#!/usr/bin/env bash
# Starts, after a merge, the fix round of each open pull request labelled `waits-for-main` or sent back by its owner.
# Usage: start-retests.sh
#        Needs GH_TOKEN (pull-requests: read; actions: write) and GITHUB_REPOSITORY, whose owner is the repo's.
#        A call to GitHub that fails ends in a message and exit 1, once every other round has been asked for.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository="${GITHUB_REPOSITORY:?start-retests.sh needs GITHUB_REPOSITORY, to know who the owner is}"
owner="${repository%%/*}"

die() { echo "$1" >&2; exit 1; }

# `app/claude` is how gh writes the app that opens the factory's pull requests. A draft is still being built (decisions A50b).
open=$(gh pr list --state open --limit 100 --json number,author,labels,isDraft \
    --jq '.[] | select(.author.login == "app/claude" and (.isDraft | not)) | "\(.number) \([.labels[].name] | index("waits-for-main") != null)"') \
  || die "The open pull requests could not be read from GitHub, so after this merge none labelled waits-for-main is tested again, and no owner's fix round is started."

started=0; failed=""
while read -r pr marked; do
  [ -n "$pr" ] || continue
  if [ "$marked" = true ]; then
    # Its one round is the owner's too, if the owner sent it back (decisions A368a).
    what="the fix round that tests pull request #$pr with main again"
  else
    # begin-fix-round.sh refuses the round of a request that has had one (decisions A396a, A396b).
    if ! review=$("$script_dir/owner-review.sh" "$pr" "$owner"); then failed+=" #$pr"; continue; fi
    [ -n "$review" ] || continue
    what="fix.yml for pull request #$pr, which its owner sent back: the owner's fix round begins unless that request has had one"
  fi
  # fix.yml itself: start-fix-round.sh starts no round for a marked pull request (decisions A368b, A368c).
  if gh workflow run fix.yml -f pr="$pr" >/dev/null; then
    echo "started $what"
    started=$((started + 1))
  else
    failed+=" #$pr"
  fi
done <<<"$open"
[ -z "$failed" ] || die "After this merge, whether these pull requests wait for a fix round could not be read, or the round could not be started:$failed. The next merge starts it."
[ "$started" -ne 0 ] || echo "no pull request is labelled waits-for-main, and none waits for its owner's fix round: no fix round is started"
