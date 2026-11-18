#!/usr/bin/env bash
# The one writer of the `sessions` branch (decisions A98), sourced by save-session.sh, post-screenshots.sh, measures.sh.
# Usage: . sessions-branch.sh; push_to_sessions <commit-message> <command> [args]
#        Needs GH_TOKEN (contents: write) and GITHUB_REPOSITORY.

# <command> gets its args, then a fresh clone's path; non-zero, in silence, after six tries (decisions A17).
push_to_sessions() {
  local message="$1" work try
  shift
  for try in 1 2 3 4 5 6; do
    work=$(mktemp -d) || return 1
    if _sessions_attempt "$work" "$message" "$@"; then
      rm -rf "$work"
      return 0
    fi
    rm -rf "$work"
    # Several jobs push here as they finish, so a push can lose a race; a random wait keeps two losers apart.
    [ "$try" -eq 6 ] || sleep $((RANDOM % 4 + 1))
  done
  return 1
}

# After a lost race it starts again from a fresh clone and never rebases (decisions A18).
_sessions_attempt() {
  local work="$1" message="$2"
  shift 2
  local remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  # No clone means no branch yet; if it failed for another reason the push is refused, and the next try clones again.
  if ! git clone --quiet --depth 1 --branch sessions "$remote" "$work" 2>/dev/null; then
    git init --quiet --initial-branch sessions "$work" || return 1
    git -C "$work" remote add origin "$remote" || return 1
  fi
  # A runner has no committer identity, and git commits nothing without one.
  git -C "$work" config user.name "github-actions[bot]" || return 1
  git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com" || return 1
  "$@" "$work" || return 1
  # Vercel tries to build every branch, and this one holds no app: the file turns that off here (free-tier.md entry 3).
  if [ ! -f "$work/apps/web/vercel.json" ]; then
    mkdir -p "$work/apps/web" || return 1
    printf '{\n  "git": { "deploymentEnabled": false }\n}\n' > "$work/apps/web/vercel.json" || return 1
  fi
  git -C "$work" add -A || return 1
  # Nothing to commit when the branch already holds exactly these files, which is the aim.
  if ! git -C "$work" diff --cached --quiet; then
    git -C "$work" commit --quiet -m "$message" || return 1
    git -C "$work" push --quiet origin HEAD:sessions 2>/dev/null || return 1
  fi
  # A push can report success and the branch still not hold the commit; only GitHub's answer counts.
  [ "$(git -C "$work" ls-remote origin refs/heads/sessions 2>/dev/null | cut -f1)" = "$(git -C "$work" rev-parse HEAD 2>/dev/null)" ]
}
