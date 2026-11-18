#!/usr/bin/env bash
# Says whether a commit is worth a review, as `review=true` or `review=false` on stdout: a build's empty first is not.
# Usage: needs-review.sh <base-branch> <head-sha>   (needs GH_TOKEN and GITHUB_REPOSITORY)
set -euo pipefail

base="${1:?Usage: needs-review.sh <base-branch> <head-sha>}"
head="${2:?Usage: needs-review.sh <base-branch> <head-sha>}"

emit() { echo "$2" >&2; echo "review=$1"; exit 0; }

# The commit the run began for, not the branch as it is now: a push may land while the run waits (decisions A266a).
# A read that fails starts the reviews, and the exit is still 0 (decisions A266b).
ahead=$(gh api "repos/${GITHUB_REPOSITORY:-}/compare/$base...$head" --jq '"\(.ahead_by) \(.files | length)"') \
  || emit true "Could not read from GitHub what commit ${head:0:7} adds to $base, so it is reviewed."

if [ "$ahead" = "1 0" ]; then
  emit false "Commit ${head:0:7} is the only one on its branch and changes no file: the build's empty first commit, so no review starts."
fi
emit true "Commit ${head:0:7} is not a build's empty first commit alone, so it is reviewed."
