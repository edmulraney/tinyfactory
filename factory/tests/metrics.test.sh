#!/usr/bin/env bash
# Tests for metrics.sh, which writes the page of the factory's delivery numbers by week on the sessions branch.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

# github: $T/origin stands for main on GitHub and $T/remote.git for its sessions branch; gh answers from $T/pulls
# and $T/bugs, and fails a call that holds a line of $T/fail.
github() {
  sessions_remote sessions
  git init -q -b main "$T/origin"
  git -C "$T/origin" commit -q --allow-empty -m "chore: start"
  : > "$T/pulls"; : > "$T/bugs"; : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in *"$words"*) echo "gh: HTTP 502: Bad Gateway" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api graphql --paginate -F owner={owner} -F name={repo} -f query="*)
        json "{\"data\":{\"repository\":{\"pullRequests\":{\"nodes\":$(jq -sc . "$T/pulls")}}}}" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=all&labels=bug&per_page=100 --paginate --jq "*) json "$(jq -sc . "$T/bugs")" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
file() {
  local path="$T/origin/$1"
  shift
  printf '%s\n' "$@" > "$path"
}
# a_ticket <number> [<label> <put on at>]...: a ticket as GitHub lists it under the pull request that closes it.
a_ticket() {
  local number="$1" events=""
  shift
  while [ $# -gt 0 ]; do
    events+=$(jq -nc --arg name "$1" --arg at "$2" '{createdAt: $at, label: {name: $name}}')$'\n'
    shift 2
  done
  jq -sc --argjson number "$number" \
    '{number: $number, title: "Export the forecast", labels: {nodes: map(.label)}, timelineItems: {nodes: .}}' <<<"$events"
}
# taking_back <number> <title>: the ticket revert.sh files to take a pull request back.
taking_back() { a_ticket "$1" | jq -c --arg title "$2" '.title = $title'; }
# merge <pr> <merged at> [<ticket>]...: squash-merges what $T/origin holds as that pull request, the next to merge.
merge() {
  local pr="$1" at="$2"
  shift 2
  git -C "$T/origin" add -A && git -C "$T/origin" commit -q --allow-empty -m "feat: change $pr (#$pr)"
  jq -nc --argjson number "$pr" --arg at "$at" --arg oid "$(git -C "$T/origin" rev-parse HEAD)" \
    '{number: $number, title: "feat: change \($number)", mergedAt: $at, mergeCommit: {oid: $oid},
      closingIssuesReferences: {nodes: $ARGS.positional}}' --jsonargs "$@" >> "$T/pulls"
}
# a_bug <number> <description> [pull]: a ticket labelled `bug`, or with `pull` a pull request that carries the label.
a_bug() {
  jq -nc --argjson n "$1" --arg body "$2" --arg pull "${3:-}" \
    '{number: $n, body: $body} | if $pull == "pull" then .pull_request = {} else . end' >> "$T/bugs"
}
# on_sessions <path> <content>: a file the sessions branch holds.
on_sessions() {
  mkdir -p "$(dirname "$T/seed/$1")" && printf '%s\n' "$2" > "$T/seed/$1"
  git -C "$T/seed" add -A && git -C "$T/seed" commit --quiet -m "$1" && git -C "$T/seed" push --quiet "$T/remote.git" sessions
}
# a_line <pr> <ticket> <merged at> <cost> <minutes> <fix rounds> <owner's rounds> <sessions>: as measures.sh records it.
a_line() {
  jq -cn --argjson pr "$1" --argjson issue "$2" --arg at "$3" --argjson cost "$4" --argjson minutes "$5" --argjson rounds "$6" \
    --argjson owner "$7" --argjson sessions "$8" '{pr: $pr, issue: $issue, merged_at: $at, cost_usd: $cost, sessions: $sessions,
      minutes: $minutes, fix_rounds: $rounds, owner_rounds: $owner, seconds: 3600, opened: []}'
}
# report: runs metrics.sh in a fresh clone of main, and reads the page the sessions branch then holds.
report() {
  rm -rf "$T/work/clone"
  git clone -q "file://$T/origin" "$T/work/clone" 2>/dev/null
  cd "$T/work/clone" || exit 1
  run "$scripts/metrics.sh"
  cd "$T/work" || exit 1
  rm -rf "$T/work/clone"
  page=$(on_github show sessions:metrics.md 2>/dev/null || true)
}
# expect_in <measure> <text>: the section of the page under that heading holds the text.
expect_in() {
  local section
  section=$(awk -v heading="## $1" '$0 == heading { inside = 1; next } /^## / { inside = 0 } inside' <<<"$page")
  [[ "$section" == *"$2"* ]] || fail "expected \"$1\" to hold: $2
found: $section"
}
expect_not_in() {
  local section
  section=$(awk -v heading="## $1" '$0 == heading { inside = 1; next } /^## / { inside = 0 } inside' <<<"$page")
  [[ "$section" != *"$2"* ]] || fail "expected \"$1\" not to hold: $2"
}
expect_no_page() { [ -z "$page" ] || fail "expected no metrics.md on the sessions branch, found: $page"; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder, found: $(ls -A "$T/tmp")"
  [ -z "$(ls -A "$T/work")" ] || fail "expected nothing left in the working folder"
}

scenario "merges a day: the pull requests merged in a week over its seven days, as a bar and a row for each week"
github
merge 1 "2026-01-05T00:00:00Z"; merge 2 "2026-01-07T12:00:00Z"; merge 3 "2026-01-11T23:59:59Z"
merge 4 "2026-01-12T00:00:00Z"
report
expect_status 0
expect_output "wrote https://github.com/owner/repo/blob/sessions/metrics.md"
expect_in "Merges a day" '```mermaid
xychart-beta
  x-axis ["2026-W02", "2026-W03"]
  y-axis "Merges a day" 0 --> 0.4
  bar [0.4, 0.1]
```

| Week | Merges a day | Counted over |
|---|---|---|
| 2026-W02 | 0.4 | 3 merges |
| 2026-W03 | 0.1 | 1 merge |'
[ "$(on_github log -1 --format=%s sessions)" = "metrics: the weeks that have ended" ] || fail "expected the commit to say what it wrote"
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcripts to still be on the branch"
expect_nothing_left

scenario "time from ready to deployed: the mean, in hours, from a ticket's first ready to the deployed its merge led to"
github
merge 1 "2026-01-05T12:30:00Z" "$(a_ticket 10 ready "2026-01-05T08:00:00Z" in-progress "2026-01-05T08:01:00Z" ready "2026-01-05T12:00:00Z" deployed "2026-01-05T13:00:00Z")"
merge 2 "2026-01-06T01:00:00Z" "$(a_ticket 11 ready "2026-01-06T00:00:00Z" deployed "2026-01-06T02:00:00Z")"
# A factory ticket deploys nothing, and one never labelled ready has no time to count from.
merge 3 "2026-01-06T03:00:00Z" "$(a_ticket 12 factory "2026-01-06T00:00:00Z" ready "2026-01-06T00:00:00Z")"
merge 4 "2026-01-06T04:00:00Z" "$(a_ticket 13 deployed "2026-01-06T05:00:00Z")"
# Shipped, taken back and shipped again: each merge is counted to the label that followed it.
twice=$(a_ticket 14 ready "2026-01-12T00:00:00Z" deployed "2026-01-12T01:00:00Z" ready "2026-01-12T20:00:00Z" deployed "2026-01-13T00:00:00Z")
merge 5 "2026-01-12T00:30:00Z" "$twice"; merge 6 "2026-01-12T23:00:00Z" "$twice"
merge 7 "2026-01-19T00:00:00Z"
report
expect_status 0
expect_in "Time from \`ready\` to deployed" '  x-axis ["2026-W02", "2026-W03"]
  y-axis "Hours" 0 --> 12.5
  bar [3.5, 12.5]'
expect_in "Time from \`ready\` to deployed" "| 2026-W02 | 3.5 | 2 deployed tickets |
| 2026-W03 | 12.5 | 2 deployed tickets |"
expect_not_in "Time from \`ready\` to deployed" "2026-W04"

scenario "merges followed by a bug ticket or a revert: the share a later bug names, or a later pull request took back"
github
merge 1 "2026-01-05T00:00:00Z" "$(a_ticket 10)"
merge 2 "2026-01-05T01:00:00Z"
merge 3 "2026-01-05T02:00:00Z" "$(a_ticket 12)"
merge 4 "2026-01-05T03:00:00Z" "$(a_ticket 13)"
merge 5 "2026-01-05T04:00:00Z" "$(a_ticket 14)"
merge 6 "2026-01-05T05:00:00Z"
merge 30 "2026-01-12T00:00:00Z" "$(taking_back 25 "Take back pull request #4")"
merge 31 "2026-01-12T01:00:00Z" "$(taking_back 26 "Take back the button merge of pull request #6")"
a_bug 20 "Since #10 shipped the export is empty."
a_bug 21 "Pull request #2 broke the totals."
# An older ticket edited to name it, and a pull request that carries the label, are no bug that followed.
a_bug 5 "Edited to name #12."
a_bug 22 "Closes #12" pull
a_bug 23 "Names #140 and #50."
report
expect_status 0
expect_in "Merges followed by a bug ticket or a revert" '  y-axis "Percent of merges" 0 --> 67
  bar [67, 0]'
expect_in "Merges followed by a bug ticket or a revert" "| 2026-W02 | 67 | 4 of 6 merges |
| 2026-W03 | 0 | 0 of 2 merges |"

scenario "rework: the share of the lines a week's product pull requests added that later pull requests changed or deleted"
github
file other.ts kept; merge 1 "2026-01-05T00:00:00Z" "$(a_ticket 10 factory "2026-01-05T00:00:00Z")"
file app.ts one two three four five six seven eight nine ten; file other.ts kept added; merge 2 "2026-01-06T00:00:00Z" "$(a_ticket 11)"
# One line changed and one deleted, of the eleven that pull request 2 added; the factory ticket's line is changed too.
file app.ts one TWO three four five six seven eight ten; file other.ts KEPT added; merge 3 "2026-01-12T00:00:00Z" "$(a_ticket 12)"
report
expect_status 0
expect_in "Rework" '  x-axis ["2026-W02"]
  y-axis "Percent of added lines" 0 --> 18
  bar [18]'
expect_in "Rework" "| 2026-W02 | 18 | 2 of 11 added lines |"
# No pull request has merged since pull request 3, so its week holds no rework yet.
expect_not_in "Rework" "2026-W03"

scenario "the five for each pull request: the means of what each merge recorded, and the turns its transcripts hold"
github
merge 1 "2026-01-05T00:00:00Z" "$(a_ticket 10)"; merge 2 "2026-01-06T00:00:00Z" "$(a_ticket 11)"; merge 3 "2026-01-12T00:00:00Z" "$(a_ticket 12)"
on_sessions measures.jsonl "$(a_line 1 10 "2026-01-05T00:00:00Z" 2.5 10 1 1 3; a_line 2 11 "2026-01-06T00:00:00.000Z" 1 5 0 0 2; a_line 3 12 "2026-01-12T00:00:00Z" 0.333 1 0 0 1)"
on_sessions pr-1/20260105T000000Z-adam-run5.json '[{"type":"system","subtype":"init"},{"type":"result","num_turns":40}]'
on_sessions issue-10/20260105T000000Z-esme-run4.json '{"type":"result","num_turns":10}'
# One nothing can read, one that ended with no result, and one of another ticket give no turn to these.
on_sessions pr-1/20260105T000000Z-ryan-run5.json 'not json'
on_sessions pr-2/20260106T000000Z-adam-run6.json '[{"type":"assistant"}]'
on_sessions issue-99/20260106T000000Z-esme-run7.json '[{"type":"result","num_turns":500}]'
on_sessions pr-3/20260112T000000Z-adam-run8.json '[{"type":"result","num_turns":7}]'
report
expect_status 0
expect_in "Fix rounds for each pull request" '  y-axis "Fix rounds" 0 --> 1
  bar [1, 0]'
expect_in "Fix rounds for each pull request" "| 2026-W02 | 1 | 2 recorded pull requests |
| 2026-W03 | 0 | 1 recorded pull request |"
expect_in "Agent sessions for each pull request" '  bar [2.5, 1]'
expect_in "Agent sessions for each pull request" "| 2026-W02 | 2.5 | 2 recorded pull requests |"
expect_in "Turns for each pull request" '  y-axis "Turns" 0 --> 25
  bar [25, 7]'
expect_in "Turns for each pull request" "| 2026-W02 | 25 | 2 recorded pull requests |"
expect_in "Actions minutes for each pull request" '  bar [7.5, 1]'
expect_in "Actions minutes for each pull request" "| 2026-W02 | 7.5 | 2 recorded pull requests |"
expect_in "Claude cost for each pull request" '  y-axis "Dollars" 0 --> 1.75
  bar [1.75, 0.33]'
expect_in "Claude cost for each pull request" "| 2026-W02 | 1.75 | 2 recorded pull requests |
| 2026-W03 | 0.33 | 1 recorded pull request |"

scenario "a ticket two recorded pull requests built: its transcripts are read once, so each pull request counts its turns once"
github
merge 5 "2026-01-05T00:00:00Z" "$(a_ticket 14)"; merge 6 "2026-01-06T00:00:00Z" "$(a_ticket 14)"; merge 7 "2026-01-12T00:00:00Z"
on_sessions measures.jsonl "$(a_line 5 14 "2026-01-05T00:00:00Z" 1 1 0 0 1; a_line 6 14 "2026-01-06T00:00:00Z" 1 1 0 0 1)"
on_sessions issue-14/20260105T000000Z-esme-run4.json '[{"type":"result","num_turns":10}]'
on_sessions pr-5/20260105T000000Z-adam-run5.json '[{"type":"result","num_turns":20}]'
on_sessions pr-6/20260106T000000Z-adam-run6.json '[{"type":"result","num_turns":30}]'
report
expect_status 0
expect_in "Turns for each pull request" "| 2026-W02 | 35 | 2 recorded pull requests |"

scenario "the page holds a chart and a table for each of the nine measures"
github
file app.ts one two; merge 1 "2026-01-05T00:00:00Z" "$(a_ticket 10 ready "2026-01-05T00:00:00Z" deployed "2026-01-05T01:00:00Z")"
file app.ts one TWO; merge 2 "2026-01-12T00:00:00Z"
on_sessions measures.jsonl "$(a_line 1 10 "2026-01-05T00:00:00Z" 2.5 10 1 0 3)"
report
expect_status 0
[[ "$page" == "# The factory's delivery numbers by week"$'\n'* ]] || fail "expected the page to open with its title"
for count in '^## ' '^```mermaid$' '^xychart-beta$' '^  bar \[' '^| Week | '; do
  [ "$(grep -c "$count" <<<"$page")" = 9 ] || fail "expected nine lines like $count, found $(grep -c "$count" <<<"$page")"
done
expect_in "Rework" "| 2026-W02 | 50 | 1 of 2 added lines |"

scenario "a week that has not ended is left out: its numbers would change by the next run"
github
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
merge 1 "2026-01-05T00:00:00Z"; merge 2 "$now"; merge 3 "$now"
on_sessions measures.jsonl "$(a_line 1 10 "2026-01-05T00:00:00Z" 2.5 10 1 0 3; a_line 2 11 "$now" 9 9 9 9 9)"
report
expect_status 0
expect_in "Merges a day" "| 2026-W02 | 0.1 | 1 merge |"
expect_in "Claude cost for each pull request" '  bar [2.5]'
[[ "$page" != *"$(date -u +%G-W%V)"* ]] || fail "expected no row for the week that is running"

scenario "a measure no week holds says so, with no chart"
github
merge 1 "2026-01-05T00:00:00Z"
report
expect_status 0
for measure in "Time from \`ready\` to deployed" "Rework" "Turns for each pull request" "Claude cost for each pull request"; do
  expect_in "$measure" "No week holds this measure yet."
  expect_not_in "$measure" "xychart-beta"
done
[ "$(grep -c '^xychart-beta$' <<<"$page")" = 2 ] || fail "expected a chart for the two measures a week holds"

scenario "the next run writes the page again: one page, and no commit when nothing moved"
github
merge 1 "2026-01-05T00:00:00Z"
report
commits=$(on_github rev-list --count sessions)
report
expect_status 0
[ "$(on_github rev-list --count sessions)" = "$commits" ] || fail "expected no commit for a page that did not change"
merge 2 "2026-01-06T00:00:00Z"
report
expect_status 0
[ "$(on_github rev-list --count sessions)" = "$((commits + 1))" ] || fail "expected one commit for the page that changed"
expect_in "Merges a day" "| 2026-W02 | 0.3 | 2 merges |"
[ "$(pushed_files | grep -c 'metrics')" = 1 ] || fail "expected one page on the branch"

scenario "tries again when the push loses a race, and then writes the page"
github
merge 1 "2026-01-05T00:00:00Z"
refuses_pushes 1
report
expect_status 0
expect_call "sleep"
expect_in "Merges a day" "| 2026-W02 | 0.1 | 1 merge |"

scenario "a page that cannot be pushed is said: stops, and leaves nothing behind"
github
merge 1 "2026-01-05T00:00:00Z"
refuses_pushes
report
expect_status 1
expect_output "metrics.md could not be written to the sessions branch, so the page there is the one written before."
[ "$(pushes)" = 6 ] || fail "expected six tries, got $(pushes)"
expect_no_page
expect_nothing_left

scenario "a record that holds a line nothing can read: stops with a message after one clone, and writes no page"
github
merge 1 "2026-01-05T00:00:00Z"
on_sessions measures.jsonl '{"pr":1,"issue":10'
report
expect_status 1
expect_output "measures.jsonl on the sessions branch holds a line that could not be read, so metrics.md is not written."
expect_no_call "sleep"
expect_no_page
expect_nothing_left

scenario "no pull request merged in a week that has ended: says so, and writes no page"
github
merge 1 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
report
expect_status 0
expect_output "No pull request merged in a week that has ended, so metrics.md is not written."
expect_no_page

scenario "stops with a message, and writes no page, when the merged pull requests cannot be listed"
github
merge 1 "2026-01-05T00:00:00Z"
echo "timelineItems" > "$T/fail"
report
expect_status 1
expect_output "Could not list the merged pull requests from GitHub, so metrics.md is not written."
expect_no_page

scenario "stops with a message, and writes no page, when the bug tickets cannot be listed: that is not a week with no bug"
github
merge 1 "2026-01-05T00:00:00Z"
echo "labels=bug" > "$T/fail"
report
expect_status 1
expect_output "Could not list the tickets labelled \`bug\` from GitHub, so which merges a bug followed is not known and metrics.md is not written."
expect_no_page

scenario "stops with what quality.sh says, and writes no page, when the rework cannot be worked out"
github
merge 1 "2026-01-05T00:00:00Z"
echo "labels(first" > "$T/fail"
report
expect_status 1
expect_output "Could not list the merged pull requests from GitHub, so no pull request's fix rounds or rework are known."
expect_no_page

scenario "stops with a message before any call when it is not told which repository to write to"
github
merge 1 "2026-01-05T00:00:00Z"
unset GITHUB_REPOSITORY
report
expect_status 1
expect_output "GH_TOKEN and GITHUB_REPOSITORY are not both set, so metrics.md is not written."
expect_no_call "gh "
expect_no_page

scenario "review-notes.yml runs it each week, in a job that may write the sessions branch"
job=$(awk '/^  metrics:$/ { inside = 1; next } /^  [a-z-]+:$/ { inside = 0 } inside' "$root/factory/workflows/review-notes.yml")
grep -qxF '        run: factory/scripts/metrics.sh' <<<"$job" || fail "review-notes.yml has no metrics job that runs metrics.sh"
grep -qE '^      contents: write( |$)' <<<"$job" || fail "the metrics job may not write the sessions branch"
grep -qxF '          GH_TOKEN: ${{ github.token }}' <<<"$job" || fail "the metrics job gives metrics.sh no token"

scenario "the owner guide links the page on the sessions branch"
grep -qF '](../../sessions/metrics.md)' "$root/factory/owner-guide.md" || fail "factory/owner-guide.md does not link metrics.md on the sessions branch"
