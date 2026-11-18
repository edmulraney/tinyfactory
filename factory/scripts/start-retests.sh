#!/usr/bin/env bash
# Starts, after a merge, the fix round that tests again each open pull request labelled `waits-for-main`.
# Usage: start-retests.sh
#        Needs GH_TOKEN (pull-requests: read; actions: write).
#        A call to GitHub that fails ends in a message and exit 1, once every other round has been asked for.
set -euo pipefail

die() { echo "$1" >&2; exit 1; }

# `app/claude` is how gh writes the app that opens the factory's pull requests. A draft is still being built (decisions A50b).
marked=$(gh pr list --state open --limit 100 --json number,author,labels,isDraft \
    --jq '.[] | select(.author.login == "app/claude" and (.isDraft | not) and ([.labels[].name] | index("waits-for-main") != null)) | .number') \
  || die "The open pull requests could not be read from GitHub, so none labelled waits-for-main is tested again after this merge."
[ -n "$marked" ] || { echo "no pull request is labelled waits-for-main: none is tested again"; exit 0; }

failed=""
while read -r pr; do
  # fix.yml itself: start-fix-round.sh starts no round for a marked pull request (decisions A368b, A368c).
  if gh workflow run fix.yml -f pr="$pr" >/dev/null; then
    echo "started the fix round that tests pull request #$pr with main again"
  else
    failed+=" #$pr"
  fi
done <<<"$marked"
[ -z "$failed" ] || die "The fix round that tests these pull requests with main again could not be started:$failed. Each keeps waits-for-main, and the next merge starts it."
