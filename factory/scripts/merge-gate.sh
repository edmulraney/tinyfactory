#!/usr/bin/env bash
# The merge gate: ships a pull request both reviews passed, or holds for the owner one only they may decide.
# Usage: merge-gate.sh <pr-number> <head-sha> <owner-login>
#        Needs what ship.sh needs: GH_TOKEN, PRODUCTION_URL and, when set, BOARD_TOKEN. Run from the root of main's checkout.
set -euo pipefail

pr="$1"; head="$2"; owner="$3"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

# Read on a line of its own (decisions H7).
files=$(retry gh pr diff "$pr" --name-only) \
  || not_merged "GitHub did not list the files this pull request changes, so whether it needs a person is not known"
# Any end of protected-paths.sh but a clean "none" is a change to the factory's files (decisions M2).
if protected=$("$script_dir/protected-paths.sh" <<<"$files"); then touches=false; else touches=true; fi

# Read on a line of its own (decisions H7). The comments hold the reviewers' assumptions.
reviews=$(retry gh pr view "$pr" --json reviews,comments) \
  || not_merged "GitHub did not return this pull request's reviews, so whether the owner approved it or sent it back is not known"
# The same test approve-merge.sh makes (decisions M23).
approved=$(jq -r --arg owner "$owner" --arg head "$head" \
  '[.reviews[] | select(.author.login == $owner)] | last | (.state == "APPROVED" and .commit.oid == $head)' <<<"$reviews")
if [ "$approved" = true ]; then
  exec "$script_dir/ship.sh" "$pr" "$head"
fi
# A review that only comments is no verdict, and dismissing the review takes the request back (decisions M48).
sent_back=$(jq -r --arg owner "$owner" \
  '[.reviews[] | select(.author.login == $owner and .state != "COMMENTED" and .state != "PENDING")] | last | .state == "CHANGES_REQUESTED"' <<<"$reviews")

issue=$(retry "$script_dir/linked-issue.sh" "$pr") \
  || not_merged "GitHub did not return this pull request's description, so the ticket it closes is not known"
# What holds it, and the lines that show it.
hold=""; shown=""
if [ "$touches" = true ]; then
  factory=false
  [ -z "$issue" ] || factory=$(retry gh issue view "$issue" --json labels --jq '[.labels[].name] | index("factory") != null') \
    || not_merged "GitHub did not return the labels of ticket #$issue, so whether it is a \`factory\` ticket, which may change the factory's files, is not known"
  # Decisions M272c.
  [ "$factory" = true ] || { hold="changes files only a \`factory\` ticket may change, and it closes none"; shown="$protected"; }
fi
if [ -z "$hold" ]; then
  # Asked of every pull request: the product's bar is held on any type of ticket (decisions M272e).
  diff=$(retry gh pr diff "$pr") \
    || not_merged "GitHub did not return this pull request's diff, so whether it changes what only the owner may decide is not known"
  # Any end of owner-decides.sh but a clean "nothing" holds the pull request (decisions M272a).
  if ! shown=$("$script_dir/owner-decides.sh" <<<"$diff" 2>&1); then
    hold="changes what only the repo owner may decide"
  # The installer that runs is the installed copy, and an older one refuses what nobody approved (decisions W272c).
  elif grep -q '^factory/workflows/' <<<"$files" \
      && ! cmp -s factory/workflows/install-workflows.yml .github/workflows/install-workflows.yml; then
    hold="changes a workflow while the installer that runs is not yet the one \`main\` holds, and that one may refuse a change nobody approved"
    shown=$(grep '^factory/workflows/' <<<"$files")
  fi
fi
if [ -z "$hold" ] && [ "$sent_back" != true ]; then
  exec "$script_dir/ship.sh" "$pr" "$head"
fi

# Each reviewer's latest verdict counts, and its list is the hidden last line of it (decisions A55b, A55c).
# A verdict from before the install holds `unverified` claims in three parts (decisions A224b).
assumptions=$(jq -r '
  reduce (.comments[].body | select(test("^\\*\\*[^*\n]+: (PASS|FAIL)\\*\\*"))) as $body ({};
    .[$body | capture("^\\*\\*(?<who>[^*\n]+): ").who] =
      [$body | [split("\n")[] | select(. != "")] | last
       | capture("^<!-- factory:(assumptions|unverified) (?<list>.*) -->$") | .list | fromjson | .[]])
  | to_entries[] | .key as $reviewer | .value[]
  | "- **\($reviewer):** Assumes: \(.assumes // .claim)\n  If wrong: \(.if_wrong // .risk)"' <<<"$reviews") \
  || not_merged "The reviewers' assumptions could not be read from their verdicts, so the owner cannot be shown them"
[ -z "$assumptions" ] || assumptions="**Before you approve, what the reviewers could not check:**"$'\n\n'"$assumptions"$'\n\n'
# The first line says what a person must do (decisions A371a).
if [ -n "$hold" ]; then
  body=$(printf 'Approve this pull request: it merges as soon as the repo owner approves.\n\n%sBoth reviews passed, but this pull request %s:\n\n```\n%s\n```\n' "$assumptions" "$hold" "$shown")
else
  body="Approve this pull request, or submit a \"Request changes\" review: an approval merges it, and a review sends it back to its engineer.

${assumptions}Both reviews passed, but the repo owner asked for changes to this pull request, so only they can say it is now right."
fi
retry gh pr comment "$pr" --body "$body" >/dev/null
retry gh pr edit "$pr" --add-label needs-human >/dev/null
# The build is over; what is left is a person's decision, so the ticket is no longer in progress.
[ -z "$issue" ] || retry gh issue edit "$issue" --remove-label in-progress --add-label needs-human >/dev/null
# It holds no place among the tickets being built now, so a ticket that waits takes it (decisions T361c).
"$script_dir/start-waiting.sh" || {
  echo "Pull request #$pr waits for the owner, and the tickets that wait with ready were not all started; each is started when a place next frees." >&2
  exit 1
}
