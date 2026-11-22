#!/usr/bin/env bash
# Tests for watch.sh: what the driver of a backlog watches, and when the watch ends.
. "$(dirname "$0")/helpers.sh"

# A sixth wait fails, so that a watch that should have ended fails its test and never hangs it.
# A run in "$T/runs" ended as its `conclusion` says, or in failure, and is listed only when that ending is asked for.
# Its workflow's id is its workflow's name, a push started it unless its `event` says otherwise, and it started in the
# order of its id unless its `startedAt` says when. "$T/open" holds the branches with an open pull request.
github() {
  echo '[]' > "$T/pulls"
  echo '[]' > "$T/issues"
  echo '[]' > "$T/proposals"
  echo '[]' > "$T/proofs"
  echo '[]' > "$T/runs"
  echo '[]' > "$T/open"
  main_is abc1234def "fix: wait out the install gap (#139)"
  : > "$T/fail"
  echo 0 > "$T/waits"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --label needs-human --limit 100 --json number,title"*) json "$(cat "$T/pulls")" "$@" ;;
      "api repos/{owner}/{repo}/commits/main"*) json "$(cat "$T/main")" "$@" ;;
      "issue list --state open --label needs-human --limit 100 --json number,title"*) json "$(cat "$T/issues")" "$@" ;;
      "issue list --state open --label proposal --limit 100 --json number,title"*) json "$(cat "$T/proposals")" "$@" ;;
      "issue list --state open --label proof --limit 100 --json number,title"*) json "$(cat "$T/proofs")" "$@" ;;
      "pr list --state open --limit 100 --json headRefName"*) json "$(cat "$T/open")" "$@" ;;
      "run list --status "*" --limit 20 --json databaseId,workflowDatabaseId,workflowName,headBranch,event,startedAt,displayTitle"*)
        json "$(jq -c --arg ended "$4" "map(select((.conclusion // \"failure\") == \$ended) | .workflowDatabaseId = .workflowName
          | .event //= \"push\" | .startedAt //= (.databaseId | todate))" "$T/runs" 2>/dev/null \
          || cat "$T/runs")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/"*"/runs -f branch="*" -f status=success -f per_page=1 "*)
        workflow=${4#*/workflows/}
        # Read on a line of its own: inside a quoted word, bash 3.2 on a Mac splits the filter at the comma in its braces.
        passed=$(jq -c --arg workflow "${workflow%/runs}" --arg branch "${6#branch=}" "{workflow_runs: map(select(
          .conclusion == \"success\" and .workflowName == \$workflow and .headBranch == \$branch) | {id: .databaseId, run_started_at: (.startedAt // (.databaseId | todate))}) | sort_by(-.id) | .[:1]}" "$T/runs")
        json "$passed" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep '
    waits=$(($(cat "$T/waits") + 1))
    echo "$waits" > "$T/waits"
    [ "$waits" -le 5 ] || { echo "the watch was still going after five waits" >&2; exit 1; }
    [ ! -f "$T/after-$waits" ] || . "$T/after-$waits"'
}
main_is() {
  jq -cn --arg sha "$1" --arg message "$2"$'\n\nIts body.' '{sha: $sha, commit: {message: $message}}' > "$T/main"
}
# after <n> <bash>: what happens on GitHub during wait <n>.
after() { printf '%s\n' "$2" > "$T/after-$1"; }
open_branch='[{"headRefName":"feat/12-export-forecast-csv"}]'
# failed_and <run>...: a failed run of ci on the open pull request's branch, and the runs given.
failed_and() {
  echo "$open_branch" > "$T/open"
  printf '%s\n' '{"databaseId":4390,"workflowName":"ci","headBranch":"feat/12-export-forecast-csv","displayTitle":"feat: export forecast as CSV"}' "$@" | jq -cs . > "$T/runs"
}
merge='jq -cn "{sha: \"fed9876abc\", commit: {message: \"feat: export forecast as CSV (#12)\"}}" > "$T/main"'
expect_looks() {
  local looks
  looks=$(grep -c '^gh api repos/{owner}/{repo}/commits/main' "$T/calls" || true)
  [ "$looks" = "$1" ] || fail "expected $1 looks at GitHub, got $looks"
}

scenario "prints the pull requests waiting, the last merge, what is flagged and the failed runs"
github
echo '[{"number":148,"title":"fix: remove the merge attribute switch"}]' > "$T/pulls"
echo '[{"number":133,"title":"Remove the merge attribute switch from fits-main"}]' > "$T/issues"
failed_and
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_output "waiting for the owner: pull request #148 fix: remove the merge attribute switch"
expect_output "last merge: abc1234 fix: wait out the install gap (#139)"
expect_output "flagged for a person: #133 Remove the merge attribute switch from fits-main"
expect_output "failed run: 4390 ci on feat/12-export-forecast-csv: feat: export forecast as CSV"
expect_no_output "Its body."

scenario "leaves out a failed run on the branch of a pull request that merged or closed"
github
failed_and
echo '[{"headRefName":"feat/14-pace-per-mile"}]' > "$T/open"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_no_output "failed run"
expect_no_call "actions/workflows"

scenario "leaves out a failed run once a later run of the same workflow on the same branch has passed"
github
failed_and '{"databaseId":4395,"conclusion":"success","workflowName":"ci","headBranch":"feat/12-export-forecast-csv","displayTitle":"fix: the export"}'
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_no_output "failed run"

scenario "lists a failed run after which only another workflow, another branch or an earlier run passed"
github
failed_and '{"databaseId":4395,"conclusion":"success","workflowName":"review","headBranch":"feat/12-export-forecast-csv","displayTitle":"a run"}' \
  '{"databaseId":4396,"conclusion":"success","workflowName":"ci","headBranch":"main","displayTitle":"a run"}' \
  '{"databaseId":4380,"conclusion":"success","workflowName":"ci","headBranch":"feat/12-export-forecast-csv","displayTitle":"a run"}'
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_output "failed run: 4390 ci on feat/12-export-forecast-csv: feat: export forecast as CSV"

scenario "lists a failed run that was run again and failed after a newer run had passed"
github
failed_and '{"databaseId":4395,"conclusion":"success","workflowName":"ci","headBranch":"feat/12-export-forecast-csv","displayTitle":"fix: the export"}'
jq -c '.[0].startedAt = "2026-11-22T10:00:00Z"' "$T/runs" > "$T/again" && mv "$T/again" "$T/runs"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_output "failed run: 4390 ci on feat/12-export-forecast-csv: feat: export forecast as CSV"

for event in push schedule; do
  scenario "leaves out a failed run on main that a $event started, once a later run of its workflow has passed"
  github
  echo "[{\"databaseId\":4390,\"event\":\"$event\",\"workflowName\":\"flag-idle\",\"headBranch\":\"main\",\"displayTitle\":\"flag-idle\"},
    {\"databaseId\":4395,\"conclusion\":\"success\",\"workflowName\":\"flag-idle\",\"headBranch\":\"main\",\"displayTitle\":\"flag-idle\"}]" > "$T/runs"
  after 1 "$merge"
  run "$scripts/watch.sh"
  expect_status 0
  expect_no_output "failed run"
done

scenario "lists a failed build of one ticket on main, though the build of another ticket passed after it"
github
echo '[{"databaseId":4390,"event":"workflow_dispatch","workflowName":"implement","headBranch":"main","displayTitle":"implement"},
  {"databaseId":4395,"conclusion":"success","event":"workflow_dispatch","workflowName":"implement","headBranch":"main","displayTitle":"implement"}]' > "$T/runs"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_output "failed run: 4390 implement on main: implement"
expect_no_call "actions/workflows"

scenario "exits when a later run passes, and says the failed run is gone"
github
failed_and
cp "$T/runs" "$T/failed"
after 1 'jq -c ". + [{databaseId: 4395, conclusion: \"success\", workflowName: \"ci\", headBranch: \"feat/12-export-forecast-csv\", displayTitle: \"fix: the export\"}]" "$T/failed" > "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  gone: failed run: 4390 ci on feat/12-export-forecast-csv: feat: export forecast as CSV"

scenario "asks once at each look for the last passing run of a workflow on a branch, however many of its runs failed"
github
echo '[{"databaseId":4390,"workflowName":"ci","headBranch":"main","displayTitle":"a run"},{"databaseId":4391,"workflowName":"ci","headBranch":"main","displayTitle":"a run"}]' > "$T/runs"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_calls 2 "gh api --method GET repos/{owner}/{repo}/actions/workflows/ci/runs -f branch=main -f status=success -f per_page=1"

scenario "goes on watching while nothing changes, a minute between looks unless told otherwise"
github
after 3 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_looks 4
expect_call "sleep 60"

scenario "waits the seconds it is given between looks"
github
after 1 "$merge"
run "$scripts/watch.sh" 300
expect_status 0
expect_call "sleep 300"
expect_no_call "sleep 60"

scenario "exits when a pull request gains needs-human, and says which"
github
after 2 'echo "[{\"number\":148,\"title\":\"fix: remove the merge attribute switch\"}]" > "$T/pulls"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 3
expect_output "  new: waiting for the owner: pull request #148 fix: remove the merge attribute switch"

scenario "exits when a pull request merges, and says what main was at and is at"
github
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: last merge: fed9876 feat: export forecast as CSV (#12)"
expect_output "  gone: last merge: abc1234 fix: wait out the install gap (#139)"

scenario "exits when a run fails"
github
after 1 'echo "[{\"databaseId\":4391,\"workflowName\":\"implement\",\"headBranch\":\"main\",\"displayTitle\":\"Export forecast as CSV\"}]" > "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: failed run: 4391 implement on main: Export forecast as CSV"

for ended in timed_out startup_failure; do
  scenario "exits when a run ends $ended"
  github
  after 1 "echo '[{\"databaseId\":4392,\"conclusion\":\"$ended\",\"workflowName\":\"implement\",\"headBranch\":\"main\",\"displayTitle\":\"Export forecast as CSV\"}]' > \"\$T/runs\""
  run "$scripts/watch.sh"
  expect_status 0
  expect_looks 2
  expect_output "  new: failed run: 4392 implement on main: Export forecast as CSV"
done

scenario "does not exit when a run is cancelled, and never prints it"
github
after 1 'echo "[{\"databaseId\":4393,\"conclusion\":\"cancelled\",\"workflowName\":\"implement\",\"headBranch\":\"main\",\"displayTitle\":\"Export forecast as CSV\"}]" > "$T/runs"'
after 3 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_looks 4
expect_no_output "4393"

scenario "a run that two endings both list is printed once"
github
echo '[{"databaseId":4394,"workflowName":"ci","headBranch":"main","displayTitle":"a run"}]' > "$T/runs"
stub gh "$(sed 's|(.conclusion // \\"failure\\") == \\$ended|true|' "$T/bin/gh" | sed '1,/^}$/d')"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
[ "$(grep -c 'failed run: 4394' <<<"$out")" = 2 ] || fail "expected run 4394 once at the first look and once at the last"

# The 20 newest timed-out runs keep their own oldest: a rerun there lets an older one slide in beside newer failures.
scenario "an older timed-out run that takes the place of one run again is not new"
github
{ seq 4400 4420 | jq -c '{databaseId: ., conclusion: "timed_out", workflowName: "ci", headBranch: "main", displayTitle: "a run"}'
  echo '{"databaseId":4500,"workflowName":"ci","headBranch":"main","displayTitle":"a failure"}'; } > "$T/all"
jq -cs 'map(select(.databaseId != 4400))' "$T/all" > "$T/runs"
jq -cs 'map(select(.databaseId != 4410))' "$T/all" > "$T/after-runs"
after 1 'cp "$T/after-runs" "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  gone: failed run: 4410 ci on main: a run"
expect_no_output "new: failed run"
expect_output "failed run: 4400 ci on main: a run"

scenario "an old run that fails again is new, though 20 newer runs timed out"
github
seq 4401 4420 | jq -c '{databaseId: ., conclusion: "timed_out", workflowName: "ci", headBranch: "main", displayTitle: "a run"}' > "$T/all"
jq -cs . "$T/all" > "$T/runs"
{ cat "$T/all"; echo '{"databaseId":4300,"workflowName":"ci","headBranch":"main","displayTitle":"run again"}'; } | jq -cs . > "$T/after-runs"
after 1 'cp "$T/after-runs" "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: failed run: 4300 ci on main: run again"

# The 20 newest failed runs, as `gh run list --limit 20` gives them: 4320 down to 4300 without the one named.
window_without() {
  seq 4300 4320 | grep -vx "$1" | jq -cn '[inputs | {databaseId: ., workflowName: "ci", headBranch: "main", displayTitle: "a run"}]'
}

scenario "a failed run that is run again is gone, and the older failure that takes its place is not new"
github
window_without 4300 > "$T/runs"
window_without 4310 > "$T/after-runs"
after 1 'cp "$T/after-runs" "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  gone: failed run: 4310 ci on main: a run"
expect_no_output "new: failed run"
expect_output "failed run: 4300 ci on main: a run"

scenario "a run that fails again after being run again is new, though newer runs have failed"
github
window_without 4310 > "$T/runs"
window_without 4300 > "$T/after-runs"
after 1 'cp "$T/after-runs" "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: failed run: 4310 ci on main: a run"

scenario "with fewer failed runs than it reads, a run older than them all that fails again is new"
github
echo '[{"databaseId":4390,"workflowName":"ci","headBranch":"main","displayTitle":"a run"}]' > "$T/runs"
after 1 'echo "[{\"databaseId\":4390,\"workflowName\":\"ci\",\"headBranch\":\"main\",\"displayTitle\":\"a run\"},{\"databaseId\":4380,\"workflowName\":\"ci\",\"headBranch\":\"main\",\"displayTitle\":\"run again\"}]" > "$T/runs"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: failed run: 4380 ci on main: run again"

scenario "exits when a ticket is flagged for a person"
github
after 1 'echo "[{\"number\":12,\"title\":\"Export forecast as CSV\"}]" > "$T/issues"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: flagged for a person: #12 Export forecast as CSV"

scenario "exits when a pull request stops waiting for the owner"
github
echo '[{"number":148,"title":"fix: remove the merge attribute switch"}]' > "$T/pulls"
after 1 'echo "[]" > "$T/pulls"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  gone: waiting for the owner: pull request #148 fix: remove the merge attribute switch"

scenario "prints the open proposals and proof tickets as to read when convenient"
github
echo '[{"number":179,"title":"Wake the watch for timed-out and never-started runs"}]' > "$T/proposals"
echo '[{"number":186,"title":"Confirm Vercel skips a pull request with no app change"}]' > "$T/proofs"
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_output "to read when convenient: proposal #179 Wake the watch for timed-out and never-started runs"
expect_output "to read when convenient: proof ticket #186 Confirm Vercel skips a pull request with no app change"
expect_no_output "flagged for a person"

for kind in "proposals|proposal|Stop a second fix round that changed nothing" "proofs|proof ticket|Confirm the next build skips e2e"; do
  file=${kind%%|*}
  title=${kind##*|}
  name=${kind#*|}
  name=${name%|*}

  scenario "does not exit when a $name is filed, and exits at the merge after it"
  github
  after 1 "echo '[{\"number\":135,\"title\":\"$title\"}]' > \"\$T/$file\""
  after 3 "$merge"
  run "$scripts/watch.sh"
  expect_status 0
  expect_looks 4
  expect_output "  new: last merge: fed9876"
  expect_no_output "new: to read when convenient"
  expect_no_output "flagged for a person: #135"
  expect_output "to read when convenient: $name #135 $title"

  scenario "does not exit when a $name is closed"
  github
  echo "[{\"number\":135,\"title\":\"$title\"}]" > "$T/$file"
  after 1 "echo '[]' > \"\$T/$file\""
  after 3 "$merge"
  run "$scripts/watch.sh"
  expect_status 0
  expect_looks 4
  expect_no_output "gone: to read when convenient"
done

scenario "exits when a ticket is flagged, whatever its title"
github
after 1 'echo "[{\"number\":135,\"title\":\"Factory: a second fix round changed nothing\"}]" > "$T/issues"'
run "$scripts/watch.sh"
expect_status 0
expect_looks 2
expect_output "  new: flagged for a person: #135 Factory: a second fix round changed nothing"

scenario "the same things in another order are not a change"
github
echo '[{"number":12,"title":"Export forecast as CSV"},{"number":14,"title":"Show pace per mile"}]' > "$T/issues"
after 1 'echo "[{\"number\":14,\"title\":\"Show pace per mile\"},{\"number\":12,\"title\":\"Export forecast as CSV\"}]" > "$T/issues"'
after 3 "$merge"
run "$scripts/watch.sh"
expect_status 0
expect_looks 4

scenario "asks only for what is open and flagged, and for runs that failed"
github
after 1 "$merge"
run "$scripts/watch.sh"
expect_call "gh pr list --state open --label needs-human"
expect_call "gh issue list --state open --label needs-human"
expect_call "gh issue list --state open --label proposal"
expect_call "gh issue list --state open --label proof"
expect_call "gh pr list --state open --limit 100 --json headRefName"
expect_call "gh run list --status failure"
expect_call "gh run list --status timed_out"
expect_call "gh run list --status startup_failure"
expect_no_call "gh run list --status cancelled"
expect_call "gh api repos/{owner}/{repo}/commits/main"

for read in "pr list|The pull requests waiting for the owner could not be read" \
  "api|The commit main is at could not be read" \
  "issue list --state open --label needs-human|The issues flagged for a person could not be read" \
  "issue list --state open --label proposal|The proposals could not be read" \
  "issue list --state open --label proof|The proof tickets could not be read" \
  "pr list --state open --limit 100 --json headRefName|The branches with an open pull request could not be read" \
  "run list --status failure|The runs that ended failure could not be read" \
  "run list --status timed_out|The runs that ended timed_out could not be read" \
  "run list --status startup_failure|The runs that ended startup_failure could not be read" \
  "api --method GET|The last passing run of workflow ci on main could not be read"; do
  call=${read%%|*}
  message=${read#*|}

  scenario "stops when \`gh $call\` fails at the first look: that is not 'nothing there'"
  github
  echo '[{"databaseId":4390,"workflowName":"ci","headBranch":"main","displayTitle":"a run"}]' > "$T/runs"
  echo "$call" > "$T/fail"
  run "$scripts/watch.sh"
  expect_status 1
  expect_output "$message"
  expect_output "Run it again."
  expect_no_output "watching:"
  expect_no_call "sleep"

  scenario "stops when \`gh $call\` fails at a later look: that is not a change"
  github
  echo '[{"number":148,"title":"fix: remove the merge attribute switch"}]' > "$T/pulls"
  echo '[{"number":12,"title":"Export forecast as CSV"}]' > "$T/issues"
  echo '[{"databaseId":4390,"workflowName":"ci","headBranch":"main","displayTitle":"a run"}]' > "$T/runs"
  after 2 "echo '$call' > \"\$T/fail\""
  run "$scripts/watch.sh"
  expect_status 1
  expect_looks "$([ "$call" = "pr list" ] && echo 2 || echo 3)"
  expect_output "$message"
  expect_no_output "changed:"
done

scenario "stops when GitHub answers with something that is not a list"
github
echo '{"message":"Server Error"}' > "$T/runs"
run "$scripts/watch.sh"
expect_status 1
expect_output "The runs that ended failure could not be read"

scenario "stops when the wait itself fails"
github
stub sleep 'echo "sleep: interrupted" >&2; exit 1'
run "$scripts/watch.sh"
expect_status 1
expect_no_output "changed:"

scenario "refuses a wait that is not a number of seconds, and asks GitHub nothing"
github
run "$scripts/watch.sh" soon
expect_status 1
expect_output '"soon" is not a number of seconds'
expect_no_call "gh "

scenario "leaves no file behind"
github
after 1 "$merge"
run "$scripts/watch.sh"
expect_status 0
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected nothing left in the working or temporary directory"
