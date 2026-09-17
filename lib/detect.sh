# shellcheck shell=bash
# Stages 1, 3 and 4: prerequisites, network, Claude Code.
# Stage 2 lives in lib/platform.sh, which is what decides the platform at all.

stage_prereqs() {
  stage 1 "Prerequisites"
  local missing=()
  for c in jq curl; do
    command -v "$c" >/dev/null 2>&1 && ok "$c present" || { fail "$c missing"; missing+=("$c"); }
  done
  if [ ${#missing[@]} -gt 0 ]; then
    hint "Install with: $(pkg_hint "${missing[*]}")"
    return 1
  fi

  sched_prereqs || return 1
}

stage_network() {
  stage 3 "Network"
  if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
    ok "proxy configured: ${https_proxy:-$HTTPS_PROXY}"
  else
    skip "no proxy in the environment"
  fi

  # A bare TLS reachability check. Deliberately NOT a request to
  # /api/oauth/usage: unauthenticated calls there are throttled per source IP,
  # and behind a shared corporate proxy a 429 would say nothing about us.
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -I \
    https://api.anthropic.com/ 2>/dev/null || echo 000)
  if [ "$code" = "000" ]; then
    fail "cannot reach api.anthropic.com - check proxy/CA"
  else
    ok "api.anthropic.com reachable"
  fi

}

# The remedy, in one place: stage 4 prints it when the read fails, and the
# poller proof prints it when the scheduler's copy of the read fails.
keychain_hint() {
  hint "Run this yourself and click Always Allow, not Allow:"
  hint "  security find-generic-password -s \"$CCMON_KEYCHAIN_SERVICE\" -a \"$CCMON_KEYCHAIN_ACCOUNT\" -w >/dev/null"
}

stage_claude() {
  stage 4 "Claude Code"
  if [ -d "$CLAUDE_DIR" ]; then ok "config dir $CLAUDE_DIR"
  else fail "no $CLAUDE_DIR - is Claude Code installed?"; return 1; fi

  local src creds rc t0 t1
  src=$(creds_source)
  if [ "$src" = none ]; then
    fail "no Claude Code credentials - log in with 'claude' first"
    return 1
  fi

  # Both sources at once is a trap worth naming out loud: a .credentials.json
  # carried over from a Linux box wins for ever and reports token-expired
  # against a Keychain holding a live token. Picking by expiry instead would be
  # too clever to debug when it went wrong.
  if [ "$src" = file ] && [ "$PLATFORM" = macos ] \
     && security find-generic-password -s "$CCMON_KEYCHAIN_SERVICE" \
          -a "$CCMON_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    need "there is both a $CCMON_CREDS_FILE and a Keychain item"
    info "The file wins, and on macOS it is the one Claude Code never refreshes."
    if confirm; then
      if rm -f "$CCMON_CREDS_FILE"; then
        fixed "removed the file; the Keychain is the source now"
        src=keychain
      else
        fail "could not remove $CCMON_CREDS_FILE"
      fi
    fi
  fi

  # A local Keychain read is milliseconds. Anything slower than that was
  # answered by a person - and a person may have clicked Allow, which is good
  # for exactly one read where a poller needs one every five minutes.
  t0=$(date +%s); creds=$(creds_json 120); rc=$?; t1=$(date +%s)
  if [ "$rc" -ne 0 ] || [ -z "$creds" ]; then
    fail "could not read the credentials ($(creds_reason "$rc"))"
    [ "$src" = keychain ] && keychain_hint
    return 1
  fi
  if [ "$src" = keychain ] && [ $(( t1 - t0 )) -ge 2 ]; then
    ok "credentials readable (keychain)"
    need "macOS asked for permission just now"
    info "Always Allow covers every future read, which is what a 5-minute poller"
    info "needs; Allow covers exactly one. Re-run ./ccmon - if this line is gone,"
    info "it stuck."
  else
    ok "credentials readable ($src)"
  fi

  local sub exp now_ms
  sub=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.subscriptionType // "none"' 2>/dev/null)
  exp=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)
  now_ms=$(( $(date +%s) * 1000 ))

  case "$sub" in
    pro|max|team|enterprise) ok "subscription: $sub (rate limits are reported)" ;;
    *) need "subscription '$sub' may not report rate limits"
       info "The API only returns rate_limits for subscription plans." ;;
  esac

  if [ "$exp" -gt "$now_ms" ] 2>/dev/null; then
    ok "access token valid for $(( (exp/1000 - now_ms/1000) / 60 )) min"
  else
    need "access token expired - ccmon will report stale until you use Claude Code again"
    info "ccmon never refreshes the token itself: rotating it would log Claude Code out."
  fi
}
