# shellcheck shell=bash
# The launchd half of the scheduler; lib/systemd.sh is the other. ./ccmon loads
# exactly one of the pair, so no stage has to know which is underneath.
#
# Four things about launchd shape everything below:
#
#   - A Label is the primary key, not a filename, and it is what launchctl
#     takes. The plists are named after their labels so the two agree.
#   - There is no daemon-reload. launchd holds a plist in memory from the moment
#     it is bootstrapped, so an edited plist needs a full bootout/bootstrap.
#   - gui/<uid>, never user/<uid>: the GUI domain is the one with an Aqua
#     session, and therefore the only one whose processes can read the login
#     Keychain that the credentials live in on this platform.
#   - `launchctl disable` writes a per-user override that outlives the plist.
#     bootstrap succeeds on a disabled label and then never runs it - so clear
#     it on the way in, and never write one on the way out.

AGENT_DIR="$HOME/Library/LaunchAgents"
GUI_DOMAIN="gui/$(id -u)"

# What to call the thing in a sentence, since "timer" and "agent" are not
# interchangeable words to anyone reading this output on their own machine.
sched_noun() { printf 'agent'; }

sched_label() { case "$1" in poll) printf 'com.ccmon.poll' ;; sync) printf 'com.ccmon.sync' ;; esac; }
sched_plist() { printf '%s/%s.plist' "$AGENT_DIR" "$(sched_label "$1")"; }

# launchctl exits 113 for a label it has never heard of in this domain.
sched_active()   { launchctl print "$GUI_DOMAIN/$(sched_label "$1")" >/dev/null 2>&1; }
sched_disabled() { launchctl print-disabled "$GUI_DOMAIN" 2>/dev/null \
                     | grep -q "\"$(sched_label "$1")\" => disabled"; }

sched_prereqs() {
  # Not "is launchd running" - it always is - but "is there a GUI login session
  # to put an agent in". Without one there is no Aqua session, and so no
  # unlocked login Keychain for the poller to read the credentials from. That is
  # what you get over ssh with nobody at the screen, and it is the honest
  # counterpart of "no systemd user instance".
  if launchctl print "$GUI_DOMAIN" >/dev/null 2>&1; then
    ok "launchd GUI session for uid $(id -u)"
  else
    fail "no GUI login session - an agent installed from here could not read the Keychain"
    hint "Run ./ccmon in Terminal on the Mac itself, logged in at the screen."
    return 1
  fi
  # linger has no counterpart. Agents stop at logout by design, and the thing
  # that would not stop is a root LaunchDaemon, which could not reach the login
  # Keychain at all.
  info "the agents run while you are logged in; sleep pauses them and they catch up on wake"
}

# Sets SCHED_CHANGED, which sched_enable reads: launchd is holding the old
# plist in memory, so "the file changed" and "the agent is current" are
# different questions here too.
sched_install() { # $1 = job
  local label; label=$(sched_label "$1")
  mkdir -p "$AGENT_DIR"
  install_file "$CCMON_ROOT/launchd/$label.plist" "$(sched_plist "$1")" 644 "$label.plist"
  SCHED_CHANGED=$INSTALL_CHANGED
  return 0
}

sched_enable() { # $1 = job
  local label plist; label=$(sched_label "$1"); plist=$(sched_plist "$1")
  # install_file has already reported and counted a missing plist; a second
  # TODO saying the same thing would double-count one absent file.
  [ -f "$plist" ] || return 0

  if sched_active "$1" && [ "${SCHED_CHANGED:-0}" != 1 ]; then
    ok "$label is loaded"
    return 0
  fi
  if sched_active "$1";      then need "$label is loaded from an older plist"
  elif sched_disabled "$1";  then need "$label is in launchd's disabled list"
  else                            need "$label is not loaded"; fi
  confirm || return 0

  launchctl enable "$GUI_DOMAIN/$label" 2>/dev/null
  launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1
  # A bootout that caught the job mid-run waits for it, and a bootstrap arriving
  # before launchd has finished tearing down fails with "Operation already in
  # progress". One retry, rather than telling the user to run ./ccmon twice.
  if launchctl bootstrap "$GUI_DOMAIN" "$plist" 2>/dev/null; then
    fixed "$label loaded"
  else
    sleep 2
    if launchctl bootstrap "$GUI_DOMAIN" "$plist" 2>&1 | sed 's/^/        /'; then
      fixed "$label loaded"
    else
      fail "launchctl refused to load $label"
    fi
  fi
}

sched_kick() { launchctl kickstart "$GUI_DOMAIN/$(sched_label "$1")" >/dev/null 2>&1; }

# launchd publishes no next-run time - there is no list-timers. What it does
# know is how often the job has run and how the last run ended, which is the
# more useful half anyway; "is it current" is already answered by the age of
# the snapshot.
sched_status() {
  local label out runs code secs
  label=$(sched_label "$1")
  out=$(launchctl print "$GUI_DOMAIN/$label" 2>/dev/null) || return 0
  runs=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*runs = //p' | head -1)
  code=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)
  secs=$(plutil -extract StartInterval raw -o - "$(sched_plist "$1")" 2>/dev/null || echo 0)
  info "every $(( secs / 60 )) min; ${runs:-0} runs, last exit ${code:-none}"
  case "$code" in
    ''|0|'(never exited)') ;;
    *) [ -s "$CCMON_DIR/$1.log" ] && hint "$(tail -1 "$CCMON_DIR/$1.log")" ;;
  esac
  return 0
}

sched_remove() {
  local label; label=$(sched_label "$1")
  if sched_active "$1"; then
    launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1 \
      && fixed "$label unloaded" || fail "could not unload $label"
  else
    skip "$label was not loaded"
  fi
  # Deliberately no `launchctl disable`: that override is sticky, and a later
  # reinstall would bootstrap cleanly and then never run.
  rm -f "$(sched_plist "$1")" "$CCMON_DIR/$1.log"
  fixed "$label.plist removed"
}
