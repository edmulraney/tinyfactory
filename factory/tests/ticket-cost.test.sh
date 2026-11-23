#!/usr/bin/env bash
# Tests for ticket-cost.sh, which sums what a merged ticket cost from GitHub and the sessions branch.
. "$(dirname "$0")/helpers.sh"

# The scripts are run from a copy, so the budgets they read are this file's and not the owner's.
project="$_base/project"
mkdir -p "$project/factory"
cp -R "$scripts" "$project/factory/scripts"
scripts="$project/factory/scripts"

# Pull request #72 closes ticket #57; $T/fail lists the gh calls that fail, by their first words.
github() {
  : > "$T/fail"
  # Ticket #57 is labelled `factory`: one build costs 11 minutes and $10.21.
  printf '# The budgets.\n\ntweak 5 2\nfactory 11 10.21\n' > "$project/factory/budget.txt"
  mkdir -p "$T/sessions" "$T/jobs"
  echo '[]' > "$T/rounds"
  echo '[{"number":72,"merged_at":"2026-11-16T09:12:00Z"}]' > "$T/pulls"
  echo '{"workflow_runs":[{"id":801}]}' > "$T/runs"
  echo '[{"event":"labeled","label":{"name":"factory"},"created_at":"2026-11-16T07:00:00Z"},
         {"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-16T08:00:00Z"},
         {"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-16T08:50:00Z"}]' > "$T/events"
  echo '[]' > "$T/pr-events"
  pull_request 72 57 "2026-11-16T09:12:00Z"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr view "*" --json body "*) json "$(jq "{body}" "$T/pr-$3")" "$@" ;;
      "pr view "*" --json number,"*) json "$(cat "$T/pr-$3")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 "*) json "$(cat "$T/rounds")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs -f branch="*) json "{\"workflow_runs\":[]}" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs -f branch=feat/"*"-test-with-main -f per_page=100 "*) json "$(cat "$T/runs")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs/"*"/jobs -f filter=all -f per_page=100 "*)
        n=${4#*/runs/}; json "$(cat "$T/jobs/${n%/jobs}")" "$@" ;;
      "api repos/{owner}/{repo}/issues/7"[0-9]"/events?per_page=100 "*) json "$(cat "$T/pr-events")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/events?per_page=100 "*) json "$(cat "$T/events")" "$@" ;;
      "api repos/{owner}/{repo}/pulls?state=closed&per_page=100 "*) json "$(cat "$T/pulls")" "$@" ;;
      "api repos/{owner}/{repo}/git/"*) sessions_on_github "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
pull_request() {  # pull_request <number> <ticket, or none> <merged at, or null>
  local body="Closes #$2" merged="\"$3\""
  [ "$2" != none ] || body="A person's own pull request."
  [ "$3" != null ] || merged=null
  jq -n --argjson n "$1" --arg body "$body" --arg branch "feat/$2-test-with-main" --argjson merged "$merged" \
    '{number: $n, title: "feat: test with main", headRefName: $branch, state: "MERGED", mergedAt: $merged, labels: [],
      comments: [], createdAt: "2026-11-16T08:05:00Z", body: $body}' > "$T/pr-$1"
}
a_session() {  # a_session <folder> <role> <run> <cost>
  mkdir -p "$T/sessions/$1"
  echo "[{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"claude-fable-5-2\"},{\"type\":\"assistant\"},{\"type\":\"result\",\"is_error\":false,\"total_cost_usd\":$4,\"num_turns\":20,\"duration_ms\":60400}]" \
    > "$T/sessions/$1/20261116T080000Z-$2-run$3.json"
}
a_job() {  # a_job <run> <conclusion or null> <started hh:mm:ss> <completed hh:mm:ss> [workflow] [runner, or null] [runner group]
  echo "{\"run_id\":$1,\"conclusion\":\"$2\",\"started_at\":\"2026-11-16T$3Z\",\"completed_at\":\"2026-11-16T$4Z\",\"workflow_name\":\"${5:-ci}\",\"runner_id\":${6:-1000000001},\"runner_group_name\":\"${7:-GitHub Actions}\"}"
}
labelled() {  # labelled <events file> <labeled or unlabeled> <label> <hh:mm>
  jq -c --arg event "$2" --arg label "$3" --arg at "2026-11-16T$4:00Z" '. + [{event: $event, label: {name: $label}, created_at: $at}]' "$T/$1" > "$T/$1.new"
  mv "$T/$1.new" "$T/$1"
}
jobs_of() {  # jobs_of <run> <job>...
  local run="$1"
  shift
  printf '%s\n' "$@" | jq -sc '{jobs: .}' > "$T/jobs/$run"
}
rounds_are() {  # rounds_are <marker>...
  printf '%s\n' "$@" | jq -R '{id: 1, user: {login: "github-actions[bot]"}, body: ("<!-- factory:" + . + " -->A round.")}' | jq -sc . > "$T/rounds"
}
# One build, run 800, and one ci run, 801: 3 + 4 + 1 + 1 + 2 billed minutes, and $6.82 + $1.84 + $1.55.
one_build() {
  a_session issue-57 fred 800 6.82
  a_session pr-72 adam 801 1.84
  a_session pr-72 ryan 801 1.55
  jobs_of 800 "$(a_job 800 success 08:01:00 08:03:10 implement)"
  jobs_of 801 "$(a_job 801 success 08:10:00 08:13:01)" "$(a_job 801 success 08:14:00 08:14:60)" \
    "$(a_job 801 success 08:14:00 08:14:20)" "$(a_job 801 skipped 08:15:00 08:15:00)" "$(a_job 801 success 09:11:00 09:12:30)"
}
cost() { run env GH_TOKEN=workflow-token "$scripts/ticket-cost.sh" "$@"; }

scenario "a ticket with one build and no fix round: four lines, summed from its sessions and its runs' jobs"
github; one_build
cost 72 "$T/sessions"
expect_status 0
[ "$(grep -c . <<<"$out")" = 4 ] || fail "expected four lines"
expect_output "- **Claude usage:** \$10.21 at API prices, in 3 sessions on claude-fable-5-2"
expect_output "- **Actions minutes:** 11, in 2 runs"
expect_output "- **Fix rounds:** 0"
expect_output "- **Ready to merged:** 1 h 12 min"
expect_no_output "gave no cost"

scenario "a ticket with two fix rounds: their sessions, their runs and the rounds are in the sum"
github; one_build
rounds_are fix-round fix-round
echo '{"workflow_runs":[{"id":801},{"id":803},{"id":805}]}' > "$T/runs"
a_session pr-72 fred-fix 802 2.10
a_session pr-72 adam 803 0.90
a_session pr-72 fred-fix 804 1.05
a_session pr-72 ryan 805 0.045
jobs_of 802 "$(a_job 802 success 08:20:00 08:25:30 fix)"
jobs_of 803 "$(a_job 803 failure 08:26:00 08:28:00)"
jobs_of 804 "$(a_job 804 success 08:30:00 08:33:01 fix)"
jobs_of 805 "$(a_job 805 success 08:40:00 08:40:01)"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$14.31 at API prices, in 7 sessions on claude-fable-5-2"
expect_output "- **Actions minutes:** 24, in 6 runs"
expect_output "- **Fix rounds:** 2"

scenario "as JSON: one line that holds every figure, and the four lines can be had from it"
github; one_build
cost --json 72 "$T/sessions"
expect_status 0
[ "$(grep -c . <<<"$out")" = 1 ] || fail "expected one line"
[ "$(jq -c '[.pr, .issue, .title, .merged_at, .cost_usd, .sessions, .minutes, .runs, .fix_rounds, .owner_rounds, .seconds, .stops]' <<<"$out")" \
  = '[72,57,"feat: test with main","2026-11-16T09:12:00Z",10.21,3,11,2,0,0,4320,0]' ] || fail "expected the figures of the four lines"
figures="$out"
: > "$T/calls"
run "$scripts/ticket-cost.sh" --comment <<<"$figures"
expect_status 0
[ "$(grep -c . <<<"$out")" = 4 ] || fail "expected four lines"
expect_output "- **Claude usage:** \$10.21 at API prices, in 3 sessions on claude-fable-5-2"
expect_output "- **Ready to merged:** 1 h 12 min"
expect_no_call "gh "

over() { run "$scripts/ticket-cost.sh" --over-budget; }

scenario "a ticket that cost its budget to the minute and the cent: each figure beside its budget, and over neither"
github; one_build
cost 72 "$T/sessions"
expect_status 0
[ "$(grep -c . <<<"$out")" = 4 ] || fail "expected four lines"
expect_output "- **Claude usage:** \$10.21 at API prices, in 3 sessions on claude-fable-5-2; the budget for a \`factory\` ticket is \$10.21"
expect_output "- **Actions minutes:** 11, in 2 runs; the budget for a \`factory\` ticket is 11 minutes"
cost --json 72 "$T/sessions"
[ "$(jq -c .budget <<<"$out")" = '{"type":"factory","minutes":11,"cost_usd":10.21}' ] || fail "expected the budget of a factory ticket, found: $(jq -c .budget <<<"$out")"
over <<<"$out"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "a ticket over its budget of minutes alone: the comment says so of the minutes, and only they are named"
github; one_build
echo "factory 10 10.21" > "$project/factory/budget.txt"
cost 72 "$T/sessions"
expect_output "- **Actions minutes:** 11, in 2 runs; over the budget of 10 minutes for a \`factory\` ticket"
expect_output "claude-fable-5-2; the budget for a \`factory\` ticket is \$10.21"
cost --json 72 "$T/sessions"
over <<<"$out"
expect_status 0
[ "$out" = "Actions minutes" ] || fail "expected only the minutes to be named"

scenario "a ticket over its budget of cost alone: the comment says so of the cost, after a transcript that gave none"
github; one_build
echo "factory 11 8.65" > "$project/factory/budget.txt"
echo '[{"type":"result","total_cost_usd":1.8' > "$T/sessions/pr-72/20261116T080000Z-ryan-run801.json"
cost 72 "$T/sessions"
expect_output "- **Claude usage:** \$8.66 at API prices, in 2 sessions on claude-fable-5-2; 1 more transcript gave no cost; over the budget of \$8.65 for a \`factory\` ticket"
expect_output "- **Actions minutes:** 11, in 2 runs; the budget for a \`factory\` ticket is 11 minutes"
cost --json 72 "$T/sessions"
over <<<"$out"
expect_status 0
[ "$out" = "Claude usage" ] || fail "expected only the cost to be named"

scenario "the budget is that of the type the ticket holds now, not of one taken off it"
github; one_build
echo '[]' > "$T/events"
labelled events labeled factory 07:00
labelled events labeled ready 08:00
labelled events unlabeled factory 08:01
labelled events labeled tweak 08:02
cost 72 "$T/sessions"
expect_output "- **Actions minutes:** 11, in 2 runs; over the budget of 5 minutes for a \`tweak\` ticket"
expect_output "over the budget of \$2.00 for a \`tweak\` ticket"

scenario "a type with no budget, and a pull request that closes no ticket: the figures alone, and over nothing"
github; one_build
echo "tweak 5 2" > "$project/factory/budget.txt"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Actions minutes:** 11, in 2 runs"
expect_no_output "budget"
cost --json 72 "$T/sessions"
[ "$(jq -c .budget <<<"$out")" = null ] || fail "expected no budget"
over <<<"$out"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
pull_request 72 none "2026-11-16T09:12:00Z"
echo '{"workflow_runs":[]}' > "$T/runs"
rm "$project/factory/budget.txt"
cost 72 "$T/sessions"
expect_status 0
expect_no_output "budget"

scenario "figures recorded before budgets began: the four lines hold no budget, and they are over nothing"
github
figures='{"pr":72,"issue":57,"cost_usd":10.21,"sessions":3,"unread":0,"models":["claude-fable-5-2"],"minutes":11,"runs":2,"fix_rounds":0,"owner_rounds":0,"seconds":4320}'
run "$scripts/ticket-cost.sh" --comment <<<"$figures"
expect_status 0
expect_output "- **Actions minutes:** 11, in 2 runs"
expect_no_output "budget"
over <<<"$figures"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

for line in "factory eleven 10" "factory 11" "factory 11 \$10" "factory 11 10 12"; do
  scenario "stops with a message, and prints no cost, for a budget that is not minutes and dollars: $line"
  github; one_build
  printf 'tweak 5 2\n%s\n' "$line" > "$project/factory/budget.txt"
  cost 72 "$T/sessions"
  expect_failure
  expect_output "factory/budget.txt:2: a line is \"<type> <minutes> <dollars>\", and this is not: $line"
  expect_output "Could not read factory/budget.txt, so the budget of ticket #57 is not known."
  expect_no_output "Claude usage"
done

scenario "stops with a message, and prints no cost, when the budgets are missing"
github; one_build
rm "$project/factory/budget.txt"
cost 72 "$T/sessions"
expect_failure
expect_output "Could not read factory/budget.txt, so the budget of ticket #57 is not known."
expect_no_output "Claude usage"

for given in "not json" "" '{"pr":72}'; do
  scenario "whether figures are over a budget is refused for figures that are not the script's own: ${given:-nothing}"
  github
  over <<<"$given"
  expect_failure
  expect_output "The figures on stdin are not a line ticket-cost.sh --json printed, so whether they are over a budget is not known."
done

scenario "the budgets the factory ships with can be read, and hold one for each type of ticket"
github; one_build
cp "$root/factory/budget.txt" "$project/factory/budget.txt"
for type in $(sed -n 's/^types=(\(.*\))$/\1/p' "$scripts/check-ticket.sh"); do
  echo '[]' > "$T/events"
  labelled events labeled "$type" 07:00
  cost --json 72 "$T/sessions"
  expect_status 0
  [ "$(jq -r .budget.type <<<"$out")" = "$type" ] || fail "expected a budget for a $type ticket"
done

for given in "not json" "" '{"pr":72}'; do
  scenario "the four lines are refused for figures that are not the script's own: ${given:-nothing}"
  github
  run "$scripts/ticket-cost.sh" --comment <<<"$given"
  expect_failure
  expect_output "The figures on stdin are not a line ticket-cost.sh --json printed"
  expect_no_output "Claude usage"
done

# From `ready` at 08:00 to merged at 09:12: the build 08:01:00 to 08:03:10, and ci's jobs 08:10:00 to 08:13:01,
# 08:14:00 to 08:15:00 and 09:11:00 to 09:12:00, its last job cut at the merge.
scenario "the time is split into build, review, fix rounds and waiting, which add up to it"
github; one_build
cost --json 72 "$T/sessions"
expect_status 0
[ "$(jq -c .split <<<"$out")" = '{"build":130,"review":301,"fix":0,"waiting":3889}' ] || fail "expected the split, found: $(jq -c .split <<<"$out")"

scenario "the split with fix rounds: time two jobs share is counted once, and a job before ready or of a retro not at all"
github; one_build
echo '{"workflow_runs":[{"id":801},{"id":803}]}' > "$T/runs"
a_session pr-72 fred-fix 802 2.10
a_session issue-57 retro 806 0.40
a_session issue-57 fred 799 1.00
# A build before `ready` was first added; a fix round that a review job overlaps by a minute; a retro.
jobs_of 799 "$(a_job 799 success 07:00:00 07:30:00 implement)"
jobs_of 802 "$(a_job 802 success 08:20:00 08:25:00 fix)"
jobs_of 803 "$(a_job 803 failure 08:24:00 08:28:00)" "$(a_job 803 success 08:26:00 08:27:00 approve-merge)"
jobs_of 806 "$(a_job 806 success 08:40:00 08:50:00 retro)"
cost --json 72 "$T/sessions"
expect_status 0
[ "$(jq -c .split <<<"$out")" = '{"build":130,"review":481,"fix":300,"waiting":3409}' ] || fail "expected the split, found: $(jq -c .split <<<"$out")"
[ "$(jq '.split | add' <<<"$out")" = "$(jq .seconds <<<"$out")" ] || fail "expected the parts to add up to the time"

scenario "a ticket never labelled ready has no split"
github; one_build
echo '[]' > "$T/events"
cost --json 72 "$T/sessions"
expect_status 0
[ "$(jq -c '[.seconds, .split]' <<<"$out")" = '[null,null]' ] || fail "expected no time and no split"

scenario "stops for a person: needs-human put on the ticket or the pull request while it was on neither"
github; one_build
# One stop flagged on both, taken off both; one on the ticket alone, before any pull request; one still on the pull request.
labelled pr-events labeled needs-human 08:20
labelled events labeled needs-human 08:20
labelled pr-events unlabeled needs-human 08:30
labelled events unlabeled needs-human 08:30
labelled events labeled needs-human 08:40
labelled events unlabeled needs-human 08:45
labelled pr-events labeled needs-human 09:00
labelled events labeled needs-human 09:05
labelled pr-events labeled ready 09:06
cost --json 72 "$T/sessions"
expect_status 0
[ "$(jq .stops <<<"$out")" = 3 ] || fail "expected three stops, found: $(jq .stops <<<"$out")"
[ "$(jq .seconds <<<"$out")" = 4320 ] || fail "expected the time from the ticket's first ready"

scenario "a transcript that cannot be read: said, and not counted as a session that cost nothing"
github; one_build
echo '[{"type":"result","total_cost_usd":1.8' > "$T/sessions/pr-72/20261116T080000Z-ryan-run801.json"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$8.66 at API prices, in 2 sessions on claude-fable-5-2; 1 more transcript gave no cost"
expect_output "- **Actions minutes:** 11, in 2 runs"

scenario "a transcript that is an empty file: said, and not left out"
github; one_build
: > "$T/sessions/pr-72/20261116T080000Z-ryan-run801.json"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$8.66 at API prices, in 2 sessions on claude-fable-5-2; 1 more transcript gave no cost"

scenario "a transcript that ends with no result: said, and not counted as a session that cost nothing"
github; one_build
echo '[{"type":"system","subtype":"init","model":"claude-fable-5-2"},{"type":"assistant"}]' > "$T/sessions/pr-72/20261116T080000Z-ryan-run801.json"
: > "$T/sessions/pr-72/20261116T080000Z-adam-run801.json"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$6.82 at API prices, in 1 session on claude-fable-5-2; 2 more transcripts gave no cost"

scenario "no transcript at all: no session and no model, and the runs still counted"
github; one_build
rm -r "$T/sessions/issue-57" "$T/sessions/pr-72"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$0.00 at API prices, in 0 sessions on not known"
expect_output "- **Actions minutes:** 8, in 1 run"

scenario "a cost under ten cents keeps its zero, and one session is not sessions"
github
a_session issue-57 fred 800 0.049
jobs_of 800 "$(a_job 800 success 08:01:00 08:03:10)"
jobs_of 801 "$(a_job 801 success 08:10:00 08:13:01)"
cost 72 "$T/sessions"
expect_output "\$0.05 at API prices, in 1 session on claude-fable-5-2"

scenario "the owner's rounds are told apart from the three"
github; one_build
rounds_are fix-round owner-round
cost 72 "$T/sessions"
expect_output "- **Fix rounds:** 1, and 1 the owner asked for"

scenario "a job still running is counted to now, and every attempt of a run is asked for"
github; one_build
jq -n '{jobs: [{run_id: 801, conclusion: null, started_at: (now - 90 | todate), completed_at: null, runner_id: 1000000001}]}' > "$T/jobs/801"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Actions minutes:** 5, in 2 runs"
expect_call "actions/runs/801/jobs -f filter=all"

scenario "a job that never started is billed nothing"
github; one_build
jobs_of 801 '{"run_id":801,"conclusion":"cancelled","started_at":null,"completed_at":"2026-11-16T08:10:00Z"}' \
  "$(a_job 801 cancelled 08:10:00 08:10:00)"
cost 72 "$T/sessions"
expect_output "- **Actions minutes:** 3, in 1 run"

scenario "a job cancelled while it waited for a runner is billed nothing, however long it waited"
github; one_build
jobs_of 801 "$(a_job 801 cancelled 08:10:00 08:16:00 ci null)" "$(a_job 801 cancelled 08:10:00 08:16:00 ci 0)"
cost 72 "$T/sessions"
expect_output "- **Actions minutes:** 3, in 1 run"

scenario "a job on a runner the owner keeps is billed nothing, and the split still counts the time it ran"
github; one_build
jobs_of 800 "$(a_job 800 success 08:01:00 08:03:10 implement 7 Default)"
jobs_of 801 "$(a_job 801 success 08:10:00 08:16:00 ci 7 Default)" "$(a_job 801 success 08:10:00 08:10:30)"
cost 72 "$T/sessions"
expect_output "- **Actions minutes:** 1, in 2 runs"
cost --json 72 "$T/sessions"
[ "$(jq -c .split <<<"$out")" = '{"build":130,"review":360,"fix":0,"waiting":3830}' ] || fail "expected the split, found: $(jq -c .split <<<"$out")"

scenario "a ticket that took days: the time is in days and hours"
github; one_build
echo '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-13T06:00:00Z"}]' > "$T/events"
cost 72 "$T/sessions"
expect_output "- **Ready to merged:** 3 d 3 h"

scenario "a ticket merged within the hour: the time is in minutes"
github; one_build
echo '[{"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-16T08:30:00Z"}]' > "$T/events"
cost 72 "$T/sessions"
expect_output "- **Ready to merged:** 42 min"

scenario "a ticket never labelled ready: the time is not known, and says why"
github; one_build
echo '[{"event":"labeled","label":{"name":"factory"},"created_at":"2026-11-16T07:00:00Z"}]' > "$T/events"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Ready to merged:** not known: the ticket was never labelled \`ready\`"

scenario "a pull request that closes no ticket: its cost, and no time"
github; one_build
pull_request 72 none "2026-11-16T09:12:00Z"
echo '{"workflow_runs":[]}' > "$T/runs"
cost 72 "$T/sessions"
expect_status 0
expect_output "- **Claude usage:** \$3.39 at API prices, in 2 sessions"
expect_output "- **Ready to merged:** not known: the pull request closes no ticket"
expect_no_call "/events"
cost --json 72 "$T/sessions"
[ "$(jq -c '[.stops, .split]' <<<"$out")" = '[null,null]' ] || fail "expected no stops and no split for a pull request with no ticket"

scenario "a pull request not merged: stops, and prints no cost"
github; one_build
pull_request 72 57 null
cost 72 "$T/sessions"
expect_failure
expect_output "Pull request #72 is not merged, so what its ticket cost is not known yet."
expect_no_output "Claude usage"

for words in "pr view 72 --json number" "api repos/{owner}/{repo}/issues/72/comments" "api --method GET repos/{owner}/{repo}/actions/runs -f branch" \
    "api --method GET repos/{owner}/{repo}/actions/runs/800/jobs" "api repos/{owner}/{repo}/issues/57/events" \
    "api repos/{owner}/{repo}/issues/72/events"; do
  scenario "stops with a message, and prints no cost, when this fails: gh $words"
  github; one_build
  echo "$words" > "$T/fail"
  cost 72 "$T/sessions"
  expect_failure
  expect_output "not known"
  expect_no_output "Claude usage"
  cost --json 72 "$T/sessions"
  expect_failure
  expect_no_output '"merged_at"'
done

nothing_left() { [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder, found: $(ls -A "$T/tmp")"; }

scenario "with no sessions folder: downloads only the ticket's two folders, and only their transcripts, and leaves nothing behind"
github; one_build
a_session pr-73 adam 811 9
a_session issue-58 esme 810 9
mkdir -p "$T/sessions/pr-72/screenshots/abc" "$T/sessions/lessons"
echo png > "$T/sessions/pr-72/screenshots/abc/1.png"
echo notes > "$T/sessions/pr-72/notes.txt"
echo '{}' > "$T/sessions/lessons/pr-72.json"
cost 72
expect_status 0
expect_output "- **Claude usage:** \$10.21 at API prices, in 3 sessions on claude-fable-5-2"
expect_output "- **Actions minutes:** 11, in 2 runs"
expect_call "gh api repos/{owner}/{repo}/git/trees/sessions"
expect_call "gh api repos/{owner}/{repo}/git/trees/pr-72"
expect_call "gh api repos/{owner}/{repo}/git/trees/issue-57"
expect_call "gh api repos/{owner}/{repo}/git/blobs/pr-72@20261116T080000Z-adam-run801.json -H Accept: application/vnd.github.raw+json"
[ "$(grep -c "git/trees/" "$T/calls")" = 3 ] || fail "expected three listings: the branch and the two folders"
[ "$(grep -c "git/blobs/" "$T/calls")" = 3 ] || fail "expected three downloads: the three transcripts"
expect_no_call "tarball"
nothing_left
[ -z "$(ls -A "$T/work")" ] || fail "expected nothing left in the working folder"

scenario "with no sessions folder: a folder the branch does not hold is not asked for, and is no error"
github; one_build
rm -r "$T/sessions/issue-57"
cost 72
expect_status 0
expect_output "- **Claude usage:** \$3.39 at API prices, in 2 sessions on claude-fable-5-2"
expect_no_call "git/trees/issue-57"
nothing_left

scenario "with no sessions folder: a branch that holds neither folder gives no session, and is no error"
github; one_build
rm -r "$T/sessions/issue-57" "$T/sessions/pr-72"
cost 72
expect_status 0
expect_output "- **Claude usage:** \$0.00 at API prices, in 0 sessions on not known"
expect_no_call "git/blobs"

scenario "with no sessions folder: a pull request that closes no ticket has only its own folder downloaded"
github; one_build
pull_request 72 none "2026-11-16T09:12:00Z"
echo '{"workflow_runs":[]}' > "$T/runs"
cost 72
expect_status 0
expect_output "- **Claude usage:** \$3.39 at API prices, in 2 sessions"
expect_no_call "git/trees/issue-"

for words in "pr view 72 --json body" "api repos/{owner}/{repo}/git/trees/sessions" "api repos/{owner}/{repo}/git/trees/pr-72" \
    "api repos/{owner}/{repo}/git/trees/issue-57" "api repos/{owner}/{repo}/git/blobs/pr-72@20261116T080000Z-ryan"; do
  scenario "with no sessions folder: stops with a message, prints no cost and leaves nothing behind, when this fails: gh $words"
  github; one_build
  echo "$words" > "$T/fail"
  cost 72
  expect_failure
  expect_output "not known"
  expect_no_output "Claude usage"
  nothing_left
done

scenario "with no sessions folder: a list of folders that GitHub cut short stops it, and is not read as a ticket with no session"
github; one_build
: > "$T/truncated"
cost 72
expect_failure
expect_output "Could not list the folders of the sessions branch, so what the agents' sessions cost is not known."
expect_no_output "Claude usage"
nothing_left

# Three more pull requests: #73 merged in the same month, #74 in the next, #75 for no ticket, and #76 never merged.
a_month() {
  one_build
  pull_request 73 58 "2026-11-30T23:59:59Z"
  pull_request 74 59 "2026-12-01T00:00:00Z"
  pull_request 75 none "2026-11-20T10:00:00Z"
  jq -n '[{number: 76, merged_at: null}, {number: 75, merged_at: "2026-11-20T10:00:00Z"}, {number: 74, merged_at: "2026-12-01T00:00:00Z"},
          {number: 73, merged_at: "2026-11-30T23:59:59Z"}, {number: 72, merged_at: "2026-11-16T09:12:00Z"}]' > "$T/pulls"
  a_session issue-58 esme 810 0.5
  echo '[{"type":"result"' > "$T/sessions/issue-58/20261130T080000Z-adam-run811.json"
  jobs_of 810 "$(a_job 810 success 08:01:00 08:01:30)"
  jobs_of 811 "$(a_job 811 success 08:01:00 08:02:30)"
}

scenario "a month: a table with a row for each ticket whose pull request merged in it, and no other"
github; a_month
cost --month 2026-11 "$T/sessions"
expect_status 0
expect_output "| Ticket | Claude usage | Sessions | Model | Actions minutes | Runs | Fix rounds | Ready to merged |"
expect_output "| #57 feat: test with main | \$10.21 | 3 | claude-fable-5-2 | 11 | 2 | 0 | 1 h 12 min |"
expect_output "| #58 feat: test with main | \$0.50; 1 more transcript gave no cost | 1 | claude-fable-5-2 | 11 | 3 | 0 | 14 d 16 h |"
[ "$(grep -c '^|' <<<"$out")" = 4 ] || fail "expected a heading, a rule and two rows"
expect_no_call "pr view 74"
expect_no_call "pr view 76"

scenario "a month: a merged pull request that closes no ticket has no row, and its cost is not worked out"
github; a_month
echo "api --method GET repos/{owner}/{repo}/actions/runs -f branch=feat/none-test-with-main" > "$T/fail"
cost --month 2026-11 "$T/sessions"
expect_status 0
[ "$(grep -c '^|' <<<"$out")" = 4 ] || fail "expected a heading, a rule and two rows"
expect_no_call "pr view 75 --json number,"

scenario "a month with no sessions folder: the branch is listed once, and each merged ticket's folders are downloaded"
github; a_month
cost --month 2026-11
expect_status 0
expect_output "| #57 feat: test with main | \$10.21 | 3 | claude-fable-5-2 | 11 | 2 | 0 | 1 h 12 min |"
expect_output "| #58 feat: test with main | \$0.50; 1 more transcript gave no cost | 1 |"
[ "$(grep -c "git/trees/sessions" "$T/calls")" = 1 ] || fail "expected the branch's folders to be listed once"
expect_call "git/trees/issue-58"
nothing_left

scenario "a month in which nothing merged: says so"
github; a_month
cost --month 2026-10 "$T/sessions"
expect_status 0
expect_output "No ticket had its pull request merged in 2026-10."

scenario "a month: stops with a message, and prints no table, when the pull requests cannot be listed"
github; a_month
echo "api repos/{owner}/{repo}/pulls" > "$T/fail"
cost --month 2026-11 "$T/sessions"
expect_failure
expect_output "Could not list the pull requests merged in 2026-11"
expect_no_output "| Ticket"

scenario "a month: stops with a message, and prints no table, when one ticket's cost cannot be worked out"
github; a_month
echo "api repos/{owner}/{repo}/issues/58/events" > "$T/fail"
cost --month 2026-11 "$T/sessions"
expect_failure
expect_output "Could not read the events of ticket #58"
expect_no_output "| Ticket"

for words in "" "--month" "--month 2026-13" "--month november" "seventy" "--json" "--json seventy" "--table 72"; do
  scenario "refuses, with its usage and no call to GitHub: ticket-cost.sh $words"
  github
  # shellcheck disable=SC2086
  cost $words
  expect_failure
  expect_output "Usage: ticket-cost.sh <pr-number>"
  expect_no_call "gh "
done
