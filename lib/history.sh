# shellcheck shell=bash
# Stage 8: git-backed usage history.
#
# Samples are appended to a clone of this repo's orphan `data` branch, pushed
# hourly. A dedicated clone under ~/.claude/ccmon/ rather than your working
# checkout, so automated commits can never sweep up work in progress.

HISTORY_DIR="$CCMON_DIR/history"

stage_history() {
  stage 8 "Usage history"

  local remote
  remote=$(git -C "$CCMON_ROOT" remote get-url origin 2>/dev/null)
  if [ -z "$remote" ]; then
    skip "no git remote - history needs somewhere to push"
    return 0
  fi

  if [ -d "$HISTORY_DIR/.git" ]; then
    ok "history clone present"
  else
    need "no history clone yet - samples are not being kept"
    info "A separate clone of the 'data' branch, so ccmon's commits stay out of"
    info "your working checkout."
    confirm || { info "skipped - ccmon still shows current usage, just no history"; return 0; }
    if git clone -q --branch data --single-branch "$remote" "$HISTORY_DIR" 2>/dev/null; then
      fixed "cloned the data branch to $HISTORY_DIR"
    else
      fail "clone failed - does the 'data' branch exist on the remote?"
      hint "Create it once with: git checkout --orphan data && git rm -rf . && mkdir data && git commit && git push -u origin data"
      return 1
    fi
  fi

  mkdir -p "$HISTORY_DIR/data"
  install_file "$CCMON_ROOT/bin/history-sync.sh" "$CCMON_DIR/history-sync.sh" 755 "history sync"
  install_file "$CCMON_ROOT/bin/chart.sh"            "$CCMON_DIR/chart.sh"      755 "chart generator"
  install_file "$CCMON_ROOT/wallboard/index.html"    "$CCMON_DIR/wallboard.html" 644 "wallboard page"
  install_file "$CCMON_ROOT/wallboard/chart-lib.js"  "$CCMON_DIR/chart-lib.js"   644 "chart library"

  sched_install sync
  sched_enable sync

  local n
  n=$(cat "$HISTORY_DIR"/data/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    ok "$n samples recorded"
    info "Chart them with: $CCMON_DIR/chart.sh   (writes $CCMON_DIR/chart.html)"
  else
    info "no samples yet - the first arrives within 5 minutes"
  fi
}
