#!/usr/bin/env bash
# Tests for needs-fresh-run.sh: whether only a ci.yml behind main failed, its one round unused (decisions A142a, A142b).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

fresh() {
  GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" 7 >/dev/null 2>&1
  : > "$T/calls"
  run env GH_TOKEN=workflow-token "$scripts/needs-fresh-run.sh" 7 "$T/failed.txt"
}
expect_result() { [ "$out" = "$1" ] || fail "expected it to print $1 and nothing else"; }

scenario "the sentence it looks for is one check-inventory.sh and workflow-behind.sh both print"
sentence="this run uses the workflow from before the install"
for script in check-inventory.sh workflow-behind.sh; do
  grep -qF -- "$sentence" "$scripts/$script" || fail "$script no longer prints: $sentence"
done
grep -qF -- "\"$sentence\"" "$scripts/needs-fresh-run.sh" || fail "needs-fresh-run.sh does not look for: $sentence"
[[ "$stale_run" == *"$sentence"* ]] && [[ "$review_behind" == *"$sentence"* ]] || fail "the logs these tests use do not hold the sentence"

scenario "true, with the ci.yml main holds, when only checks failed, saying the run is an install behind"
checks_failed; not_settled "$stale_run"
fresh
expect_status 0
expect_result "true $ci_yml"

scenario "true when a ci run whose ci.yml differs from main's at review time left both reviews with no verdict"
checks_failed; reviews_behind
fresh
expect_status 0
expect_result "true $ci_yml"

scenario "false when the review job failed and does not say the run is behind"
checks_failed; reviews_behind
echo "Ryan (correctness): review not finished." > "$T/log-33"
fresh
expect_result false

scenario "true when the run's ci.yml still has a job main's no longer has, and each failed job says the run is behind"
checks_failed; reviews_behind
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":33,"name":"review","conclusion":"failure"},{"id":34,"name":"verdicts","conclusion":"failure"}]}' > "$T/jobs"
echo "not reviewed. $review_behind" > "$T/log-34"
fresh
expect_result "true $ci_yml"

scenario "false when one of two failed jobs does not say the run is behind"
checks_failed; reviews_behind
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":33,"name":"review","conclusion":"failure"},{"id":34,"name":"verdicts","conclusion":"failure"}]}' > "$T/jobs"
echo "Usage: review.sh" > "$T/log-34"
fresh
expect_result false

scenario "false once a round for a fresh run has run while main held this ci.yml: the same sentence again is no install"
checks_failed; not_settled "$stale_run"
echo "[$(fresh_run_round)]" > "$T/comments.json"
fresh
expect_status 0
expect_result false

scenario "true again when main holds another ci.yml than the one a round ran for"
checks_failed; not_settled "$stale_run"
echo "[$(fresh_run_round dddddddddddddddddddddddddddddddddddddddd)]" > "$T/comments.json"
fresh
expect_result "true $ci_yml"

scenario "a marker somebody else wrote, or one only quoted, is no round"
checks_failed; not_settled "$stale_run"
echo "[{\"id\":3,\"user\":{\"login\":\"repo-owner\"},\"body\":\"<!-- factory:fresh-run-round $ci_yml -->\"},{\"id\":4,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"Quoted: <!-- factory:fresh-run-round $ci_yml -->\"}]" > "$T/comments.json"
fresh
expect_result "true $ci_yml"

scenario "false for any other failure of checks, without asking GitHub anything"
checks_failed
fresh
expect_status 0
expect_result false
[ ! -s "$T/calls" ] || fail "expected no call to GitHub"

scenario "false for the sentences of a main whose workflows had not settled: checks is run again for those"
checks_failed; not_settled
fresh
expect_result false

scenario "false when another job failed as well: that one is an engineer's to fix"
checks_failed; not_settled "$stale_run"
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"failure"},{"id":31,"name":"e2e","conclusion":"failure"}]}' > "$T/jobs"
fresh
expect_result false

scenario "false when the pull request is in conflict as well"
checks_failed; not_settled "$stale_run"; in_conflict
fresh
expect_result false

scenario "false when the owner sent the pull request back: that round is the owner's"
checks_failed; not_settled "$stale_run"; sent_back
GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" 7 >/dev/null 2>&1
GH_TOKEN=workflow-token "$scripts/owner-review.sh" 7 repo-owner "$T/failed.txt" >/dev/null 2>&1
run env GH_TOKEN=workflow-token "$scripts/needs-fresh-run.sh" 7 "$T/failed.txt"
expect_result false

scenario "false when nothing failed"
checks_failed; nothing_failed
fresh
expect_result false

while IFS='|' read -r words message; do
  scenario "stops with a message, and answers nothing, when this fails: gh $words"
  checks_failed; not_settled "$stale_run"
  GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" 7 >/dev/null 2>&1
  echo "$words" > "$T/fail"
  run env GH_TOKEN=workflow-token "$scripts/needs-fresh-run.sh" 7 "$T/failed.txt"
  expect_status 1
  expect_output "$message"
  expect_no_output true
  expect_no_output false
done <<'CALLS'
api repos/{owner}/{repo}/contents|Could not read the ci.yml main holds from GitHub
api repos/{owner}/{repo}/issues/7/comments|The fix rounds for a fresh run of pull request #7 could not be counted
CALLS

scenario "stops with a message when GitHub gives no id for main's ci.yml"
checks_failed; not_settled "$stale_run"
echo "" > "$T/ci-yml"
fresh
expect_status 1
expect_output "GitHub gave no id for the ci.yml main holds"
expect_no_output true

scenario "stops with a message when the file of failures is not there"
checks_failed
run env GH_TOKEN=workflow-token "$scripts/needs-fresh-run.sh" 7 "$T/nowhere.txt"
expect_status 1
expect_output "so what failed on pull request #7 is not known"
