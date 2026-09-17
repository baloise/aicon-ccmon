# shellcheck shell=bash
# Stages 1-4: prerequisites, platform, network, Claude Code.

stage_prereqs() {
  stage 1 "Prerequisites"
  local missing=()
  for c in jq curl; do
    command -v "$c" >/dev/null 2>&1 && ok "$c present" || { fail "$c missing"; missing+=("$c"); }
  done
  if [ ${#missing[@]} -gt 0 ]; then
    hint "Install with: sudo apt-get install -y ${missing[*]}"
    return 1
  fi

  sched_prereqs || return 1
}

stage_platform() {
  stage 2 "Platform"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
    ok "WSL2 detected (${WSL_DISTRO_NAME:-unknown distro})"
  else
    IS_WSL=0
    skip "not WSL - the Windows widget stage will be skipped"
    return 0
  fi

  if [ -d /mnt/c ]; then ok "Windows drive mounted at /mnt/c"
  else skip "/mnt/c not mounted - Windows interop unavailable"; IS_WSL=0; return 0; fi

  UNC_PATH=$(wslpath -w "$CLAUDE_DIR" 2>/dev/null || true)
  if [ -n "$UNC_PATH" ]; then
    ok "snapshot reachable from Windows"
    info "$UNC_PATH\\usage-snapshot.json"
  else
    skip "could not resolve a Windows path for $CLAUDE_DIR"
  fi

  WIN_PROFILE=$(cmd_exe_userprofile)
  [ -n "$WIN_PROFILE" ] && ok "Windows profile: $WIN_PROFILE" || skip "Windows profile not resolved"
}

cmd_exe_userprofile() {
  local p
  p=$(powershell.exe -NoProfile -Command 'Write-Output $env:USERPROFILE' 2>/dev/null | tr -d '\r\n')
  printf '%s' "$p"
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

stage_claude() {
  stage 4 "Claude Code"
  if [ -d "$CLAUDE_DIR" ]; then ok "config dir $CLAUDE_DIR"
  else fail "no $CLAUDE_DIR - is Claude Code installed?"; return 1; fi

  if [ ! -r "$CREDS" ]; then
    fail "$CREDS not readable - log in with 'claude' first"
    return 1
  fi
  ok "credentials readable"

  local sub exp now_ms
  sub=$(jq -r '.claudeAiOauth.subscriptionType // "none"' "$CREDS" 2>/dev/null)
  exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null)
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
