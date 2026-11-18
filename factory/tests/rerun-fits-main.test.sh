#!/usr/bin/env bash
# Tests for factory/scripts/rerun-fits-main.sh, which runs fits-main again on the latest ci run of a pull request.
. "$(dirname "$0")/helpers.sh"

head=5555555555555555555555555555555555555555

# $T/statuses holds what `gh run view` answers, one line per asking, the last repeating; $T/fail the gh calls that fail.
a_finished_run() {
  echo '[{"databaseId":900,"status":"completed"}]' > "$T/runs"
  echo '{"jobs":[{"id":30,"name":"checks"},{"id":31,"name":"fits-main"},{"id":32,"name":"merge"}]}' > "$T/jobs"
  echo in_progress > "$T/statuses"
  : > "$T/fail"
  export head
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr view 7 --json headRefOid "*) json "{\"headRefOid\":\"$head\"}" "$@" ;;
      "run list --workflow ci.yml --commit $head --limit 20 "*) json "$(cat "$T/runs")" "$@" ;;
      "run view 900 --json status "*)
        json "{\"status\":\"$(head -n 1 "$T/statuses")\"}" "$@"
        if [ "$(wc -l < "$T/statuses")" -gt 1 ]; then tail -n +2 "$T/statuses" > "$T/statuses.rest"; mv "$T/statuses.rest" "$T/statuses"; fi ;;
      "api repos/{owner}/{repo}/actions/runs/900/jobs "*) json "$(cat "$T/jobs")" "$@" ;;
      "run rerun --job "*) echo "requested" ;;
      "workflow run "*) echo "created" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
  stub date 'now=$(cat "$T/clock" 2>/dev/null || echo 1000); echo $((now + 5)) > "$T/clock"; echo "$now"'
}
still_going() { echo '[{"databaseId":900,"status":"in_progress"}]' > "$T/runs"; }

scenario "runs the fits-main job again on the latest ci run for the pull request's head"
a_finished_run
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7
expect_status 0
expect_call "gh run rerun --job 31"
expect_output "fits-main is running again for pull request #7"
expect_no_output "requested"
expect_no_call "gh workflow run"
expect_no_call "gh run view"

scenario "runs that one job again, and not the whole run or another job"
a_finished_run
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7
[ "$(grep -c '^gh run rerun' "$T/calls")" = 1 ] || fail "expected one re-run"
expect_no_call "gh run rerun 900"
expect_no_call "--job 30"
expect_no_call "--job 32"

scenario "called from the run that is still going, starts the workflow that waits for it to end"
a_finished_run
still_going
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 "$scripts/rerun-fits-main.sh" 7
expect_status 0
expect_call "gh workflow run rerun-fits-main.yml -f pr=7"
expect_output "fits-main will run again for pull request #7 as soon as this run has ended"
expect_no_call "gh run rerun"

scenario "called from another run, leaves a run that is still going and says why"
a_finished_run
still_going
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=901 "$scripts/rerun-fits-main.sh" 7
expect_status 0
expect_output "the ci run for pull request #7 is still going"
expect_no_call "gh run rerun"
expect_no_call "gh workflow run"
expect_no_call "gh run view"

scenario "given time to wait, runs the job again once the run has ended"
a_finished_run
still_going
printf 'in_progress\nin_progress\ncompleted\n' > "$T/statuses"
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=901 "$scripts/rerun-fits-main.sh" 7 120
expect_status 0
expect_call "gh run rerun --job 31"
[ "$(grep -c '^gh run view 900' "$T/calls")" = 3 ] || fail "expected three askings, got $(grep -c '^gh run view 900' "$T/calls")"

scenario "given time to wait, gives up when the run has not ended by then"
a_finished_run
still_going
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7 30
expect_status 0
expect_output "the ci run for pull request #7 is still going"
expect_no_call "gh run rerun"

scenario "does not hand a finished run to the waiting workflow, even from that run"
a_finished_run
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 "$scripts/rerun-fits-main.sh" 7
expect_call "gh run rerun --job 31"
expect_no_call "gh workflow run"

scenario "fails when the head has no ci run"
a_finished_run
echo '[]' > "$T/runs"
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7
expect_failure
expect_output "pull request #7 has no ci run for its head 5555555"
expect_no_call "gh run rerun"

scenario "says so, and fails nothing, when the run began before fits-main was installed"
a_finished_run
echo '{"jobs":[{"id":30,"name":"checks"},{"id":32,"name":"merge"}]}' > "$T/jobs"
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7
expect_status 0
expect_output "began before fits-main was installed"
expect_no_call "gh run rerun"

for words in "pr view 7" "run list" "api repos/{owner}/{repo}/actions/runs/900/jobs" "run rerun"; do
  scenario "fails with gh's message when this fails: gh $words"
  a_finished_run
  echo "$words" > "$T/fail"
  run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7
  expect_failure
  expect_output "gh: failed: $words"
  expect_no_output "fits-main is running again"
done

scenario "fails when the waiting workflow could not be started"
a_finished_run
still_going
echo "workflow run" > "$T/fail"
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 "$scripts/rerun-fits-main.sh" 7
expect_failure
expect_no_output "fits-main will run again"

scenario "fails when the run's state could not be read while waiting"
a_finished_run
still_going
echo "run view" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/rerun-fits-main.sh" 7 120
expect_failure
expect_no_call "gh run rerun"

# The job would otherwise repeat `checks` on every push, or wait for a job a re-run does not run (decisions M17).
scenario "the job it runs again needs no other job in ci.yml, and runs only when asked for again"
job=$(awk '$0 == "  fits-main:" { on = 1; next } /^  [a-z-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml")
! grep -q '^    needs:' <<<"$job" || fail "expected fits-main to need no job"
grep -qxF '    if: github.event.pull_request.draft == false && github.run_attempt > 1' <<<"$job" \
  || fail "expected fits-main to run only in an attempt after the first"
