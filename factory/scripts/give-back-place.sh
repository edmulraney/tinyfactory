#!/usr/bin/env bash
# Gives back the place of a build whose job ended before the engineer ran, and asks for a person (decisions T64g).
# Usage: give-back-place.sh <issue-number> [notified]
#        notified  `true` when the ticket already carries a comment saying why it was not built.
#        Needs GH_TOKEN (issues and actions: write; pull requests: read) and GITHUB_REPOSITORY.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

issue="${1:?Usage: give-back-place.sh <issue-number> [notified]}"
notified="${2:-}"

die() { echo "$1" >&2; exit 1; }

# The number goes into calls, so anything that is not one is refused.
[[ "$issue" =~ ^[0-9]+$ ]] || die "\"$issue\" is not an issue number."

# The label first: a place given back and not explained costs less than one explained and still held.
gh issue edit "$issue" --remove-label in-progress --add-label needs-human >/dev/null \
  || die "The build of issue #$issue never began, and in-progress could not be taken off it: it holds a place with no build until the label is removed by hand."

# Only a ticket told why passes its place to one that waits (decisions T297a, T297b).
if [ "$notified" = true ]; then
  echo "gave back the place of issue #$issue, which was told why it was not built"
  "$script_dir/start-waiting.sh" \
    || die "Issue #$issue gave its place back, and the tickets that wait with ready were not all started; each is started when a place next frees."
  exit 0
fi

run_link=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_link=" See $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
# The first line says what a person must do (decisions A371a).
gh issue comment "$issue" --body "Add the \`ready\` label again: the build starts when a place is free.

The build of this ticket never began: its job ended before the engineer started. Nothing was built, and its place among the tickets in flight was given back.$run_link" >/dev/null \
  || die "The build of issue #$issue never began and its place was given back, but it could not be told so."
echo "gave back the place of issue #$issue: its build never began"
