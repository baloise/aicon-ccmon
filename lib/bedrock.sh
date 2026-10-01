# shellcheck shell=bash
# Stage 6: the Bedrock gateway's monthly quota, for machines that use Claude
# Code through Amazon Bedrock behind a gateway that enforces one.
#
# Two things have to be known and neither belongs in this repository: where the
# gateway's dashboard lives, and which address it files this user under. Both
# are proposed from what the gateway's own credential provider left on disk,
# confirmed by the user, and kept in $CCMON_DIR/bedrock.conf - never in the
# repo, never in the history clone.

BEDROCK_CONF="$CCMON_DIR/bedrock.conf"
BEDROCK_SNAPSHOT="$CLAUDE_DIR/bedrock-snapshot.json"

bedrock_conf() { # $1 = key
  [ -f "$BEDROCK_CONF" ] || return 0
  sed -n "s/^$1=//p" "$BEDROCK_CONF" | tail -1
}

# settings.json and every claude-config profile, as one JSON array. A machine
# that is on its subscription profile today still has a Bedrock one to switch to.
bedrock_settings() {
  local files=()
  [ -f "$CLAUDE_DIR/settings.json" ] && files+=("$CLAUDE_DIR/settings.json")
  for f in "$CLAUDE_DIR"/profiles/*.json; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || { printf '[]'; return; }
  jq -s '[.[] | select(.env.CLAUDE_CODE_USE_BEDROCK == "1")]' "${files[@]}" 2>/dev/null || printf '[]'
}

bedrock_applicable() {
  [ -f "$BEDROCK_CONF" ] && return 0
  [ "$(bedrock_settings | jq 'length')" -gt 0 ] 2>/dev/null
}

# A Windows path in awsAuthRefresh is reached through its /mnt mapping.
bedrock_unix_path() {
  case "$1" in
    [A-Za-z]:\\*) wslpath -u "$1" 2>/dev/null ;;
    *) printf '%s' "$1" ;;
  esac
}

# The credential provider's executable: the first word of awsAuthRefresh, which
# may be quoted because it may contain spaces.
bedrock_provider_exe() {
  local cmd
  cmd=$(bedrock_settings | jq -r '[.[].awsAuthRefresh // empty] | first // empty')
  [ -n "$cmd" ] || return 0
  case "$cmd" in
    \"*) cmd=${cmd#\"}; cmd=${cmd%%\"*} ;;
    *)   cmd=${cmd%% *} ;;
  esac
  bedrock_unix_path "$cmd"
}

bedrock_aws_profile() {
  bedrock_settings | jq -r '[.[].env.AWS_PROFILE // empty] | first // empty'
}

# The dashboard, as the provider's own files name it. First choice: a link to
# its downloads or docs pages, which update.sh carries on Linux and macOS.
# Second: the runtime endpoint the connectivity check probes, which on the
# gateways this was written against sits on the same domain as the dashboard.
# AWS's public endpoint is skipped - it shares the prefix and is no help.
bedrock_propose_url() {
  local dir=$1 host
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  host=$(grep -h -o -E 'https://[A-Za-z0-9.-]+/(downloads|docs)' "$dir"/* 2>/dev/null \
         | sed -E 's#^https://##; s#/.*##' | head -1)
  if [ -z "$host" ]; then
    host=$(grep -h -o -E 'bedrock-runtime\.[A-Za-z0-9.-]+' "$dir"/check-connectivity.* 2>/dev/null \
           | grep -v -F amazonaws.com | head -1)
    [ -n "$host" ] && host="claude-bedrock.${host#bedrock-runtime.}"
  fi
  [ -n "$host" ] && printf 'https://%s' "$host"
}

# The curl options that reach the dashboard from here. Corporate networks tend
# to route internal hosts around the proxy, and some resolve them to an IPv6
# address nothing answers on - so try the plain route first, then without the
# proxy, then without the proxy over IPv4.
bedrock_transport() { # $1 = url -> echoes options, empty for plain
  local url=$1 host opts
  host=${url#*://}; host=${host%%/*}
  for opts in "" "--noproxy $host" "-4 --noproxy $host"; do
    # shellcheck disable=SC2086 # word-splitting the options is the point
    if [ "$(curl -sS $opts -o /dev/null -w '%{http_code}' --max-time 10 "${url%/}/health" 2>/dev/null)" = 200 ]; then
      printf '%s' "$opts"
      return 0
    fi
  done
  return 1
}

# The address the gateway knows this user by. The credential provider keeps
# the identity token's email claim beside the token itself, and that claim is
# what the gateway records usage under - only the email field is read. On WSL
# a Windows provider keeps it in the Windows profile.
bedrock_propose_email() {
  local exe=$1 profile f email=""
  profile=$(bedrock_aws_profile)
  [ -n "$profile" ] || return 0
  f="$HOME/.claude-code-session/$profile-monitoring.json"
  if [ -f "$f" ]; then
    email=$(jq -r '.email // empty' "$f" 2>/dev/null)
  elif [ "${WIN_INTEROP:-0}" = 1 ] && [ "${exe%.exe}" != "$exe" ]; then
    email=$(powershell.exe -NoProfile -Command \
      "\$f = Join-Path \$env:USERPROFILE '.claude-code-session\\$profile-monitoring.json'; if (Test-Path \$f) { (Get-Content \$f -Raw | ConvertFrom-Json).email }" \
      2>/dev/null | tr -d '\r\n')
  fi
  printf '%s' "$email"
}

# Prompt with a default, except under --yes, where a default is the answer -
# said out loud, since nobody was asked.
bedrock_ask() { # $1 = prompt, $2 = default
  if [ "$ASSUME_YES" = 1 ] && [ -n "$2" ]; then
    printf '        %s%s: %s%s\n' "$C_DIM" "$1" "$2" "$C_RESET" >&2
    printf '%s' "$2"
    return
  fi
  ask_value "$1" "$2"
}

bedrock_write_conf() { # url email curl-options
  local tmp="$BEDROCK_CONF.tmp.$$"
  mkdir -p "$CCMON_DIR"
  ( umask 077; printf 'url=%s\nemail=%s\ncurl=%s\n' "$1" "$2" "$3" > "$tmp" ) \
    && mv -f "$tmp" "$BEDROCK_CONF"
}

stage_bedrock() {
  stage 6 "Bedrock quota"

  # Installed whatever the answer below: the poll job runs it every time, and
  # unconfigured it does nothing.
  install_file "$CCMON_ROOT/bin/bedrock-poll.sh" "$CCMON_DIR/bedrock-poll.sh" 755 "Bedrock poller"

  if ! bedrock_applicable; then
    skip "no Bedrock profile in settings.json or ~/.claude/profiles"
    return 0
  fi

  if [ -n "$(bedrock_conf url)" ] && [ -n "$(bedrock_conf email)" ]; then
    ok "configured for $(bedrock_conf email)"
    info "$BEDROCK_CONF"
  else
    need "the Bedrock quota is not configured"
    info "The gateway's dashboard knows each user's monthly budget. ccmon reads your"
    info "row every 15 minutes to hourly and shows it as a second panel. Both answers"
    info "below stay in $BEDROCK_CONF."
    confirm || { info "skipped - the widget shows the subscription panel only"; return 0; }

    local exe dir url opts email
    exe=$(bedrock_provider_exe)
    dir=""
    [ -n "$exe" ] && dir=$(dirname "$exe")
    url=$(bedrock_ask "Gateway dashboard URL" "$(bedrock_propose_url "$dir")")
    url=${url%/}
    case "$url" in
      http://*|https://*) ;;
      *) fail "not a URL: ${url:-(empty)}"; return 1 ;;
    esac
    if ! opts=$(bedrock_transport "$url"); then
      fail "cannot reach $url - not directly, and not around the proxy"
      return 1
    fi
    [ -n "$opts" ] && info "reached it with: curl $opts"
    email=$(bedrock_ask "Your address as the gateway knows it" "$(bedrock_propose_email "$exe")")
    case "$email" in
      *@*) ;;
      *) fail "not an email address: ${email:-(empty)}"; return 1 ;;
    esac
    bedrock_write_conf "$url" "$email" "$opts" || { fail "could not write $BEDROCK_CONF"; return 1; }
    "$CCMON_DIR/bedrock-poll.sh" --force
    fixed "wrote $BEDROCK_CONF"
  fi

  bedrock_proof
}

# What the last fetch said, in the units the panel will show: the gateway's
# tokens are weighted by price, a million to the dollar.
bedrock_proof() {
  if [ ! -f "$BEDROCK_SNAPSHOT" ]; then
    [ "$MODE" = status ] || "$CCMON_DIR/bedrock-poll.sh" --force
  fi
  [ -f "$BEDROCK_SNAPSHOT" ] || { need "no Bedrock snapshot yet"; return 0; }

  local line
  line=$(jq -r '
    def usd: . / 1e6 | if . < 10
                       then (. * 100 | floor) as $c
                            | "$\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)"
                       else "$" + (floor | tostring) end;
    def pct: . * 100 | round | tostring + "%";
    if .ok then
      if .unlimited then "unlimited"
      else "\(.used / .limit | pct) used - \([.limit - .used, 0] | max | usd) of \(.limit | usd) left this month" end
      + (if .pool.binding == true
         then " - the \(.pool.name | ascii_downcase) pool is \(.pool.used / .pool.limit | pct) used and binds first"
         else "" end)
      + (if .blocked then " - BLOCKED (\(.block_reasons | join(", ")))" else "" end)
      + (if .known then "" else " - no usage recorded under this address yet" end)
    else "stale: \(.reason // "unknown")" end' "$BEDROCK_SNAPSHOT" 2>/dev/null)
  case "$line" in
    stale:*)
      fail "the last Bedrock fetch failed - $line"
      hint "Check the URL and address in $BEDROCK_CONF, or delete it and run ./ccmon again." ;;
    *"no usage recorded"*)
      ok "$line"
      info "If you have used Bedrock this month, the address is probably not the one"
      info "the gateway uses - delete $BEDROCK_CONF and run ./ccmon again." ;;
    *) ok "$line" ;;
  esac
}
