#!/usr/bin/env bash
# ccmon Bedrock poller: read this user's monthly token quota from the Bedrock
# gateway's dashboard and write a local snapshot for the widget. Run from the
# same timer as usage-poll.sh; see ./ccmon for setup.
#
# Live only, by design. The snapshot sits beside usage-snapshot.json, outside
# the history clone, and nothing here appends a sample - the gateway's numbers
# are per person, not per account, so they have no business in a published
# data branch.
#
# Every fifteen minutes when the gateway answers for this user alone, hourly
# when it sends everyone. Fifteen minutes is how often the gateway itself
# recounts, so polling faster shows nothing new; but the full list is a few
# megabytes, and that is worth fetching only every hour. Once a day was tried
# and was visibly behind the dashboard by lunchtime. --force (the widget's
# "Refresh now"), a new month and a failed last attempt override the throttle.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCMON_DIR="$CLAUDE_DIR/ccmon"
CONF="$CCMON_DIR/bedrock.conf"
OUT="$CLAUDE_DIR/bedrock-snapshot.json"

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

now_s=$(date +%s)
now_ms=$(( now_s * 1000 ))
month=$(date -u +%Y-%m)   # the gateway counts calendar months in UTC

force=0
[ "${1:-}" = "--force" ] && force=1

# key=value, read rather than sourced: the file is written by ./ccmon, but a
# value is still not something to execute.
conf() { # $1 = key
  [ -f "$CONF" ] || return 0
  sed -n "s/^$1=//p" "$CONF" | tail -1
}

URL="${CCMON_BEDROCK_URL:-$(conf url)}"
EMAIL="${CCMON_BEDROCK_EMAIL:-$(conf email)}"
read -r -a CURL_OPTS <<< "$(conf curl)"

# Not configured is not an error: on a subscription-only machine this runs
# every five minutes and has nothing to do.
[ -n "$URL" ] && [ -n "$EMAIL" ] || exit 0

if [ "$force" = 0 ] && [ -f "$OUT" ]; then
  fresh=$(jq -r --argjson now "$now_ms" --arg m "$month" --arg max "${CCMON_BEDROCK_MAX_AGE:-}" '
    (if $max != "" then ($max | tonumber) elif .filtered == true then 900 else 3600 end) as $age
    | .ok == true and .month == $m and ($now - (.fetchedAtMs // 0)) < ($age * 1000)
  ' "$OUT" 2>/dev/null)
  [ "$fresh" = true ] && exit 0
fi

write_snapshot_stale() { # $1 = reason
  local prev='{}'
  [ -f "$OUT" ] && prev=$(cat "$OUT" 2>/dev/null || echo '{}')
  echo "$prev" | jq --arg r "$1" --argjson t "$now_ms" \
    '. + {ok:false, stale:true, reason:$r, checkedAtMs:$t}' > "$TMP" 2>/dev/null \
    || printf '{"ok":false,"stale":true,"reason":"%s","checkedAtMs":%s}\n' "$1" "$now_ms" > "$TMP"
  mv -f "$TMP" "$OUT"
}

# ?email= asks for this one user. A gateway that does not know the parameter
# ignores it and sends everyone, which the filter below copes with just the
# same - so there is nothing to detect and no second code path.
#
# The body is held in memory and never written out: it is every user's usage,
# and only our own row is kept.
q=$(jq -rn --arg e "$EMAIL" '$e | @uri')
# The +-form because bash 3.2, /bin/bash on every Mac, calls an empty array
# unbound under set -u.
body=$(curl -sS --max-time 90 ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -o - -w '\n%{http_code}' \
  -H "User-Agent: ccmon/1" "${URL%/}/api/usage?email=$q" 2>/dev/null)
code="${body##*$'\n'}"
if [ "$code" != "200" ]; then
  write_snapshot_stale "http-${code:-000}"
  exit 0
fi

# Used is months[current].total_tokens and the limit is effective_limit, as on
# the dashboard itself. Someone with no usage yet this month is absent from the
# list, which means 0 used against the default limit - not an error.
#
# The shared pool kept is whichever applies to this user and is fullest: any of
# them blocks everyone in it once spent. It is "binding" when it is fuller than
# the user's own quota, or blocked - the only case in which it is worth a row,
# since otherwise the personal quota runs out first.
#
# "filtered" is whether the gateway answered for this user alone, which is what
# the throttle above keys on. "dashboard" is for the widget's menu link.
if ! printf '%s' "${body%$'\n'*}" | jq --arg e "$EMAIL" --arg url "${URL%/}" --argjson t "$now_ms" '
  (.current_month) as $m
  | ([.users[]? | select((.email | ascii_downcase) == ($e | ascii_downcase))] | first) as $u
  | (.pools // {}) as $p
  | ($m | split("-") | map(tonumber)) as [$y, $mo]
  | {
      ok: true,
      stale: false,
      fetchedAtMs: $t,
      filtered: ((.users // []) | length <= 1),
      dashboard: $url,
      serverRefreshedAt: (.last_refresh // null),
      email: ($u.email // $e),
      known: ($u != null),
      month: $m,
      used: ($u.months[$m].total_tokens // 0),
      limit: ($u.effective_limit // .default_limit),
      unlimited: ($u.unlimited // false),
      blocked: ($u.blocked // false),
      block_reasons: ($u.block_reasons // []),
      resets_at: (if $mo == 12 then "\($y + 1)-01-01T00:00:00Z"
                  else "\($y)-\(if $mo < 9 then "0" else "" end)\($mo + 1)-01T00:00:00Z" end),
      pool: ([ ($p.org[$m]? // empty | {kind: "org", name: "Org"} + .),
               ($p.country[$u.country // ""][$m]? // empty | {kind: "country", name: $u.country} + .),
               ($p.market_unit[$u.market_unit // ""][$m]? // empty | {kind: "market_unit", name: $u.market_unit} + .) ]
             | map(select((.monthly_token_limit // 0) > 0)
                   | {kind, name, used: .total_tokens, limit: .monthly_token_limit, blocked: (.blocked // false)})
             | max_by(.used / .limit))
    }
  | . as $s
  | .pool |= (if . == null then null
              else . + {binding: (.blocked or $s.unlimited
                                  or ($s.limit != null and $s.limit > 0
                                      and .used / .limit >= $s.used / $s.limit))} end)
  | if .limit == null or $m == null then error("not a usage response") else . end
' > "$TMP" 2>/dev/null; then
  write_snapshot_stale "bad-response"
  exit 0
fi
mv -f "$TMP" "$OUT"
