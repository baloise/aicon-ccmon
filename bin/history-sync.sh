#!/usr/bin/env bash
# Push this machine's usage samples to the repo's `data` branch, refresh the
# manifest the wallboard reads, and keep that branch's git history compact.
#
# The data files are append-only, so per-commit diffs carry no information worth
# keeping: once the branch exceeds COMPACT_AFTER commits it is rewritten to a
# single orphan commit holding the current state. Rewrites use
# --force-with-lease, so a race with another machine fails safely and simply
# retries on the next run - no samples are lost, because we always fetch first.

set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CCMON_DIR="$CLAUDE_DIR/ccmon"
HISTORY_DIR="$CCMON_DIR/history"
# Opaque per-machine id, written by the poller. Never the hostname - see
# bin/usage-poll.sh for why.
HOST=$(cat "$CCMON_DIR/machine-id" 2>/dev/null)
[ -n "$HOST" ] || { echo "no machine id yet; run the poller first" >&2; exit 0; }
COMPACT_AFTER="${CCMON_COMPACT_AFTER:-100}"
MINE="data/$HOST.jsonl"
MINE_LATEST="data/$HOST.latest.json"

[ -d "$HISTORY_DIR/.git" ] || { echo "no history clone at $HISTORY_DIR" >&2; exit 0; }
cd "$HISTORY_DIR" || exit 0

git config user.name  >/dev/null 2>&1 || git config user.name  "ccmon"
git config user.email >/dev/null 2>&1 || git config user.email "ccmon@localhost"

if ! git fetch -q origin data 2>/dev/null; then
  echo "fetch failed (offline?)" >&2
  exit 0
fi

# Our own files are authoritative for this machine and only ever grow. Take the
# remote's view of everything else, then put ours back.
keep=$(mktemp -d)
for f in "$MINE" "$MINE_LATEST"; do
  [ -f "$f" ] && cp "$f" "$keep/$(basename "$f")"
done
git reset -q --hard origin/data
mkdir -p data
for f in "$MINE" "$MINE_LATEST"; do
  [ -f "$keep/$(basename "$f")" ] && mv "$keep/$(basename "$f")" "$f"
done
rm -rf "$keep"

# The reset above restores this machine's pre-machine-id files from the remote,
# whose samples the poller has already merged into ours. Only ever retire our
# own former name - another machine's files are not ours to delete.
legacy=$(hostname -s 2>/dev/null || hostname)
if [ -n "$legacy" ] && [ "$legacy" != "$HOST" ] && [ -f "$MINE" ]; then
  for f in "data/$legacy.jsonl" "data/$legacy.latest.json"; do
    [ -f "$f" ] && git rm -q --ignore-unmatch "$f" 2>/dev/null
  done
fi

# The wallboard and its drawing library are served from this branch, so keep
# the published copies in step with whatever ccmon installed locally.
for pair in "wallboard.html:index.html" "chart-lib.js:chart-lib.js"; do
  src="$CCMON_DIR/${pair%%:*}"; dst="${pair##*:}"
  [ -f "$src" ] && { cmp -s "$src" "$dst" 2>/dev/null || cp "$src" "$dst"; }
done
# Without this, GitHub Pages runs Jekyll and hides everything under data/.
[ -f .nojekyll ] || : > .nojekyll

# Rebuild the manifest from every machine's latest reading. Deterministic given the
# same inputs, so two machines regenerating it converge rather than fight.
if ls data/*.latest.json >/dev/null 2>&1; then
  {
    echo '{'
    echo "  \"generated\": $(date +%s),"
    echo '  "sources": ['
    first=1
    for l in data/*.latest.json; do
      h=$(basename "$l" .latest.json)
      n=$(wc -l < "data/$h.jsonl" 2>/dev/null || echo 0)
      [ $first -eq 1 ] || echo ','
      first=0
      printf '    {"source": %s, "file": "data/%s.jsonl", "samples": %s, "latest": %s}' \
        "$(jq -Rn --arg h "$h" '$h')" "$h" "$n" "$(cat "$l")"
    done
    echo
    echo '  ]'
    echo '}'
  } > data/index.json.tmp && mv -f data/index.json.tmp data/index.json
fi

git add -A -- data index.html chart-lib.js .nojekyll 2>/dev/null
if git diff --cached --quiet 2>/dev/null; then
  exit 0   # nothing new since the last sync
fi

n=$(wc -l < "$MINE" 2>/dev/null || echo 0)
git commit -q -m "ccmon: $n samples" || exit 0

# "data" is both a branch and a directory here, so name the ref unambiguously.
commits=$(git rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$commits" -le "$COMPACT_AFTER" ]; then
  git push -q origin data 2>/dev/null || echo "push failed" >&2
  exit 0
fi

# Compact: replace the whole branch with one commit holding the current tree.
lease=$(git rev-parse origin/data 2>/dev/null)
git checkout -q --orphan _compact
git add -A
git commit -q -m "ccmon data, compacted $(date -I) ($(cat data/*.jsonl 2>/dev/null | wc -l) samples)"
git branch -q -M _compact data
if git push -q --force-with-lease="data:$lease" origin data 2>/dev/null; then
  git reflog expire --expire=now --all >/dev/null 2>&1
  git gc --prune=now -q >/dev/null 2>&1
else
  echo "compaction lost the race; retrying next run" >&2
fi
