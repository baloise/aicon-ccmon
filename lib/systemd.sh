# shellcheck shell=bash
# The systemd half of the scheduler; lib/launchd.sh is the other. ./ccmon loads
# exactly one of the pair, so no stage has to know which is underneath.
#
# Jobs are named "poll" and "sync". Each lib maps those names onto its own
# artifacts - two unit files here, one plist there - and that mapping is the
# whole point: it is the unit filenames, spelled out in stage_poller and
# stage_history, that used to weld those stages to systemd.

UNIT_DIR="$HOME/.config/systemd/user"

# What to call the thing in a sentence, since "timer" and "agent" are not
# interchangeable words to anyone reading the output on their own machine.
sched_noun() { printf 'timer'; }

# The unit names predate the job names and are kept as they are: renaming them
# would orphan the timers already installed on every machine running this.
sched_unit() { case "$1" in poll) printf 'claude-usage' ;; sync) printf 'ccmon-sync' ;; esac; }

sched_prereqs() {
  if systemctl --user show-environment >/dev/null 2>&1; then
    ok "systemd user instance running"
  else
    fail "no systemd user instance - the timer cannot be installed"
    hint "On WSL, enable systemd: add 'systemd=true' under [boot] in /etc/wsl.conf, then 'wsl --shutdown'."
    return 1
  fi

  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "linger enabled (timer survives logout)"
  else
    need "linger is off - the timer stops when you log out"
    if confirm; then
      if loginctl enable-linger "$USER" 2>/dev/null; then
        fixed "linger enabled"
      else
        fail "could not enable linger (needs sudo: sudo loginctl enable-linger $USER)"
      fi
    fi
  fi
}

# Sets SCHED_CHANGED, which sched_enable reads: daemon-reload re-reads a unit
# file but leaves an already-running timer on its old schedule, so "the unit
# changed" and "the timer is current" are different questions.
sched_install() { # $1 = job
  local unit u changed=0
  unit=$(sched_unit "$1")
  for u in "$unit.service" "$unit.timer"; do
    install_file "$CCMON_ROOT/systemd/$u" "$UNIT_DIR/$u" 644 "$u"
    [ "$INSTALL_CHANGED" = 1 ] && changed=1
  done
  SCHED_CHANGED=$changed
  [ "$changed" = 1 ] && systemctl --user daemon-reload
  return 0
}

sched_active() { # $1 = job
  local unit; unit=$(sched_unit "$1")
  systemctl --user is-enabled "$unit.timer" >/dev/null 2>&1 \
    && systemctl --user is-active "$unit.timer" >/dev/null 2>&1
}

sched_enable() { # $1 = job
  local unit; unit=$(sched_unit "$1")
  if sched_active "$1" && [ "${SCHED_CHANGED:-0}" != 1 ]; then
    ok "$unit.timer enabled and active"
    return 0
  fi
  if sched_active "$1"; then
    need "$unit.timer is running from an older unit file"
    confirm || return 0
    systemctl --user restart "$unit.timer" >/dev/null 2>&1 \
      && fixed "$unit.timer restarted" || fail "could not restart $unit.timer"
    return 0
  fi
  need "$unit.timer is not enabled"
  confirm || return 0
  systemctl --user enable --now "$unit.timer" >/dev/null 2>&1 \
    && fixed "$unit.timer enabled" || fail "could not enable $unit.timer"
}

sched_kick() { systemctl --user start "$(sched_unit "$1").service" >/dev/null 2>&1; }

sched_status() {
  local next
  next=$(systemctl --user list-timers "$(sched_unit "$1").timer" --no-pager 2>/dev/null \
         | awk 'NR==2{print $1, $2, $3}')
  [ -n "$next" ] && info "next run: $next"
  return 0
}

sched_remove() {
  local unit; unit=$(sched_unit "$1")
  systemctl --user disable --now "$unit.timer" >/dev/null 2>&1 \
    && fixed "$unit.timer disabled" || skip "$unit.timer was not active"
  rm -f "$UNIT_DIR/$unit.timer" "$UNIT_DIR/$unit.service"
  rm -rf "$UNIT_DIR/$unit.service.d"
  systemctl --user daemon-reload
  fixed "$unit units removed"
}
