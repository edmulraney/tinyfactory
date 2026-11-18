#!/usr/bin/env bash
# Tests for measures.sh, which keeps a line of measures for each merged ticket and prints a period's six.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

# a_line <pr> <ticket> <merged at> <cost> <minutes> <fix rounds> <seconds, or null> <stops>: as ticket-cost.sh --json prints it.
a_line() {
  jq -cn --argjson pr "$1" --argjson issue "$2" --arg at "$3" --argjson cost "$4" --argjson minutes "$5" --argjson rounds "$6" \
    --argjson seconds "$7" --argjson stops "$8" '
    {pr: $pr, issue: $issue, title: "feat: test with main", merged_at: $at, cost_usd: $cost, sessions: 3, unread: 0,
     models: ["claude-fable-5-2"], minutes: $minutes, runs: 2, fix_rounds: $rounds, owner_rounds: 0, seconds: $seconds,
     split: (if $seconds == null then null else {build: 600, review: 900, fix: ($rounds * 300), waiting: ($seconds - 1500 - $rounds * 300)} end),
     stops: $stops}'
}
# Ticket #57 merged on Monday of week 47, an hour after it was made `ready`.
its_line() { a_line 72 57 "2026-11-16T09:00:00Z" 10.21 11 0 3600 0; }
# an_issue <number> <label> <description>: one GitHub lists; a pull request has "pull" for a label.
an_issue() {
  jq -cn --argjson n "$1" --arg label "$2" --arg body "$3" '{number: $n, labels: [{name: $label}], body: $body}
    | if $label == "pull" then .pull_request = {} else . end' >> "$T/issues"
}
github() {
  : > "$T/fail"; : > "$T/issues"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f since="*" -f per_page=100 --paginate "*) json "$(jq -sc . "$T/issues")" "$@" ;;
      "api repos/{owner}/{repo}/contents/measures.jsonl?ref=sessions -H Accept: application/vnd.github.raw") cat "$T/record/measures.jsonl" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# already_recorded <line>...: the sessions branch on GitHub holds these lines.
already_recorded() {
  git clone --quiet --branch sessions "$T/remote.git" "$T/clone"
  printf '%s\n' "$@" > "$T/clone/measures.jsonl"
  git -C "$T/clone" add -A && git -C "$T/clone" commit --quiet -m measures && git -C "$T/clone" push --quiet origin sessions
  rm -rf "$T/clone"
}
recorded() { on_github show sessions:measures.jsonl 2>/dev/null; }
record() { run "$scripts/measures.sh" record; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder, found: $(ls -A "$T/tmp")"
  [ -z "$(ls -A "$T/work")" ] || fail "expected nothing left in the working folder"
}

scenario "a merge appends one line: the ticket's figures, after the lines of the tickets before it"
sessions_remote sessions; github
already_recorded "$(a_line 70 55 "2026-11-15T09:00:00Z" 2 5 0 600 0)"
record <<<"$(its_line)"
expect_status 0
expect_output "recorded the measures of ticket #57 in measures.jsonl on the sessions branch"
[ "$(recorded | wc -l | tr -d ' ')" = 2 ] || fail "expected two lines, found: $(recorded)"
[ "$(recorded | head -n 1 | jq .issue)" = 55 ] || fail "expected the earlier ticket's line first"
[ "$(recorded | tail -n 1 | jq -c 'del(.opened)')" = "$(its_line)" ] || fail "expected the figures as they were given, found: $(recorded | tail -n 1)"
[ "$(on_github log -1 --format=%s sessions)" = "measures: ticket #57" ] || fail "expected the commit to name the ticket"
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcripts to still be on the branch"
expect_nothing_left

scenario "the first merge makes the record, and the branch when there is none"
sessions_remote; github
record <<<"$(its_line)"
expect_status 0
[ "$(recorded | jq .issue)" = 57 ] || fail "expected the ticket's line on a new sessions branch, found: $(pushed_files)"

scenario "the line names the tickets opened from it: later issues whose description names it or its pull request"
sessions_remote sessions; github
an_issue 60 factory "Seen in pull request #72"
an_issue 61 bug "Since #57 merged the export is empty."
an_issue 62 factory "Built on #570 and #720."
an_issue 63 pull "Closes #57"
an_issue 50 factory "An older ticket, edited to name #57."
an_issue 64 factory ""
record <<<"$(its_line)"
expect_status 0
[ "$(recorded | jq -c .opened)" = "[60,61]" ] || fail "expected #60 and #61, found: $(recorded | jq -c .opened)"
expect_call "-f since=2026-11-16T08:00:00Z "

scenario "a ticket never labelled ready: the issues are listed from its merge"
sessions_remote sessions; github
record <<<"$(a_line 72 57 "2026-11-16T09:00:00Z" 10.21 11 0 null 0)"
expect_status 0
expect_call "-f since=2026-11-16T09:00:00Z "
[ "$(recorded | jq -c .opened)" = "[]" ] || fail "expected no ticket opened from it"

scenario "a merge whose steps run again keeps one line for the ticket, the later one"
sessions_remote sessions; github
already_recorded "$(its_line)" "$(a_line 73 58 "2026-11-17T09:00:00Z" 4 20 2 7200 1)"
record <<<"$(a_line 72 57 "2026-11-16T09:00:00Z" 11.5 14 0 3600 0)"
expect_status 0
[ "$(recorded | jq -c '[.issue, .cost_usd]' | tr '\n' ' ')" = "[58,4] [57,11.5] " ] || fail "expected one line for each ticket, found: $(recorded)"

scenario "tries again when the push loses a race, and then records"
sessions_remote sessions; github
refuses_pushes 1
record <<<"$(its_line)"
expect_status 0
expect_call "sleep"
[ "$(recorded | jq .issue)" = 57 ] || fail "expected the line on the branch after the second try"

scenario "a line that cannot be written is said: stops, and leaves nothing behind"
sessions_remote sessions; github
refuses_pushes
record <<<"$(its_line)"
expect_failure
expect_output "The measures of ticket #57 could not be written to measures.jsonl on the sessions branch, so no table will hold them."
[ "$(pushes)" = 6 ] || fail "expected six tries, got $(pushes)"
[ -z "$(recorded)" ] || fail "expected no record on the branch"
expect_nothing_left

scenario "a record that holds a line nothing can read is not written over"
sessions_remote sessions; github
already_recorded '{"pr":70,"issue":55' "$(a_line 71 56 "2026-11-15T09:00:00Z" 2 5 0 600 0)"
record <<<"$(its_line)"
expect_failure
expect_output "The measures of ticket #57 could not be written"
[ "$(recorded | wc -l | tr -d ' ')" = 2 ] || fail "expected the record as it was, found: $(recorded)"
expect_nothing_left

scenario "stops with a message, and records nothing, when the issues cannot be listed"
sessions_remote sessions; github
echo "api --method GET repos/{owner}/{repo}/issues" > "$T/fail"
record <<<"$(its_line)"
expect_failure
expect_output "Could not list the issues changed since 2026-11-16T08:00:00Z, so the tickets opened from ticket #57 are not known and its measures are not recorded."
[ -z "$(recorded)" ] || fail "expected no record on the branch"

for given in "" "not json" '{"pr":72,"issue":null,"merged_at":"2026-11-16T09:00:00Z"}' '{"pr":72,"issue":57,"merged_at":null}'; do
  scenario "refuses figures that are not a merged ticket's, with no call to GitHub: ${given:-nothing}"
  sessions_remote sessions; github
  record <<<"$given"
  expect_failure
  expect_output "The figures on stdin are not those of a merged ticket, so nothing is recorded."
  expect_no_call "gh "
  [ -z "$(recorded)" ] || fail "expected no record on the branch"
done

scenario "stops with a message before any call when it is not told which repository to write to"
sessions_remote sessions; github
unset GITHUB_REPOSITORY
record <<<"$(its_line)"
expect_failure
expect_output "GH_TOKEN and GITHUB_REPOSITORY are not both set, so the measures of ticket #57 are not recorded."
expect_no_call "gh "

# Three tickets merged in week 47 of 2026, one the week before and one in December.
three_tickets() {
  mkdir -p "$T/record"
  {
    a_line 60 50 "2026-11-13T12:00:00Z" 99 99 3 86400 9
    its_line | jq -c '.opened = [59]'
    a_line 73 58 "2026-11-18T12:00:00Z" 4 20 2 10800 1
    a_line 74 59 "2026-11-22T23:59:59Z" 3.8 8 0 1800 1 | jq -c '.unread = 0'
    a_line 80 65 "2026-12-01T00:00:00Z" 50 50 1 600 5
  } > "$T/record/measures.jsonl"
  an_issue 90 factory "Seen in pull request #73"
  an_issue 91 bug "Since #57 merged the export is empty."
  an_issue 92 bug "Pull request #73 broke the totals."
  an_issue 93 bug "Unrelated to any ticket."
  an_issue 94 pull "Closes #58"
}
table() { run env GH_TOKEN=owner-token "$scripts/measures.sh" "$@"; }

scenario "a week: the table is right for three recorded tickets, and holds no ticket merged outside it"
github; three_tickets
table --week 2026-W47 "$T/record"
expect_status 0
expect_output "The six measures for 2026-W47, over 3 merged tickets:"
expect_output "| Measure | Figure |"
# (10.21 + 4 + 3.8) / 3 and (11 + 20 + 8) / 3.
expect_output "| Cost per ticket | \$6.00 of Claude usage at API prices and 13 Actions minutes |"
# (3600 + 10800 + 1800) / 3 seconds; 600 and 900 each; 600 over three; the rest.
expect_output "| Time to merge | 1 h 30 min: 10 min building, 15 min in review, 3 min in fix rounds, 1 h 2 min waiting |"
expect_output "| Passing with no fix round | 2 of 3 (67%) |"
expect_output "| Stops for a person per ten tickets | 6.7 |"
# #59 was recorded at the merge; #91, and #90 and #92, are found now.
expect_output "| Tickets opened per merge | 1.3 |"
expect_output "| Bugs traced to a ticket | 2: #91 to #57; #92 to #58 |"
[ "$(grep -c '^|' <<<"$out")" = 8 ] || fail "expected a heading, a rule and six rows"
expect_call "-f since=2026-11-16T08:00:00Z "
expect_no_call "contents/measures.jsonl"

scenario "a month: every ticket merged in it"
github; three_tickets
table --month 2026-11 "$T/record"
expect_status 0
expect_output "The six measures for 2026-11, over 4 merged tickets:"
expect_output "| Passing with no fix round | 2 of 4 (50%) |"
expect_output "| Time to merge | 7 h 8 min: "

scenario "one ticket, and no bug: the words agree"
github; three_tickets
table --month 2026-12 "$T/record"
expect_status 0
expect_output "The six measures for 2026-12, over 1 merged ticket:"
expect_output "| Cost per ticket | \$50.00 of Claude usage at API prices and 50 Actions minutes |"
expect_output "| Stops for a person per ten tickets | 50 |"
expect_output "| Tickets opened per merge | 0 |"
expect_output "| Bugs traced to a ticket | 0 |"

scenario "a transcript that could not be read, and a ticket never labelled ready: both are said"
github
mkdir -p "$T/record"
{ its_line | jq -c '.unread = 2'; a_line 73 58 "2026-11-18T12:00:00Z" 4 20 0 null 0; } > "$T/record/measures.jsonl"
table --week 2026-W47 "$T/record"
expect_status 0
expect_output "and 16 Actions minutes; 2 transcripts could not be read, so the usage is more |"
expect_output "| Time to merge | 1 h 0 min: 10 min building, 15 min in review, 0 min in fix rounds, 35 min waiting, over the 1 labelled \`ready\` |"

scenario "no ticket was labelled ready: the time is not known, and says why"
github
mkdir -p "$T/record"
a_line 73 58 "2026-11-18T12:00:00Z" 4 20 0 null 0 > "$T/record/measures.jsonl"
table --week 2026-W47 "$T/record"
expect_status 0
expect_output "| Time to merge | not known: no ticket was labelled \`ready\` |"

scenario "a period in which no recorded ticket merged: says so, and asks GitHub nothing"
github; three_tickets
table --week 2026-W40 "$T/record"
expect_status 0
expect_output "No recorded ticket merged in 2026-W40."
expect_no_output "| Measure"
expect_no_call "gh "

scenario "with no sessions folder: downloads the record alone, and leaves nothing behind"
github; three_tickets
table --week 2026-W47
expect_status 0
expect_call "gh api repos/{owner}/{repo}/contents/measures.jsonl?ref=sessions"
expect_output "| Passing with no fix round | 2 of 3 (67%) |"
expect_nothing_left

scenario "stops with a message, and prints no table, when the record cannot be downloaded"
github; three_tickets
echo "api repos/{owner}/{repo}/contents/measures.jsonl" > "$T/fail"
table --week 2026-W47
expect_failure
expect_output "Could not download measures.jsonl from the sessions branch, so the measures of 2026-W47 are not known."
expect_no_output "| Measure"

scenario "stops with a message, and prints no table, when the issues cannot be listed"
github; three_tickets
echo "api --method GET repos/{owner}/{repo}/issues" > "$T/fail"
table --week 2026-W47 "$T/record"
expect_failure
expect_output "Could not list the issues changed since 2026-11-16T08:00:00Z, so the tickets opened from those merged in 2026-W47, and the bugs traced to them, are not known."
expect_no_output "| Measure"

scenario "stops with a message when the folder holds no record"
github
table --week 2026-W47 "$T/work"
expect_failure
expect_output "$T/work holds no measures.jsonl, so no ticket's measures are recorded there."

scenario "stops with a message, and prints no table, when a line of the record cannot be read"
github; three_tickets
echo '{"pr":81,"issue":66' >> "$T/record/measures.jsonl"
table --week 2026-W47 "$T/record"
expect_failure
expect_output "measures.jsonl holds a line that could not be read, so the measures of 2026-W47 are not known."
expect_no_output "| Measure"

for words in "" "--week" "--week 2026-47" "--week 2026-W54" "--month" "--month 2026-13" "--year 2026" "72"; do
  scenario "refuses, with its usage and no call to GitHub: measures.sh $words"
  github
  # shellcheck disable=SC2086
  table $words
  expect_failure
  expect_output "Usage: measures.sh record | --week <yyyy>-W<ww> [sessions-dir] | --month <yyyy-mm> [sessions-dir]"
  expect_no_call "gh "
done
