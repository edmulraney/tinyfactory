#!/usr/bin/env bash
# Hands a pull request over: pushes the branch, and marks it ready once GitHub reports the last commit as its head.
# Usage: hand-over.sh <pr-number>   (from the pull request's branch, with nothing left to commit; safe to run again)
set -euo pipefail

pr="${1:?Usage: hand-over.sh <pr-number>}"
die() { echo "$1 Pull request #$pr was not marked ready: run hand-over.sh $pr again." >&2; exit 1; }

last=$(git rev-parse HEAD) || die "The last commit could not be read from git."
git push -q origin HEAD || die "The push failed."

# The branch can hold a commit seconds before the pull request does, and the checks read the pull request (decisions A266c).
head=""
for _ in $(seq 1 18); do   # up to 90 seconds (decisions A542)
  head=$(gh api "repos/{owner}/{repo}/pulls/$pr" --jq '.head.sha') \
    || die "The head of pull request #$pr could not be read from GitHub."
  [ "$head" != "$last" ] || break
  sleep 5
done
[ "$head" = "$last" ] || die "After 90 seconds GitHub still reports ${head:-no commit} as the head of pull request #$pr, not the last commit, $last."

gh pr ready "$pr" || die "GitHub refused to mark it ready."
