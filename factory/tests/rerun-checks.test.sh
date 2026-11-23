#!/usr/bin/env bash
# Tests for rerun-checks.sh: `checks` runs again in the latest ci run for a head once it has ended (decisions A134a).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

rerun() { run env GH_TOKEN=workflow-token "$scripts/rerun-checks.sh" 7 "${1:-120}"; }

scenario "runs the checks job of the latest ci run again, and nothing else"
checks_failed
rerun
expect_status 0
expect_call "gh run rerun --job 30"
[ "$(grep -c '^gh run rerun' "$T/calls")" = 1 ] || fail "expected one job to be run again"
[ "$out" = "checks is running again for pull request #7" ] || fail "expected one sentence saying checks is running again"
expect_no_call "sleep"
expect_no_call "gh pr comment"
expect_no_call "gh workflow run"

scenario "waits for a run that is still going, then runs the job again"
checks_failed
printf 'in_progress\nin_progress\ncompleted\n' > "$T/status"
rerun
expect_status 0
[ "$(grep -c '^sleep 5$' "$T/calls")" = 2 ] || fail "expected two waits of 5 seconds"
expect_call "gh run rerun --job 30"

scenario "stops with a message, and runs nothing again, when the run has not ended in time"
checks_failed
echo in_progress > "$T/status"
rerun 0
expect_status 1
expect_output "The ci run 900 for pull request #7 had not ended after 0 seconds, so its checks were not run again."
expect_no_call "gh run rerun"

scenario "stops with a message when the pull request has no ci run for its head"
checks_failed; no_ci_run
rerun
expect_status 1
expect_output "Pull request #7 has no ci run for its head 5555555, so its checks were not run again."
expect_no_call "gh run rerun"

scenario "stops with a message when the run has no job named checks"
checks_failed
echo '{"jobs":[{"id":31,"name":"e2e","conclusion":"success"}]}' > "$T/jobs"
rerun
expect_status 1
expect_output "has no job named checks, so its checks were not run again."
expect_no_call "gh run rerun"

for words in "pr view 7 --json headRefOid" "api repos/{owner}/{repo}/actions/workflows/ci.yml/runs" "run view 900" "api repos/{owner}/{repo}/actions/runs/900/jobs" "run rerun --job 30"; do
  scenario "stops with a message when this fails: gh $words"
  checks_failed
  printf 'in_progress\ncompleted\n' > "$T/status"
  echo "$words" > "$T/fail"
  rerun
  expect_status 1
  expect_no_output "checks is running again"
  case "$words" in
    "run rerun"*) expect_output "GitHub did not run checks again in ci run 900 for pull request #7." ;;
    *) expect_output "so its checks were not run again"; expect_no_call "gh run rerun" ;;
  esac
done
