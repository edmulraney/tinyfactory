#!/usr/bin/env bash
# Prints the section of metrics.md that shows production's usage by week beside the tickets deployed (decisions H666a).
# Usage: usage.sh <rows file> <tickets file>
#        The file holds what review-notes.yml's fixed query read from `usage_events`: a line for each week, then one for
#        each event in it, as week, event (empty on the week's own line), times and people, split by tabs. An empty file
#        means the database holds no such table, and nothing is printed; no file means it could not be read.
#        The tickets file holds, a line each, the tickets metrics.sh read as the merged pull requests' closing tickets,
#        with the labels put on them, as GitHub returns them. Needs GITHUB_REPOSITORY.
set -euo pipefail

rows="${1:?Usage: usage.sh <rows file> <tickets file>}"
tickets="${2:?Usage: usage.sh <rows file> <tickets file>}"
die() { echo "$1" >&2; exit 1; }

heading="## Usage by week"
if [ ! -e "$rows" ]; then
  printf '%s\n\n%s\n' "$heading" "Production's database could not be read, so this week's page shows no usage."
  exit 0
fi
[ -s "$rows" ] || exit 0

# A ticket `revert.sh` took back was labelled `deployed` before `reverted`, and was still deployed that week.
# shellcheck disable=SC2016
section='
  def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
  def plural(word; words): "\(.) " + (if . == 1 then word else words end);
  def cell: gsub("\\|"; "\\|");
  def row: "| " + join(" | ") + " |";
  ($rows | split("\n") | map(select(. != "") | split("\t") | {week: .[0], event: .[1], times: (.[2] | tonumber), people: (.[3] | tonumber)})) as $lines
  | ($lines | map(select(.event != "")) | map(.event) | unique) as $events
  | [$tickets[] | {number, title, weeks: [.timelineItems.nodes[] | select(.label.name? == "deployed") | .createdAt | at | strftime("%G-W%V")]}] as $deployed
  | "\($heading)", "",
    "Each of the last 12 weeks that have ended, from the `usage_events` table of the production database: the people active, then for each event the times it happened and the people it happened for, beside the tickets labelled `deployed` that week. A person is an account, so an event done with no account counts no person.", "",
    (["Week", "People active"] + ($events | map("`\(cell)`")) + ["Tickets deployed"] | row),
    (["Week", "People active"] + $events + ["Tickets deployed"] | map("---") | row),
    ($lines | map(select(.event == ""))[] | .week as $week
     | ($lines | map(select(.week == $week and .event != "")) | map({key: .event, value: .}) | from_entries) as $of
     | [$deployed[] | select(.weeks | index($week)) | "[#\(.number)](\($base)/issues/\(.number)) \(.title | cell)"] as $shipped
     | [$week, (.people | tostring)]
       + ($events | map(($of[.] // {times: 0, people: 0}) | "\(.times | plural("time"; "times")) by \(.people | plural("person"; "people"))"))
       + [if $shipped == [] then "None" else $shipped | join("; ") end]
     | row)'
jq -rn --rawfile rows "$rows" --slurpfile tickets "$tickets" --arg heading "$heading" \
    --arg base "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY" "$section" \
  || die "The usage read from production's database could not be shown by week, so the usage by week is not written."
