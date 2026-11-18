#!/usr/bin/env bash
# Prints the branch an earlier build of a ticket left unfinished, or nothing.
# Usage: unfinished-work.sh <issue-number>   (in a checkout with `origin`; needs GH_TOKEN)
set -euo pipefail

issue="$1"

# Each is read on a line of its own: piped on, a failure would read as "no branch" or "no pull request" (decisions H7).
heads=$(git ls-remote --heads origin) \
  || { echo "Could not list the branches on GitHub, so it is not known whether an earlier build left work." >&2; exit 1; }
branch=$(sed 's|^.*refs/heads/||' <<<"$heads" | grep -E "^[a-z]+/$issue-" | head -n 1 || true)
[ -n "$branch" ] || exit 0

# A pull request marked ready, or closed, was handed over: only a draft is unfinished work (decisions A50a).
pulls=$(gh pr list --state all --head "$branch" --json state,isDraft --jq '[.[] | select(.state != "OPEN" or (.isDraft | not))] | length') \
  || { echo "Could not read the pull requests for $branch from GitHub, so it is not known whether it is unfinished." >&2; exit 1; }
[ "$pulls" -ne 0 ] || echo "$branch"
