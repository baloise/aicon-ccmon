# shellcheck shell=bash
# Where the Claude Code OAuth credentials live, and how to read them.
#
# Sourced, never executed - by ./ccmon out of the repo, and by the installed
# poller standing next to it in ~/.claude/ccmon/. Two readers, one copy: the
# macOS half below is the fiddly part of this whole file, and that is the last
# place a second copy should be allowed to drift. It lives in bin/ rather than
# lib/ because lib/ means "sourced by ./ccmon", and the poller is the other
# reader that matters.
#
# Linux and WSL keep the credentials in a file. macOS keeps the same JSON as the
# secret of a login-Keychain generic password. Nothing here ever writes:
# refreshing the token would rotate Claude Code's own session and log it out
# from under you.

CCMON_CREDS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
CCMON_KEYCHAIN_SERVICE="Claude Code-credentials"
CCMON_KEYCHAIN_ACCOUNT="${USER:-$(id -un)}"

# file | keychain | none
#
# Never prompts, on either platform: the Keychain hands an item's attributes to
# anyone who asks and guards only its secret, so asking whether the item is
# there at all is free.
creds_source() {
  [ -r "$CCMON_CREDS_FILE" ] && { printf 'file'; return 0; }
  if [ "$(uname -s)" = Darwin ] && security find-generic-password \
       -s "$CCMON_KEYCHAIN_SERVICE" -a "$CCMON_KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
    printf 'keychain'; return 0
  fi
  printf 'none'
}

# Echo the credential JSON. $1 = seconds to wait on the Keychain (default 10).
#
# The wait is why this is not a one-liner. If the Keychain has not been told to
# trust /usr/bin/security for this item, the read blocks on a dialog - forever,
# when nobody is at the machine - and a poller that never exits is a poller that
# never runs again. Backgrounding the read keeps its stdout on the command
# substitution's pipe, so the token still never touches disk, while giving us a
# pid to kill. The watchdog's own stdout has to go to /dev/null: left on that
# pipe it would hold it open and stall the fast path for the full timeout.
creds_json() {
  local secs="${1:-10}" reader watchdog rc

  # The file first, on every platform. On Linux the branch below it is dead code
  # and the check costs nothing; on macOS it costs one failing [ -r ]. What it
  # buys is that a fixture .credentials.json wins everywhere, which is how this
  # gets exercised without going near the real token.
  #
  # Note what it does not buy. The Keychain item is keyed on the OS user, not on
  # CLAUDE_CONFIG_DIR, so pointing that at an *empty* directory on macOS falls
  # through to the real credentials rather than finding none - a sandbox needs a
  # file in it, not just a directory of its own. Claude Code keys the item the
  # same way, so one login per OS user is the behaviour to match, not a bug.
  if [ -r "$CCMON_CREDS_FILE" ]; then cat "$CCMON_CREDS_FILE"; return $?; fi
  [ "$(uname -s)" = Darwin ] || return 1

  security find-generic-password -s "$CCMON_KEYCHAIN_SERVICE" \
    -a "$CCMON_KEYCHAIN_ACCOUNT" -w 2>/dev/null &
  reader=$!
  # TERM, then KILL: the whole point of the watchdog is that this function
  # cannot hang, and a reader that declined to die on TERM would defeat it.
  ( sleep "$secs"; kill -TERM "$reader" 2>/dev/null
    sleep 2;       kill -KILL "$reader" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$reader"; rc=$?
  kill -TERM "$watchdog" 2>/dev/null
  return "$rc"
}

# A failed read, in the vocabulary the snapshot's "reason" field already uses.
# 44 is the Keychain's own "no such item"; 143 is our watchdog's SIGTERM.
creds_reason() { # $1 = creds_json's exit status
  case "$1" in
    44)  printf 'no-credentials' ;;
    143) printf 'keychain-timeout' ;;
    *)   if [ "$(creds_source)" = none ]
         then printf 'no-credentials'
         else printf 'keychain-denied'; fi ;;
  esac
}
