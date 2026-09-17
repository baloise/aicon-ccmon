# shellcheck shell=bash
# Shared output + prompting helpers for ccmon. Sourced, never executed.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[36m'
else
  C_RESET=; C_DIM=; C_BOLD=; C_GREEN=; C_YELLOW=; C_RED=; C_BLUE=
fi

N_OK=0; N_FIXED=0; N_NEED=0; N_FAIL=0

stage()  { # $1 = number (may be empty), $2 = title
  if [ -n "$1" ]; then printf '\n%s%s %s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"
  else printf '\n%s%s%s\n' "$C_BOLD" "$2" "$C_RESET"; fi
}
ok()     { N_OK=$((N_OK+1));     printf '  %sOK%s    %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
fixed()  { N_FIXED=$((N_FIXED+1)); [ "$N_NEED" -gt 0 ] && N_NEED=$((N_NEED-1)); printf '  %sFIX%s   %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
need()   { N_NEED=$((N_NEED+1));  printf '  %sTODO%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
skip()   {                        printf '  %sSKIP%s  %s\n' "$C_DIM"    "$C_RESET" "$*"; }
fail()   { N_FAIL=$((N_FAIL+1));  printf '  %sFAIL%s  %s\n' "$C_RED"    "$C_RESET" "$*"; }
info()   {                        printf '        %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
hint()   {                        printf '        %s\n' "$*"; }

# confirm "question" -> 0 to proceed. Never proceeds in status mode; always
# proceeds under --yes.
confirm() {
  [ "$MODE" = status ] && return 1
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  local reply
  printf '        %s[y/N] %s' "$C_BOLD" "$C_RESET"
  read -r reply </dev/tty || return 1
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

ask_secret() { # $1 = prompt -> echoes the value
  local v
  printf '        %s: ' "$1" >&2
  read -rs v </dev/tty || true
  printf '\n' >&2
  printf '%s' "$v"
}

ask_value() { # $1 = prompt, $2 = default -> echoes the value
  local v
  printf '        %s [%s]: ' "$1" "$2" >&2
  read -r v </dev/tty || true
  printf '%s' "${v:-$2}"
}

# Install $1 -> $2 only when content differs. Reports which happened.
#
# Sets INSTALL_CHANGED so a caller can tell a copy from a no-op. The return code
# cannot say it: 0 already means both "installed it" and "it was already
# current", and the schedulers need the difference to know whether a reload is
# owed. Reset on entry, or a later call inherits an earlier one's verdict.
INSTALL_CHANGED=0
install_file() { # src dst mode label
  local src=$1 dst=$2 mode=$3 label=$4
  INSTALL_CHANGED=0
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    ok "$label is current"
    return 0
  fi
  local verb="installed"
  [ -f "$dst" ] && verb="updated"
  if [ ! -f "$dst" ]; then
    need "$label is not installed"
  else
    need "$label differs from the repo copy"
  fi
  confirm || { info "left unchanged"; return 1; }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod "$mode" "$dst"
  INSTALL_CHANGED=1
  fixed "$verb $label -> $dst"
}

# owner/repo from the origin URL. Handles ssh, https, and https with a userinfo
# component (https://user@github.com/...), which a plain scheme strip misses.
repo_slug() {
  git -C "$CCMON_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#^[a-z]+://[^/@]*@?##; s#^git@[^:]*:##; s#^[^/]*/##; s#\.git$##'
}

summary() {
  printf '\n%s────────%s %s ok' "$C_DIM" "$C_RESET" "$N_OK"
  [ "$N_FIXED" -gt 0 ] && printf ', %s%s changed%s' "$C_YELLOW" "$N_FIXED" "$C_RESET"
  [ "$N_NEED"  -gt 0 ] && printf ', %s%s outstanding%s' "$C_YELLOW" "$N_NEED" "$C_RESET"
  [ "$N_FAIL"  -gt 0 ] && printf ', %s%s failed%s' "$C_RED" "$N_FAIL" "$C_RESET"
  printf '\n'
  if [ "$N_NEED" -gt 0 ] || [ "$N_FAIL" -gt 0 ]; then
    printf '%sRun ./ccmon again to continue where this left off.%s\n' "$C_DIM" "$C_RESET"
  fi
  [ "$N_FAIL" -eq 0 ]
}
