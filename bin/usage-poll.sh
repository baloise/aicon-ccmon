#!/usr/bin/env bash
# ccmon poller: read Claude usage limits, write a local snapshot, ship a sample
# to Grafana Cloud. Run from a systemd timer; see ./ccmon for setup.
#
# Read-only on credentials: never refreshes or rotates the OAuth token, so it
# cannot invalidate Claude Code's own session.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCMON_DIR="$CLAUDE_DIR/ccmon"
CREDS="$CLAUDE_DIR/.credentials.json"
# An opaque id, not the hostname. It exists only to keep each machine's data in
# its own file (so concurrent pushes cannot conflict) and its own metric series.
# Publishing the real hostname would leak asset naming and answer nothing: every
# machine reports the same account-wide numbers, and freshness is already in the
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
ENV_FILE="$CCMON_DIR/grafana-cloud.env"
PUSH_LOG="$CCMON_DIR/last-push.txt"
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
    '. + {ok:false, stale:true, reason:$r, checkedAtMs:$t}' > "$TMP" 2>/dev/null \
    || printf '{"ok":false,"stale":true,"reason":"%s","checkedAtMs":%s}\n' "$1" "$now_ms" > "$TMP"
  mv -f "$TMP" "$OUT"
}

fetch_usage() {
  [ -r "$CREDS" ] || { echo "no-credentials"; return 1; }

  local expires token
  expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null)
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
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

# ------------------------------------------------------------------- push ---
# Everything below is best-effort. A push failure must never fail the unit or
# affect the snapshot the local widget reads.

[ -r "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${GRAFANA_OTLP_ENDPOINT:=}" "${GRAFANA_OTLP_USER:=}" "${GRAFANA_OTLP_TOKEN:=}"
[ -n "$GRAFANA_OTLP_ENDPOINT" ] && [ -n "$GRAFANA_OTLP_TOKEN" ] || exit 0

ACCOUNT="${CCMON_ACCOUNT:-unknown}"

# OTLP wants nanoseconds. account/source go on the DATA POINTS, not the resource:
# Mimir promotes only a few resource attributes to labels and files the rest
# under target_info, where they are useless for querying these series.
payload=$(jq -n \
  --slurpfile snap "$OUT" \
  --arg ts "${now_s}000000000" \
  --arg account "$ACCOUNT" \
  --arg source "$HOST" '
  ($snap[0]) as $s
  | [{key:"account", value:{stringValue:$account}},
     {key:"source",  value:{stringValue:$source}}] as $base
  | def gauge(name; points): {name: name, gauge: {dataPoints: points}};
    def point(v; extra): {
      asDouble: (v | tonumber),
      timeUnixNano: $ts,
      attributes: ($base + extra)
    };
    [
      (if ($s.five_hour // null) != null
        then gauge("claude_usage_five_hour_percent"; [point($s.five_hour; [])]) else empty end),
      (if ($s.seven_day // null) != null
        then gauge("claude_usage_seven_day_percent"; [point($s.seven_day; [])]) else empty end),
      ( [ ($s.limits // [])[]
          | select(.kind == "weekly_scoped" and .scope != null)
          | point(.percent; [{key:"scope", value:{stringValue:.scope}}]) ] as $scoped
        | if ($scoped | length) > 0
          then gauge("claude_usage_scoped_percent"; $scoped) else empty end),
      gauge("claude_usage_stale"; [point((if $s.ok then 0 else 1 end); [])])
    ] as $metrics
  | {resourceMetrics: [{
      resource: {attributes: [
        {key:"service.name", value:{stringValue:"claude-ccmon"}}
      ]},
      scopeMetrics: [{scope: {name:"ccmon", version:"1"}, metrics: $metrics}]
    }]}
  ' 2>/dev/null) || exit 0

resp=$(curl -sS --max-time 20 -o - -w '\n%{http_code}' \
  -X POST "$GRAFANA_OTLP_ENDPOINT" \
  -u "$GRAFANA_OTLP_USER:$GRAFANA_OTLP_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary "$payload" 2>&1)

printf '%s\t%s\n%s\n' "$(date -Is)" "${resp##*$'\n'}" "${resp%$'\n'*}" > "$PUSH_LOG"
exit 0
