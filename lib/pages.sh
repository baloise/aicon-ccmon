# shellcheck shell=bash
# Stage 11: publish the wallboard through GitHub Pages.
#
# A public repo gets a public site. A private repo on Enterprise Cloud gets a
# private one: viewing it needs a signed-in GitHub session, which is fine at a
# desk and awkward for an unattended screen - that is what `ccmon serve` is for.

stage_pages() {
  stage 11 "GitHub Pages"

  local slug
  slug=$(git -C "$CCMON_ROOT" remote get-url origin 2>/dev/null \
         | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')
  if [ -z "$slug" ]; then
    skip "no GitHub remote"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    skip "gh CLI not installed - cannot check or enable Pages"
    hint "Enable by hand: Settings -> Pages -> Deploy from a branch -> 'data' / (root)"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    skip "gh is not authenticated (gh auth login)"
    return 0
  fi

  local pages
  if pages=$(gh api "repos/$slug/pages" 2>/dev/null); then
    local branch path url public
    branch=$(printf '%s' "$pages" | jq -r '.source.branch // "-"')
    path=$(printf '%s' "$pages"  | jq -r '.source.path // "-"')
    url=$(printf '%s' "$pages"   | jq -r '.html_url // "-"')
    public=$(printf '%s' "$pages"| jq -r 'if .public then "public" else "private" end')
    if [ "$branch" = "data" ]; then
      ok "Pages serving $branch$path ($public)"
    else
      need "Pages is serving '$branch', not the 'data' branch"
      info "The wallboard and its data live on 'data'."
    fi
    info "$url"
    [ "$public" = "private" ] && info "Private site: opening it needs a signed-in GitHub session."
    info "For an unattended screen use: ./ccmon serve"
    return 0
  fi

  need "Pages is not enabled - the wallboard is not published"
  cat <<EXPLAIN

        Turning this on serves the 'data' branch at a github.io URL:
          index.html        the wallboard
          data/*.jsonl      the raw samples
          data/index.json   the manifest the page polls

        A public repo gets a public site at <org>.github.io/<repo>. A private
        one on Enterprise Cloud gets a randomised hostname and requires a
        signed-in GitHub session, and enterprise policy may refuse to make it
        public at all. A wallboard that cannot hold a session should point at
        ./ccmon serve.

EXPLAIN
  confirm || { info "skipped - nothing published; ./ccmon serve still works locally"; return 0; }

  if gh api -X POST "repos/$slug/pages" -f "source[branch]=data" -f "source[path]=/" \
       >/dev/null 2>&1; then
    fixed "Pages enabled on the data branch"
    sleep 2
    gh api "repos/$slug/pages" --jq '.html_url' 2>/dev/null \
      | while read -r u; do info "$u (first build takes a minute)"; done
  else
    fail "could not enable Pages"
    hint "Do it by hand: Settings -> Pages -> Deploy from a branch -> 'data' / (root)"
  fi
}
