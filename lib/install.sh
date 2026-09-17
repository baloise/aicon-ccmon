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

  # Before the poller, which sources it on every run.
  install_file "$CCMON_ROOT/bin/creds.sh" "$CCMON_DIR/creds.sh" 644 "credential helper"
  install_file "$CCMON_ROOT/bin/usage-poll.sh" "$CCMON_DIR/usage-poll.sh" 755 "poller"

  sched_install poll
  sched_enable poll
  sched_status poll
  poller_proof
}

# Proof by running it, not by reading configuration back. On macOS the question
# is whether the *scheduler's* copy of the poller can read the Keychain with
# nobody there to click anything, and only letting the scheduler run it answers
# that. It pays for itself on both platforms: ./ccmon now ends with real numbers
# on screen instead of "the first sample arrives within five minutes".
poller_proof() {
  sched_active poll || return 0

  local before age okflag reason i=0
  before=$(file_mtime "$SNAPSHOT")
  age=$(( $(date +%s) - before ))
  if [ -f "$SNAPSHOT" ] && [ "$age" -lt 600 ]; then
    ok "snapshot refreshed ${age}s ago"
    return 0
  fi

  need "no recent snapshot - the $(sched_noun) has not produced one yet"
  confirm || { info "it will try again on its own within 5 minutes"; return 0; }

  sched_kick poll
  while [ "$i" -lt 20 ]; do
    [ "$(file_mtime "$SNAPSHOT")" != "$before" ] && break
    sleep 1; i=$(( i + 1 ))
  done
  if [ "$(file_mtime "$SNAPSHOT")" = "$before" ]; then
    fail "the $(sched_noun) wrote no snapshot within 20s"
    [ -s "$CCMON_DIR/poll.log" ] && hint "$(tail -1 "$CCMON_DIR/poll.log")"
    return 1
  fi

  okflag=$(jq -r '.ok // false'  "$SNAPSHOT" 2>/dev/null)
  reason=$(jq -r '.reason // ""' "$SNAPSHOT" 2>/dev/null)
  [ "$okflag" = true ] && { fixed "the $(sched_noun) fetched usage"; return 0; }

  case "$reason" in
    keychain-timeout)
      fail "the $(sched_noun) sat waiting for a Keychain dialog"
      hint "Answer it with Always Allow, then run ./ccmon again." ;;
    keychain-denied)
      fail "the Keychain refused the $(sched_noun) the credentials"
      keychain_hint ;;
    token-expired)
      need "token expired - use Claude Code once and the poller recovers on its own" ;;
    *)
      fail "the $(sched_noun) ran and reported: ${reason:-unknown}" ;;
  esac
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
