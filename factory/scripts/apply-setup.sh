#!/usr/bin/env bash
# Applies a merged pull request's changes to the setup scripts, running each one the factory holds a credential for.
# Usage: apply-setup.sh <pr-number> [merge-commit]
#        Needs GH_TOKEN (contents: read, pull-requests and issues: write). BOARD_TOKEN is optional.
set -euo pipefail

pr="$1"
script_dir="$(cd "$(dirname "$0")" && pwd)"
dir=".claude/skills/bootstrap/scripts"

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
# Read on a line of its own, so a failed listing stops here. The files endpoint, not `gh pr diff` (decisions H7, U10).
files=$(gh api "repos/$repo/pulls/$pr/files" --paginate --jq '.[].filename')
changed=$(grep -E "^$dir/[^/]+\.sh$" <<<"$files" || true)
[ -n "$changed" ] || { echo "pull request #$pr changed no setup script; nothing to apply"; exit 0; }

# ship.sh passes the commit when it found the merge on main itself (decisions M27).
commit="${2:-}"
[ -n "$commit" ] || commit=$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""')
[ -n "$commit" ] || { echo "pull request #$pr is not merged; nothing to apply"; exit 1; }

# This checkout is main before the merge. The merged copy passed the merge gate, and the owner approved one given a secret (decisions M272a).
tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
gh api "repos/$repo/tarball/$commit" | tar -xz --strip-components=1 -C "$tree"

body="$tree/.apply-setup-comment.md"
: > "$body"
waiting=0
failed=0

run() {
  local script="$1" out status=0
  shift
  out=$("$@" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    printf 'Applied `%s` (as merged in %s):\n\n' "$script" "${commit:0:7}" >> "$body"
  else
    printf 'Ran `%s` (as merged in %s by pull request #%s) and it failed with exit %s, so its change may not be in effect:\n\n' \
      "$script" "${commit:0:7}" "$pr" "$status" >> "$body"
    waiting=1
    failed=1
  fi
  # The end of the output is where a script says what it did; a comment holds 65,536 characters.
  printf '```\n%s\n```\n\n' "$(tail -c 20000 <<<"$out")" >> "$body"
}

needs_owner() {
  printf '`%s` changed, and %s. The change takes effect the next time setup runs with the owner'"'"'s logins: `%s/%s %s`.\n\n' \
    "$1" "$2" "$dir" "$1" "${repo#*/}" >> "$body"
  waiting=1
}

while IFS= read -r path; do
  script=$(basename "$path")
  [ -f "$tree/$path" ] || continue
  case "$script" in
    board.sh)
      if [ -n "${BOARD_TOKEN:-}" ]; then
        # Only the board token: the script gets no credential that can see a repo.
        run "$script" env -u BOARD_TOKEN GH_TOKEN="$BOARD_TOKEN" bash -c 'cd "$1" && "$2" "$3"' _ "$tree" "$tree/$path" "${repo#*/}"
      else
        needs_owner "$script" "this run was not given the \`BOARD_TOKEN\` secret that lets the factory run it"
      fi ;;
    labels.sh)
      # The workflow's own token is enough, so the board token is kept from it.
      run "$script" env -u BOARD_TOKEN bash -c 'cd "$1" && "$2" "$3"' _ "$tree" "$tree/$path" "$repo" ;;
    preflight.sh | scaffold.sh | purpose.sh | bootstrap.sh | present.sh)
      echo "$script changed; it has nothing to apply to a project that is already set up" ;;
    *)
      # Also a script added later that nobody listed: the factory stores no credential for it (decisions U2).
      needs_owner "$script" "the factory holds no credential that can run it" ;;
  esac
done <<<"$changed"

[ -s "$body" ] || exit 0
issue=""
[ "$waiting" -eq 0 ] || issue=$("$script_dir/linked-issue.sh" "$pr")
# The first line says what a person must do (decisions A371a).
if [ "$waiting" -eq 1 ]; then
  printf 'Run by hand, with your own logins, each setup script below that failed or was not run: the factory does not run it again.\n\n' | cat - "$body" > "$body.todo"
  mv "$body.todo" "$body"
fi
# A failure is told to the ticket, and fails this script (decisions U9).
if [ "$failed" -eq 1 ] && [ -n "$issue" ]; then gh issue comment "$issue" --body-file "$body"
else gh pr comment "$pr" --body-file "$body"
fi
if [ "$waiting" -eq 1 ]; then
  if [ -n "$issue" ]; then gh issue edit "$issue" --add-label needs-human >/dev/null
  else gh pr edit "$pr" --add-label needs-human >/dev/null
  fi
fi
[ "$failed" -eq 0 ] || { echo "a setup script failed after the merge of pull request #$pr; its output is in the comment, and a person was asked" >&2; exit 1; }
