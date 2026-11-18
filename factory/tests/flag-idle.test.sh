#!/usr/bin/env bash
# Tests for flag-idle.sh: a ticket in flight that nothing works on is flagged once (decisions T271a to T271d).
. "$(dirname "$0")/helpers.sh"

# $T/issues and $T/pulls are what in-flight.sh reads; $T/issue-<n> and $T/pull-<n> answer for each one;
# $T/runs-<state> holds the runs in that state; $T/fail holds the start of each call that should fail.
# A flagged ticket leaves $T/issues, as the label's removal has it leave flight; $T/ready is as waiting_on_github says.
github() {
  echo '[]' > "$T/issues"
  echo '[]' > "$T/pulls"
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") cat "$T/pulls" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs -f status="*" -f per_page=100 --jq "*)
        state=${6#status=}
        [ -e "$T/runs-$state" ] || : > "$T/runs-$state"
        json "$(jq -s "{workflow_runs: .}" "$T/runs-$state")" "$@" ;;
      "issue view "*" --json labels,updatedAt --jq "*) json "$(cat "$T/issue-$3")" "$@" ;;
      "pr view "*" --json updatedAt,headRefName,mergeable,isDraft --jq "*) json "$(cat "$T/pull-$3")" "$@" ;;
      "issue edit "*" --add-label needs-human --remove-label in-progress")
        jq -c --argjson n "$3" "map(select(.number != \$n))" "$T/issues" > "$T/issues.new" && mv "$T/issues.new" "$T/issues" ;;
      "issue comment "*) : ;;
      *) waiting_on_github "$@" ;;
    esac'
}
# ticket <number> <minutes since it was touched> [label]: an issue labelled in-progress.
ticket() {
  jq -c --argjson number "$1" '. + [{number: $number}]' "$T/issues" > "$T/issues.new" && mv "$T/issues.new" "$T/issues"
  jq -cn --argjson ago "$2" --arg label "${3:-}" \
    '{updatedAt: (now - $ago * 60 | todate), labels: ([{name: "in-progress"}] + (if $label == "" then [] else [{name: $label}] end))}' > "$T/issue-$1"
}
# pull <number> <branch> <minutes since it was touched> [mergeable] [draft] [label]: an open pull request of the factory's.
pull() {
  jq -c --argjson number "$1" --arg branch "$2" --argjson draft "${5:-false}" --arg label "${6:-}" \
    '. + [{number: $number, headRefName: $branch, author: {login: "app/claude"}, isDraft: $draft,
      labels: (if $label == "" then [] else [{name: $label}] end)}]' "$T/pulls" > "$T/pulls.new" && mv "$T/pulls.new" "$T/pulls"
  jq -cn --arg branch "$2" --argjson ago "$3" --arg mergeable "${4:-MERGEABLE}" --argjson draft "${5:-false}" \
    '{updatedAt: (now - $ago * 60 | todate), headRefName: $branch, mergeable: $mergeable, isDraft: $draft}' > "$T/pull-$1"
}
# a_run <state> <workflow> <branch>
a_run() { jq -cn --arg name "$2" --arg branch "$3" '{name: $name, head_branch: $branch}' >> "$T/runs-$1"; }
flags() { grep -c '^gh issue edit' "$T/calls" || true; }

scenario "flags a ticket idle past the hour, once, and says what was found"
github
ticket 64 300
pull 112 feat/64-three-in-flight 200
run "$scripts/flag-idle.sh"
expect_status 0
expect_call "gh issue edit 64 --add-label needs-human --remove-label in-progress"
expect_call "gh issue comment 64 --body Nothing is working on this ticket. It is in flight (pull request #112), no run is going or queued for it, and nothing has happened on it since "
expect_call ", 200 minutes ago. Pull request #112 is ready for review"
expect_output "flagged: #64 (pull request #112), last touched 200 minutes ago"
[ "$(flags)" = 1 ] || fail "expected one flag, got $(flags)"
# The next look finds the label the first one left.
: > "$T/calls"
ticket 64 0 needs-human
jq -c 'map(select(.number != 64))' "$T/issues" | jq -c 'unique' > "$T/issues.new" && mv "$T/issues.new" "$T/issues"
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 waits for a person"
expect_no_call "gh issue edit"
expect_no_call "gh issue comment"

scenario "a flagged ticket with no pull request gives its place to the ticket that waits with ready"
github
ticket 64 300
pull 112 feat/70-other 10
pull 113 feat/71-another 10
echo '[{"number":81},{"number":80}]' > "$T/ready"
run "$scripts/flag-idle.sh"
expect_status 0
expect_call "gh issue edit 64 --add-label needs-human --remove-label in-progress"
expect_call "gh workflow run implement.yml -f issue=80"
expect_no_call "issue=81"
expect_output "started the build of issue #80, which waited with ready"
[ "$(grep -n 'workflow run' "$T/calls" | cut -d: -f1)" -gt "$(grep -n 'issue comment 64' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the idle one was flagged and told"

scenario "a flagged ticket whose pull request is open still holds its place: the ticket that waits is not started"
github
ticket 64 300
pull 111 feat/64-three-in-flight 200
pull 112 feat/70-other 10
pull 113 feat/71-another 10
echo '[{"number":80}]' > "$T/ready"
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "flagged: #64"
expect_output "3 tickets are being built or checked, so no waiting ticket was started"
expect_no_call "gh workflow run"

scenario "with nothing flagged, the tickets that wait are not looked for"
github
ticket 64 10
echo '[{"number":80}]' > "$T/ready"
run "$scripts/flag-idle.sh"
expect_status 0
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

scenario "a ticket that could not be flagged gave no place back: the tickets that wait are not looked for"
github
ticket 64 300
echo '[{"number":80}]' > "$T/ready"
echo "issue edit 64" > "$T/fail"
run "$scripts/flag-idle.sh"
expect_status 1
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

scenario "a flagged ticket that could not be told why still gives its place to the one that waits"
github
ticket 64 300
echo '[{"number":80}]' > "$T/ready"
echo "issue comment 64" > "$T/fail"
run "$scripts/flag-idle.sh"
expect_status 1
expect_call "gh workflow run implement.yml -f issue=80"

while IFS='|' read -r words message; do
  scenario "fails with a message, the idle ticket flagged and told, when this fails: gh $words"
  github
  ticket 64 300
  echo '[{"number":80}]' > "$T/ready"
  echo "$words" > "$T/fail"
  run "$scripts/flag-idle.sh"
  expect_status 1
  expect_output "$message"
  expect_output "Tickets were flagged, and the tickets that wait with ready were not all started"
  expect_call "gh issue edit 64 --add-label needs-human --remove-label in-progress"
  expect_call "gh issue comment 64"
done <<'CALLS'
api repos/{owner}/{repo}/issues?state=open&labels=ready|the tickets labelled ready could not be read from GitHub
api repos/{owner}/{repo}/issues/80/events|when issue #80 was labelled ready could not be read from GitHub
workflow run implement.yml|the build of these waiting tickets could not be started: #80
CALLS

scenario "leaves a ticket whose pull request has a ci run going"
github
ticket 64 300
pull 112 feat/64-three-in-flight 200
a_run in_progress ci feat/64-three-in-flight
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 has a run going or queued (ci)"
expect_no_call "gh issue edit"
expect_no_call "gh issue comment"

scenario "leaves a ticket whose run is queued, and flags the one beside it that has none"
github
ticket 64 300
pull 112 feat/64-three-in-flight 200
ticket 70 300
pull 113 fix/70-other 200
a_run queued ci feat/64-three-in-flight
a_run in_progress retro main
a_run in_progress flag-idle main
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 has a run going or queued (ci)"
expect_output "flagged: #70"
expect_no_call "gh issue edit 64"
expect_call "gh issue edit 70 --add-label needs-human --remove-label in-progress"

for workflow in implement fix approve-merge rerun-fits-main; do
  scenario "leaves every ticket while a run of $workflow is going: it names no ticket"
  github
  ticket 64 300
  ticket 70 300
  pull 113 fix/70-other 200
  a_run in_progress "$workflow" main
  run "$scripts/flag-idle.sh"
  expect_status 0
  expect_output "left: #64 has a run going or queued ($workflow)"
  expect_output "left: #70 has a run going or queued ($workflow)"
  expect_no_call "gh issue edit"
done

for state in queued in_progress waiting requested pending; do
  scenario "asks for the runs that are $state"
  github
  ticket 64 300
  a_run "$state" implement main
  run "$scripts/flag-idle.sh"
  expect_status 0
  expect_output "left: #64 has a run going or queued"
  expect_no_call "gh issue edit"
done

scenario "leaves a pull request that waits for a person, and reads nothing more of it"
github
pull 111 fix/57-fits-main 5000 MERGEABLE false needs-human
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #57 waits for a person"
expect_no_call "gh issue view"
expect_no_call "gh issue edit"

scenario "leaves a ticket flagged for a person whose pull request carries no flag"
github
ticket 64 5000 needs-human
pull 112 feat/64-three-in-flight 5000
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 waits for a person"
expect_no_call "gh issue edit"

scenario "leaves a ticket touched inside the hour"
github
ticket 64 59
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 was touched 59 minutes ago"
expect_no_call "gh issue edit"

scenario "leaves a ticket whose pull request was touched inside the hour, however old the issue"
github
ticket 64 5000
pull 112 feat/64-three-in-flight 10
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: #64 was touched 10 minutes ago"
expect_no_call "gh issue edit"

scenario "flags a ticket with no pull request, and says how to start its build"
github
ticket 64 61
run "$scripts/flag-idle.sh"
expect_status 0
expect_call "gh issue comment 64 --body Nothing is working on this ticket. It is in flight (being built), no run"
expect_call "No build of it is going. Add the \`ready\` label again to start one."

scenario "flags a ticket whose build left a draft, and says how to start its build"
github
ticket 64 300
pull 130 feat/64-three-in-flight 200 MERGEABLE true
run "$scripts/flag-idle.sh"
expect_status 0
expect_call "It is in flight (being built, in draft pull request #130)"
expect_call "Add the \`ready\` label again to start one."

scenario "says of a conflict that no fix round is going, and how to start one"
github
ticket 64 300
pull 112 feat/64-three-in-flight 200 CONFLICTING
run "$scripts/flag-idle.sh"
expect_status 0
expect_call "Pull request #112 conflicts with \`main\`, and no fix round is going for it. To start one: \`gh workflow run fix.yml -f pr=112\`."

scenario "names the run that found it, in a workflow"
github
ticket 64 300
GITHUB_RUN_ID=9 GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo run "$scripts/flag-idle.sh"
expect_status 0
expect_call "Found by https://github.com/owner/repo/actions/runs/9"

scenario "leaves a pull request that names no ticket: there is none to flag"
github
pull 120 chore/tidy-things 5000
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "left: pull request #120, which names no ticket"
expect_no_call "gh issue edit"
expect_output "nothing to flag"

scenario "says so when nothing is in flight"
github
run "$scripts/flag-idle.sh"
expect_status 0
expect_output "Nothing is in flight: nothing to flag."
expect_no_call "actions/runs"

# A failed read flags nothing, not even the idle ticket read before it.
for words in "api repos/{owner}/{repo}/issues?state=open&labels=in-progress" "pr list" "api --method GET repos/{owner}/{repo}/actions/runs -f status=queued" \
  "api --method GET repos/{owner}/{repo}/actions/runs -f status=pending" "issue view 70" "pr view 113"; do
  scenario "flags nothing, and says so, when this fails: gh $words"
  github
  ticket 64 300
  ticket 70 300
  pull 113 fix/70-other 200
  echo "$words" > "$T/fail"
  run "$scripts/flag-idle.sh"
  expect_status 1
  expect_output "so nothing was flagged."
  expect_no_call "gh issue edit"
  expect_no_call "gh issue comment"
done

scenario "a failed read is not taken for no run going"
github
ticket 64 300
a_run in_progress implement main
echo "api --method GET repos/{owner}/{repo}/actions/runs -f status=in_progress" > "$T/fail"
run "$scripts/flag-idle.sh"
expect_status 1
expect_output "The runs that are in_progress could not be read from GitHub, so nothing was flagged."
expect_no_call "gh issue edit"

scenario "stops when GitHub answers a time that is not one"
github
ticket 64 300
echo '{"updatedAt":"yesterday","labels":[]}' > "$T/issue-64"
run "$scripts/flag-idle.sh"
expect_status 1
expect_output "When ticket #64 was last touched (yesterday) could not be worked out, so nothing was flagged."
expect_no_call "gh issue edit"

scenario "says a ticket was not flagged when the label cannot be added, tells it nothing, and flags the next"
github
ticket 64 300
ticket 70 300
echo "issue edit 64" > "$T/fail"
run "$scripts/flag-idle.sh"
expect_status 1
expect_output "needs-human could not be added to it: it was not flagged."
expect_no_call "gh issue comment 64"
expect_call "gh issue edit 70 --add-label needs-human --remove-label in-progress"
expect_call "gh issue comment 70"

scenario "fails when a flagged ticket cannot be told why"
github
ticket 64 300
echo "issue comment 64" > "$T/fail"
run "$scripts/flag-idle.sh"
expect_status 1
expect_call "gh issue edit 64 --add-label needs-human --remove-label in-progress"
expect_output "Ticket #64 was flagged needs-human, with nothing working on it, but it could not be told why."

# The workflow: what the script is left to rely on.
workflow="$root/factory/workflows/flag-idle.yml"
scenario "the workflow runs rerun-refused.sh first, and flag-idle.sh even when that failed"
steps=$(grep -n 'run: factory/scripts/' "$workflow" | sed 's/.*run: //' | tr '\n' ';')
[ "$steps" = "factory/scripts/rerun-refused.sh;factory/scripts/flag-idle.sh;" ] || fail "expected rerun-refused.sh then flag-idle.sh, got: $steps"
grep -B4 'run: factory/scripts/flag-idle.sh' "$workflow" | grep -qF 'if: ${{ !cancelled() }}' \
  || fail "expected the flag-idle.sh step to run after a failed step"

scenario "the workflow's token may do what the two scripts need"
for permission in "issues: write" "pull-requests: read" "actions: write" "checks: read" "contents: read"; do
  grep -qF "      $permission" "$workflow" || fail "expected the permission: $permission"
done
