# shellcheck shell=bash
# Stages 5 and 9: poller + timer, and the Claude Code status line.

UNIT_DIR="$HOME/.config/systemd/user"

stage_poller() {
  stage 5 "Poller and timer"

  # Migrate the pre-repo layout, if present.
  if [ -f "$CLAUDE_DIR/usage-poll.sh" ]; then
    need "found a pre-repo poller at $CLAUDE_DIR/usage-poll.sh"
    if confirm; then
      rm -f "$CLAUDE_DIR/usage-poll.sh"
      fixed "removed the old copy (the repo version installs to $CCMON_DIR/)"
    fi
  fi

  install_file "$CCMON_ROOT/bin/usage-poll.sh" "$CCMON_DIR/usage-poll.sh" 755 "poller"

  local changed=0
  for u in claude-usage.service claude-usage.timer; do
    if [ -f "$UNIT_DIR/$u" ] && cmp -s "$CCMON_ROOT/systemd/$u" "$UNIT_DIR/$u"; then
      ok "$u is current"
    else
      need "$u needs installing"
      if confirm; then
        mkdir -p "$UNIT_DIR"
        cp "$CCMON_ROOT/systemd/$u" "$UNIT_DIR/$u"
        fixed "wrote $UNIT_DIR/$u"
        changed=1
      fi
    fi
  done
  [ "$changed" = 1 ] && systemctl --user daemon-reload

  if systemctl --user is-enabled claude-usage.timer >/dev/null 2>&1 \
     && systemctl --user is-active claude-usage.timer >/dev/null 2>&1; then
    ok "timer enabled and active"
  else
    need "timer is not enabled"
    if confirm; then
      systemctl --user enable --now claude-usage.timer >/dev/null 2>&1 \
        && fixed "timer enabled" || fail "could not enable the timer"
    fi
  fi

  local next
  next=$(systemctl --user list-timers claude-usage.timer --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')
  [ -n "$next" ] && info "next run: $next"
}

stage_statusline() {
  stage 9 "Claude Code status line"
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
