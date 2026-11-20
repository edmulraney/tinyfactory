#!/usr/bin/env bash
# Counts a fix round after the engineer's step, unless the usage limit ended its session, and flags one that never ran.
# Usage: record-fix-round.sh <pr-number> <execution-file> [counted] [head] [review]
#        <execution-file>  the one the engineer's step, or its last continuation, left; may be empty.
#        [counted]         what begin-fix-round.sh wrote: `false`, `conflict`, `retest`, `start-checks` and `fresh-run:<id>` leave a round uncounted.
#        [head]            the commit the round began with, also from begin-fix-round.sh.
#        [review]          the id of the owner's review the owner's round was begun for, also from begin-fix-round.sh.
#        Needs GH_TOKEN (pull-requests and issues: write) and, for the owner's round, flag-ticket.sh.
set -euo pipefail

pr="${1:?Usage: record-fix-round.sh <pr-number> <execution-file> [counted]}"; file="${2:-}"; counted="${3:-true}"; head="${4:-}"; review="${5:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

# A round that never ran leaves no count behind (decisions A89c).
if [ -n "$file" ] && [ -s "$file" ]; then
  # Nor does one the Claude usage limit ended: the limit refused the attempt, and no marker of any kind is written (decisions A395d).
  if [ "$("$script_dir/session-ending.sh" "$file")" = usage_limit ]; then
    echo "the Claude usage limit ended the fix round on pull request #$pr: it is not counted"
    exit 0
  fi
  # The owner asking again is a decision, not a loop, and its marker gets a retro (decisions A48a, A48d).
  if [ "$counted" = false ]; then
    # Its marker names the review: a request gets one such round, and a later request its own (decisions A396b).
    gh pr comment "$pr" --body "<!-- factory:owner-round ${review:+$review }-->The owner's fix round: the engineer's session ran. It is not one of the three fix rounds." >/dev/null \
      || die "The owner's fix round on pull request #$pr ran, but could not be recorded: the comment that records it could not be posted."
    echo "the owner's fix round ran on pull request #$pr: it is recorded, and not counted"
    exit 0
  fi
  # Its marker names the head: a pull request gets one such round for each head (decisions A124b, A124g).
  if [ "$counted" = conflict ]; then
    # fix.yml as it was before it passed the head still runs between a merge and the install of the workflow.
    if [ -z "$head" ]; then
      echo "the fix round for a conflict ran on pull request #$pr: it is not counted, and not recorded, as the head it began with was not given"
      exit 0
    fi
    gh pr comment "$pr" --body "<!-- factory:conflict-round $head -->The fix round for a conflict: the engineer's session ran, on ${head:0:7}. It is not one of the three fix rounds." >/dev/null \
      || die "The fix round for a conflict on pull request #$pr ran, but could not be recorded: the comment that records it could not be posted."
    echo "the fix round for a conflict ran on pull request #$pr at ${head:0:7}: it is recorded, and not counted"
    exit 0
  fi
  # No marker: the label that began it came off as it began, and only another mark begins another (decisions A368a).
  if [ "$counted" = retest ]; then
    echo "the fix round for a retest ran on pull request #$pr: it is not counted"
    exit 0
  fi
  # No marker either: approve-merge.sh starts one for a commit (decisions M543b).
  if [ "$counted" = start-checks ]; then
    echo "the fix round to start the checks ran on pull request #$pr: it is not counted"
    exit 0
  fi
  # Its marker names the ci.yml main held: one such round for each (decisions A142a, A142b).
  if [[ "$counted" == fresh-run:* ]]; then
    workflow="${counted#fresh-run:}"
    gh pr comment "$pr" --body "<!-- factory:fresh-run-round $workflow -->The fix round for a fresh run: the engineer's session ran. It is not one of the three fix rounds." >/dev/null \
      || die "The fix round for a fresh run on pull request #$pr ran, but could not be recorded: the comment that records it could not be posted."
    echo "the fix round for a fresh run ran on pull request #$pr: it is recorded, and not counted"
    exit 0
  fi
  rounds=$("$script_dir/fix-rounds.sh" "$pr") \
    || die "The fix round on pull request #$pr ran, but could not be counted: the rounds before it could not be read."
  # The marker fix-rounds.sh counts, at the very start of the comment (decisions A28).
  gh pr comment "$pr" --body "<!-- factory:fix-round -->Fix round $((rounds + 1)) of 3: the engineer's session ran." >/dev/null \
    || die "The fix round on pull request #$pr ran, but could not be counted: the comment that counts it could not be posted."
  echo "counted fix round $((rounds + 1)) of 3 for pull request #$pr"
  exit 0
fi

# The Claude action can skip itself and exit 0, so a round with no session fails and asks for a person (decisions A89d).
run_link=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_link=" The log says which: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
# The first line says what a person must do (decisions A371a).
message="Run \`gh workflow run fix.yml -f pr=$pr\`: a new fix round starts.

The fix round did not run: no engineer's session began, so nothing was fixed and the round is not counted. The Claude action skipped itself, or it or a step before it failed.$run_link"
echo "$message" >&2
gh pr comment "$pr" --body "$message" >/dev/null \
  || die "Could not say on pull request #$pr that its fix round did not run."
gh pr edit "$pr" --add-label needs-human >/dev/null \
  || die "Could not add needs-human to pull request #$pr, whose fix round did not run."
# The owner's round took `needs-human` off the ticket too as it began (decisions A48c).
[ "$counted" != false ] || "$script_dir/flag-ticket.sh" "$pr" || exit 1
exit 1
