# shellcheck shell=bash
# Stage 2, and the handful of one-liners whose GNU spelling is not portable.
#
# PLATFORM is decided once, here, at source time; everything else asks this
# variable rather than re-running uname or re-reading /proc/version. The three
# helpers below are each a single differing line - too small to earn a platform
# module of their own, too scattered to leave inline at the call sites.

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  # WSL is Linux that can also reach Windows. Whether that reach actually works
  # is a second question, and lib/windows.sh answers it for itself.
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null
          then PLATFORM=wsl; else PLATFORM=linux; fi ;;
  *)      PLATFORM=unknown ;;
esac

# BSD stat has no -c. The 0 is load-bearing: callers compare mtimes to decide
# whether a build ran, and a missing file has to compare unequal rather than
# make every caller handle an error.
file_mtime() { # $1 = path
  case "$PLATFORM" in
    macos) stat -f %m "$1" 2>/dev/null || echo 0 ;;
    *)     stat -c %Y "$1" 2>/dev/null || echo 0 ;;
  esac
}

# This machine's address on the LAN, for the `ccmon serve` banner. `hostname -I`
# is GNU-only and macOS has no equivalent, so ask the routing table which
# interface carries the default route and then that interface's address. A VPN
# can leave the default route on a utun with no IPv4 of its own, hence the en0
# fallback.
lan_ip() {
  local dev ip=""
  if [ "$PLATFORM" = macos ]; then
    dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$dev" ] && ip=$(ipconfig getifaddr "$dev" 2>/dev/null)
    [ -n "$ip" ] || ip=$(ipconfig getifaddr en0 2>/dev/null)
    printf '%s' "$ip"
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

# The one-liner that installs a missing tool. Not a package-manager
# abstraction: it prints a command for a person to read, and never runs one.
pkg_hint() { # $@ = packages
  case "$PLATFORM" in
    macos) printf 'brew install %s' "$*" ;;
    *)     printf 'sudo apt-get install -y %s' "$*" ;;
  esac
}

stage_platform() {
  stage 2 "Platform"
  case "$PLATFORM" in
    wsl)   platform_wsl ;;
    macos) platform_macos ;;
    linux) ok "Linux"; skip "no desktop widget outside WSL and macOS" ;;
    *)     fail "ccmon does not know how to run on $(uname -s)" ;;
  esac
}

platform_macos() {
  local v; v=$(sw_vers -productVersion 2>/dev/null)
  ok "macOS${v:+ $v}"

  # A launchd agent carries no TCC consent of its own. If the config dir sits
  # in a protected domain the poller reads fine from Terminal and is denied
  # from the agent - silently, with a clean exit code, and the only symptom is
  # samples that stop arriving. Refuse now rather than leave that to be found.
  case "$CLAUDE_DIR/" in
    "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*|/Volumes/*)
      fail "$CLAUDE_DIR is inside a location macOS guards with TCC"
      info "A scheduled agent gets no consent prompt there; it would just be denied."
      hint "Point CLAUDE_CONFIG_DIR outside Documents, Desktop, Downloads and /Volumes."
      return 1 ;;
    *) ok "config dir is outside the TCC-protected locations" ;;
  esac
}
