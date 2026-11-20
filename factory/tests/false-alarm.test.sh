#!/usr/bin/env bash
# Tests for factory/scripts/false-alarm.sh: whether a failure is nothing an engineer can fix (decisions A134a, A134b).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

alarm() {
  GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" 7 >/dev/null 2>&1
  : > "$T/calls"
  run env GH_TOKEN=workflow-token "$scripts/false-alarm.sh" 7 "$T/failed.txt"
}
expect_result() { [ "$out" = "$1" ] || fail "expected it to print $1 and nothing else"; }

scenario "the two sentences it looks for are ones check-inventory.sh prints"
for sentence in "was edited directly. Undo that and change" "in case an install was on its way, and they still differ."; do
  grep -qF -- "$sentence" "$scripts/check-inventory.sh" || fail "check-inventory.sh no longer prints: $sentence"
  grep -qF -- "\"$sentence\"" "$scripts/false-alarm.sh" || fail "false-alarm.sh does not look for: $sentence"
done

scenario "true when only checks failed, saying an installed copy was edited directly, in the run's first attempt"
checks_failed; not_settled
alarm
expect_status 0
expect_result true

scenario "true for the other sentence: an approved change that was still not installed after the wait"
checks_failed; not_settled "$never_installed"
alarm
expect_status 0
expect_result true

scenario "false for a run an install behind in its own workflow: running checks again would not give it main's workflow"
grep -qF -- "this run uses the workflow from before the install" "$scripts/check-inventory.sh" || fail "check-inventory.sh no longer prints the sentence this scenario is about"
checks_failed; not_settled "$stale_run"
alarm
expect_status 0
expect_result false
[ ! -s "$T/calls" ] || fail "expected no call to GitHub"

scenario "false for any other failure of checks, without asking GitHub anything"
checks_failed
alarm
expect_status 0
expect_result false
[ ! -s "$T/calls" ] || fail "expected no call to GitHub"

scenario "false when another job failed as well: that one is an engineer's to fix"
checks_failed; not_settled
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"failure"},{"id":31,"name":"e2e","conclusion":"failure"}]}' > "$T/jobs"
alarm
expect_result false

scenario "false when another job failed with the sentence in its log"
checks_failed
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":31,"name":"e2e","conclusion":"failure"}]}' > "$T/jobs"
echo "$edited_directly" > "$T/log-31"
alarm
expect_result false

scenario "false when the pull request is in conflict as well"
checks_failed; not_settled; in_conflict
alarm
expect_result false

scenario "false when nothing failed"
checks_failed; nothing_failed
alarm
expect_result false

scenario "false in a later attempt of the run: the same sentence twice is no gap of a few seconds"
checks_failed; not_settled
echo '[{"databaseId":900,"attempt":2}]' > "$T/runs"
alarm
expect_status 0
expect_result false

for words in "pr view 7 --json headRefOid" "run list --workflow ci.yml"; do
  scenario "stops with a message, and answers nothing, when this fails: gh $words"
  checks_failed; not_settled
  GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" 7 >/dev/null 2>&1
  echo "$words" > "$T/fail"
  run env GH_TOKEN=workflow-token "$scripts/false-alarm.sh" 7 "$T/failed.txt"
  expect_status 1
  expect_output "so whether its checks have been run again is not known"
  expect_no_output true
  expect_no_output false
done

scenario "stops with a message when the file of failures is not there"
checks_failed
run env GH_TOKEN=workflow-token "$scripts/false-alarm.sh" 7 "$T/nowhere.txt"
expect_status 1
expect_output "so what failed on pull request #7 is not known"
