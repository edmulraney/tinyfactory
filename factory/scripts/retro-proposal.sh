#!/usr/bin/env bash
# Prints the proposal a retro's saved lesson files, as a ticket's body, or nothing for a lesson below the bar.
# Usage: retro-proposal.sh <lesson-file>   (as retro.yml saves it: {pr, issue, facts, lesson})
set -euo pipefail

file="${1:?Usage: retro-proposal.sh <lesson-file>}"
die() { echo "$1" >&2; exit 1; }

jq -e '(.lesson | type == "object") and (.facts | type == "object")' "$file" >/dev/null 2>&1 \
  || die "The lesson in $file could not be read, so whether it files a proposal is not known."

# A figure in the cost and the saving, and a loss, a stop or a repeat (decisions A223a, A223b).
below=$(jq -r '
  # A link or the number of an issue holds a digit and is no figure.
  def figure: (. // "" | tostring | gsub("https?://[^ ]+|#[0-9]+"; "") | test("[0-9]"));
  # Lost work is one fact the lesson can hold in two fields, so either counts.
  def lost: ((.cost.kind // []) | length) > 0 or ((.handling // []) | index("lost-work")) != null;
  .lesson
  | if .propose != true or (.change.kind // "none") == "none" then "the retro proposes no change"
    elif (.cost.amount | figure | not) then "the lesson gives no figure for what the fault cost"
    elif (.saves | figure | not) then "the lesson gives no figure for what the change saves"
    elif (lost | not) and ((.repeats // []) | length) == 0
    then "the run lost no work or money, did not stop for a person and repeats no earlier lesson"
    else "" end' "$file") \
  || die "The lesson in $file could not be judged, so whether it files a proposal is not known."
if [ -n "$below" ]; then
  echo "no proposal: $below. The lesson is saved." >&2
  exit 0
fi

# The body follows the factory ticket template, so Fred can build the ticket as it is (decisions A184b, A173).
body=$(jq -r '
  (if .facts.changed_by then "the first run of `\(.facts.workflow)` since pull request #\(.facts.changed_by.pr) changed it, \(.facts.url)"
   elif .facts.run then "the failed `\(.facts.workflow)` run \(.facts.url)" else "pull request #\(.pr)" end) as $seen
  | "## Change\n\n`\(.lesson.change.target)` (\(.lesson.change.kind))\n\n\(.lesson.change.proposal)\n\nRemoves: \(.lesson.change.removes)\n\n"
  + "## How we will know it works\n\n\(.lesson.saves)\n\n"
  + "## Evidence\n\nWhat the fault cost: \(.lesson.cost.amount)"
  + (if (.lesson.cost.kind | length) > 0 then " (\(.lesson.cost.kind | join(", ")))" else "" end)
  + "\n\n\(.lesson.evidence | map("- " + .) | join("\n"))\n\nSeen in \($seen)"
  + (if (.lesson.repeats | length) > 0
     then " and in these earlier lessons on the `sessions` branch:\n\n\(.lesson.repeats | map("- `lessons/" + . + "`") | join("\n"))"
     else "." end)
  + (if (.lesson.handling | length) > 0
     then "\n\nHow the factory handled the failure: \(.lesson.handling | join(", ")). Would trying again have been enough: \(.lesson.retry)."
     else "" end)
  + "\n\nProposed by a retro. Add `ready` to have Fred build it, or close it."' "$file") \
  || die "The proposal of the lesson in $file could not be written, so nothing is filed."
sed 's/@claude/claude/g' <<<"$body"
