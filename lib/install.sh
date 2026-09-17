# shellcheck shell=bash
# Stages 5 and 7: poller + scheduled job, and the Claude Code status line.

stage_poller() {
  stage 5 "Poller and $(sched_noun)"

  # Migrate the pre-repo layout, if present.
  if [ -f "$CLAUDE_DIR/usage-poll.sh" ]; then
    need "found a pre-repo poller at $CLAUDE_DIR/usage-poll.sh"
    if confirm; then
      rm -f "$CLAUDE_DIR/usage-poll.sh"
      fixed "removed the old copy (the repo version installs to $CCMON_DIR/)"
    fi
  fi

  install_file "$CCMON_ROOT/bin/usage-poll.sh" "$CCMON_DIR/usage-poll.sh" 755 "poller"

  sched_install poll
  sched_enable poll
  sched_status poll
}

stage_statusline() {
  stage 7 "Claude Code status line"
  install_file "$CCMON_ROOT/bin/statusline.sh" "$CCMON_DIR/statusline.sh" 755 "status line script"

  # Migrate the pre-repo status line, if present.
  if [ -f "$CLAUDE_DIR/statusline-command.sh" ]; then
    need "found a pre-repo status line at $CLAUDE_DIR/statusline-command.sh"
    if confirm; then
      rm -f "$CLAUDE_DIR/statusline-command.sh"
      fixed "removed the old copy"
    fi
  fi

  local settings="$CLAUDE_DIR/settings.json"
  local want='bash ~/.claude/ccmon/statusline.sh'
  if [ ! -f "$settings" ]; then
    need "no $settings"
    return 0
  fi
  local have
  have=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)
  if [ "$have" = "$want" ]; then
    ok "settings.json points at the ccmon status line"
    return 0
  fi
  if [ -n "$have" ]; then
    need "settings.json uses a different status line: $have"
  else
    need "settings.json has no status line configured"
  fi
  confirm || { info "left unchanged"; return 0; }
  local tmp="$settings.ccmon.$$"
  if jq --arg c "$want" '.statusLine = {type:"command", command:$c}' "$settings" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$settings"
    fixed "settings.json updated"
  else
    rm -f "$tmp"
    fail "could not rewrite $settings"
  fi
}
