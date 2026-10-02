#!/usr/bin/env bash
# ccmon poller: read Claude usage limits, write a local snapshot, and append a
# sample to this machine's history file. Run from a systemd timer; see ./ccmon
# for setup.
#
# Read-only on credentials: never refreshes or rotates the OAuth token, so it
# cannot invalidate Claude Code's own session.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCMON_DIR="$CLAUDE_DIR/ccmon"

# Beside this script, wherever it is: ccmon installs the two together, and the
# repo keeps them side by side in bin/. Resolving it this way rather than from
# CCMON_DIR keeps the poller working when CLAUDE_CONFIG_DIR points at a fixture.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=creds.sh
. "$HERE/creds.sh" || { echo "no creds.sh beside the poller - run ./ccmon" >&2; exit 1; }
# An opaque id, not the hostname. It exists only to keep each machine's data in
# its own file, so two machines syncing at once cannot conflict. Publishing the
# real hostname would leak asset naming and answer nothing: every machine
# reports the same account-wide numbers, and freshness is already in the
# timestamps.
machine_id() {
  local f="$CCMON_DIR/machine-id"
  if [ ! -s "$f" ]; then
    mkdir -p "$CCMON_DIR"
    (od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') > "$f"
  fi
  cat "$f"
}
OUT="$CLAUDE_DIR/usage-snapshot.json"
HISTORY_DIR="$CCMON_DIR/history"
BACKOFF="$CCMON_DIR/backoff-until"

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT

now_s=$(date +%s)
now_ms=$(( now_s * 1000 ))

# ---------------------------------------------------------------- snapshot ---

write_snapshot_stale() { # $1 = reason
  local prev='{}'
  [ -f "$OUT" ] && prev=$(cat "$OUT" 2>/dev/null || echo '{}')
  echo "$prev" | jq --arg r "$1" --argjson t "$now_ms" \
    'del(.via, .ownReason) + {ok:false, stale:true, reason:$r, checkedAtMs:$t}' > "$TMP" 2>/dev/null \
    || printf '{"ok":false,"stale":true,"reason":"%s","checkedAtMs":%s}\n' "$1" "$now_ms" > "$TMP"
  mv -f "$TMP" "$OUT"
}

fetch_usage() {
  local creds rc expires token
  creds=$(creds_json); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$creds" ] || { creds_reason "$rc"; return 1; }

  expires=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -n "$token" ] || { echo "no-token"; return 1; }
  [ "$expires" -gt "$now_ms" ] 2>/dev/null || { echo "token-expired"; return 1; }

  local body code
  body=$(curl -sS --max-time 20 -o - -w '\n%{http_code}' \
    https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: ccmon/1" 2>/dev/null)

  code="${body##*$'\n'}"
  [ "$code" = "200" ] || { echo "http-$code"; return 1; }
  printf '%s' "${body%$'\n'*}"
}

# ---------------------------------------------------------------- history ---
# Append one line to this machine's own file. One file per host means several
# machines never touch the same file, so pushes don't conflict.
#
# Failed polls are recorded too, with null values: that makes "the poller ran
# and got nothing" visibly different from "this laptop was switched off".

append_history() {
  [ -d "$HISTORY_DIR/data" ] || return 0
  local line
  # Build the line first: appending directly would touch the file even when jq
  # fails, leaving a silent zero-byte gap instead of a sample.
  line=$(jq -c --argjson t "$now_s" '
    {
      t: $t,
      five_hour: (if .ok then .five_hour else null end),
      seven_day: (if .ok then .seven_day else null end),
      scoped: (if .ok
               then ([ (.limits // [])[]
                       | select(.kind == "weekly_scoped" and .scope != null)
                       | {key: .scope, value: .percent} ] | from_entries)
               else {} end),
      ok: .ok
    }' "$OUT" 2>>"$CCMON_DIR/history-errors.log") || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >> "$HISTORY_DIR/data/$HOST.jsonl"

  # This host's latest reading, including the reset times the append-only rows
  # deliberately omit. The wallboard needs them for its countdowns.
  jq -c --argjson t "$now_s" --arg source "$HOST" '
    def epoch: if . == null then null
               else (sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601) end;
    {
      source: $source, t: $t, ok: .ok,
      five_hour: .five_hour, seven_day: .seven_day,
      scoped: ([ (.limits // [])[]
                 | select(.kind == "weekly_scoped" and .scope != null)
                 | {key: .scope, value: .percent} ] | from_entries),
      five_hour_resets_at: (.five_hour_resets_at | epoch),
      seven_day_resets_at: (.seven_day_resets_at | epoch)
    }' "$OUT" > "$HISTORY_DIR/data/$HOST.latest.json.tmp" 2>>"$CCMON_DIR/history-errors.log" \
    && mv -f "$HISTORY_DIR/data/$HOST.latest.json.tmp" "$HISTORY_DIR/data/$HOST.latest.json"
}

# ----------------------------------------------------------------- borrow ---
# When this machine cannot read its own usage - most often because its token
# expired while Claude Code was used through another provider - another
# machine's reading is the next best thing. The quota is per account, so it is
# the same number, and the history clone already holds every machine's latest
# one: no network, no credentials.
#
# Only a reading under 30 minutes old (the sync runs every 15), and only from
# the same account. latest.json carries no account id, but the weekly window
# is anchored to the account and repeats every 7 days, so a 7d reset that is a
# whole number of weeks from this machine's last one is the same account. With
# no last reading of its own to compare against, a machine borrows nothing.
#
# Our own failure was recorded by then, so the borrowed numbers never enter
# this machine's history, and another machine never borrows a borrowed one.
borrow_reading() { # $1 = why our own read failed
  local data="$HISTORY_DIR/data" f files=()
  [ -d "$data" ] && [ -f "$OUT" ] || return 1
  for f in "$data"/*.latest.json; do
    [ -f "$f" ] && [ "$f" != "$data/$HOST.latest.json" ] && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 1

  jq -n --slurpfile own "$OUT" --arg why "$1" --argjson now "$now_s" '
    def epoch: if . == null then null
               else (sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601) end;
    def iso: if . == null then null else todate end;
    ($own[0].seven_day_resets_at | epoch) as $anchor
    | select($anchor != null)
    | [ inputs
        | select(.ok == true and .t != null and ($now - .t) < 1800
                 and .seven_day_resets_at != null)
        | select((((.seven_day_resets_at - $anchor) % 604800) + 604800) % 604800
                 | . < 3600 or . > 604800 - 3600) ]
    | max_by(.t) // empty
    | {
        ok: true,
        stale: false,
        fetchedAtMs: (.t * 1000),
        checkedAtMs: ($now * 1000),
        via: .source,
        ownReason: $why,
        five_hour: .five_hour,
        seven_day: .seven_day,
        five_hour_resets_at: (.five_hour_resets_at | iso),
        seven_day_resets_at: (.seven_day_resets_at | iso),
        limits: [ (.scoped // {}) | to_entries[]
                  | {kind: "weekly_scoped", group: null, percent: .value,
                     severity: null, resets_at: null, scope: .key} ]
      }' "${files[@]}" > "$TMP" 2>/dev/null || return 1
  [ -s "$TMP" ] || return 1
  mv -f "$TMP" "$OUT"
}

mkdir -p "$CCMON_DIR"
HOST=$(machine_id)

# Samples collected before machine ids existed are named after the hostname.
if [ -d "$HISTORY_DIR/data" ]; then
  legacy=$(hostname -s 2>/dev/null || hostname)
  if [ -n "$legacy" ] && [ "$legacy" != "$HOST" ] && [ -f "$HISTORY_DIR/data/$legacy.jsonl" ] \
     && [ ! -f "$HISTORY_DIR/data/$HOST.jsonl" ]; then
    mv -f "$HISTORY_DIR/data/$legacy.jsonl" "$HISTORY_DIR/data/$HOST.jsonl"
    [ -f "$HISTORY_DIR/data/$legacy.latest.json" ] \
      && mv -f "$HISTORY_DIR/data/$legacy.latest.json" "$HISTORY_DIR/data/$HOST.latest.json"
  fi
fi

# The endpoint throttles (HTTP 429) without advertising a limit in headers, so
# back off rather than hammering it at the normal cadence.
if [ -f "$BACKOFF" ] && [ "$(cat "$BACKOFF" 2>/dev/null || echo 0)" -gt "$now_s" ] 2>/dev/null; then
  exit 0
fi

if ! raw=$(fetch_usage); then
  case "$raw" in
    http-429) echo $(( now_s + 900 )) > "$BACKOFF" ;;
  esac
  write_snapshot_stale "${raw:-unknown}"
  append_history
  borrow_reading "${raw:-unknown}"
  exit 0
fi
rm -f "$BACKOFF"

if ! echo "$raw" | jq --argjson t "$now_ms" '
  {
    ok: true,
    stale: false,
    fetchedAtMs: $t,
    five_hour:  (.five_hour.utilization // null),
    seven_day:  (.seven_day.utilization // null),
    five_hour_resets_at: (.five_hour.resets_at // null),
    seven_day_resets_at: (.seven_day.resets_at // null),
    limits: [ (.limits // [])[] | {
        kind, group, percent, severity, resets_at,
        scope: (.scope.model.display_name // null)
    } ]
  }' > "$TMP" 2>/dev/null; then
  write_snapshot_stale "bad-response"
  exit 0
fi
mv -f "$TMP" "$OUT"

append_history
