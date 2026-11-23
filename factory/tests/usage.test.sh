#!/usr/bin/env bash
# Tests for usage.sh, which prints the section of metrics.md that shows production's usage beside the tickets deployed.
. "$(dirname "$0")/helpers.sh"

# no_tickets: empties $T/deployed, which holds the tickets metrics.sh passes, a line each, as a_ticket writes them.
no_tickets() {
  : > "$T/deployed"
  export GITHUB_REPOSITORY=owner/repo
}
# a_ticket <number> <title> [<label> <put on at>]...: a ticket and the labels put on it.
a_ticket() {
  local number="$1" title="$2" events=""
  shift 2
  while [ $# -gt 0 ]; do
    events+=$(jq -nc --arg name "$1" --arg at "$2" '{createdAt: $at, label: {name: $name}}')$'\n'
    shift 2
  done
  jq -sc --argjson number "$number" --arg title "$title" '{number: $number, title: $title, timelineItems: {nodes: .}}' <<<"$events" >> "$T/deployed"
}
# week <week> <people> [<event> <times> <people>]...: the lines the query reads for a week.
week() {
  local name="$1"
  printf '%s\t\t0\t%s\n' "$name" "$2" >> "$T/rows"
  shift 2
  while [ $# -gt 0 ]; do
    printf '%s\t%s\t%s\t%s\n' "$name" "$1" "$2" "$3" >> "$T/rows"
    shift 3
  done
}
row() { grep -F "| $1 |" <<<"$out" || true; }

scenario "a ticket is shown in each week it was labelled deployed, a reverted one too, and one deployed in no week shown is left out"
no_tickets
week 2026-W02 1 "race added" 2 1
week 2026-W03 0
a_ticket 10 "Add a race" ready "2026-01-05T00:00:00Z" deployed "2026-01-05T01:00:00Z" deployed "2026-01-13T00:00:00Z"
a_ticket 11 "Open the dashboard" ready "2026-01-06T00:00:00Z" deployed "2026-01-14T00:00:00Z" reverted "2026-01-15T00:00:00Z"
a_ticket 12 "Join the waitlist" deployed "2025-12-01T00:00:00Z"
run "$scripts/usage.sh" "$T/rows" "$T/deployed"
expect_status 0
[ "$(row 2026-W02)" = "| 2026-W02 | 1 | 2 times by 1 person | [#10](https://github.com/owner/repo/issues/10) Add a race |" ] \
  || fail "expected the first week to hold the ticket deployed in it, found: $(row 2026-W02)"
[ "$(row 2026-W03)" = "| 2026-W03 | 0 | 0 times by 0 people | [#10](https://github.com/owner/repo/issues/10) Add a race; [#11](https://github.com/owner/repo/issues/11) Open the dashboard |" ] \
  || fail "expected the second week to hold no event and both tickets deployed in it, found: $(row 2026-W03)"
expect_no_output "#12"

scenario "a week in which nothing was deployed says so, and a bar in a title or an event name stays in its cell"
no_tickets
week 2026-W02 1 "race | added" 1 1
a_ticket 10 "Add a | race" deployed "2026-01-05T01:00:00Z"
week 2026-W03 1
run "$scripts/usage.sh" "$T/rows" "$T/deployed"
expect_status 0
expect_output '| Week | People active | `race \| added` | Tickets deployed |'
expect_output 'Add a \| race |'
[ "$(row 2026-W03)" = "| 2026-W03 | 1 | 0 times by 0 people | None |" ] || fail "expected a week with no ticket to say None, found: $(row 2026-W03)"

scenario "a database with no usage table prints nothing"
no_tickets
: > "$T/rows"
run "$scripts/usage.sh" "$T/rows" "$T/deployed"
expect_status 0
[ -z "$out" ] || fail "expected nothing printed, found: $out"

scenario "a database that could not be read is said under the heading"
no_tickets
run "$scripts/usage.sh" "$T/rows" "$T/deployed"
expect_status 0
expect_output "## Usage by week

Production's database could not be read, so this week's page shows no usage."

scenario "stops with a message when the rows are not those the query reads"
no_tickets
printf 'not a row\n' > "$T/rows"
run "$scripts/usage.sh" "$T/rows" "$T/deployed"
expect_status 1
expect_output "The usage read from production's database could not be shown by week, so the usage by week is not written."
