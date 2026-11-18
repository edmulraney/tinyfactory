#!/usr/bin/env bash
# Tests for factory/scripts/start-fix-round.sh: start a fix round, stop one out of rounds, or start the owner's round.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

round='{"id":2,"user":{"login":"github-actions[bot]"},"body":"<!-- factory:fix-round -->Fix round"}'

# used <n>: pull request #7 of fix-round-github.sh with n fix rounds counted on it.
used() {
  local n rounds=""
  for ((n = 0; n < $1; n++)); do rounds+="$round,"; done
  checks_failed
  echo "[${rounds}{\"id\":1,\"user\":{\"login\":\"repo-owner\"},\"body\":\"Looks good.\"}]" > "$T/comments.json"
}
start() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/start-fix-round.sh" 7; }

scenario "starts fix.yml with the pull request's number, and nothing else"
used 0
start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
[ "$out" = "a fix round was started for pull request #7" ] || fail "expected one sentence saying a fix round was started"
[ "$(grep -c '^gh workflow run' "$T/calls")" = 1 ] || fail "expected one workflow to be started"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"

scenario "starts nothing for a draft, whose engineer is still building it, and says so"
used 0
echo true > "$T/draft"
start
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"
expect_output "pull request #7 is a draft, which its engineer is still building: no fix round was started"

scenario "stops with a message, and starts nothing, when GitHub does not say whether it is a draft"
used 0
echo "pr view 7 --json isDraft" > "$T/fail"
start
expect_status 1
expect_no_call "gh workflow run"
expect_output "No fix round was started for pull request #7: GitHub did not say whether it is a draft."

scenario "starts a third round for a pull request that has used two"
used 2
start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_no_call "retro.yml"

scenario "starts nothing for a pull request that has used three rounds: says so, flags it and starts a retro"
used 3
start
expect_status 0
expect_no_call "fix.yml"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_call "gh pr comment 7 --body Three fix rounds have not got this pull request to green. Stopping here; it needs a human."
expect_call "gh workflow run retro.yml -f pr=7"
expect_output "pull request #7 has used its three fix rounds: no fix round was started"

scenario "three rounds used, and checks failed because the workflows on main had not settled: starts fix.yml, and does not stop it"
used 3; not_settled
start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_output "which no engineer can fix: fix.yml was started to run them again, and no fix round is used"
expect_no_call "needs-human"
expect_no_call "gh pr comment"
expect_no_call "retro.yml"

scenario "three rounds used: stops it when checks failed that way a second time, in a later attempt of the run"
used 3; not_settled
echo '[{"databaseId":900,"attempt":2}]' > "$T/runs"
start
expect_status 0
expect_no_call "fix.yml"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh workflow run retro.yml -f pr=7"

scenario "three rounds used, and checks failed only because the run is an install behind: neither stopped nor left waiting, a fresh run is asked for"
used 3; not_settled "$stale_run"
start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_output "fix.yml was started for the round that gets it a fresh run, and none of the three is used"
expect_no_call "needs-human"
expect_no_call "gh pr comment"
expect_no_call "retro.yml"

scenario "three rounds used, and both reviews ended with no verdict in a run whose ci.yml main no longer holds: a fresh run is asked for"
used 3; reviews_behind
start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_no_call "needs-human"
expect_no_call "retro.yml"

scenario "three rounds used: stops it when the run is an install behind again after its round for a fresh run"
used 3; not_settled "$stale_run"
echo "[$round,$round,$round,$(fresh_run_round)]" > "$T/comments.json"
start
expect_status 0
expect_no_call "fix.yml"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh workflow run retro.yml -f pr=7"

while IFS='|' read -r words message; do
  scenario "three rounds used, and the run an install behind: neither stops it nor starts anything when this fails: gh $words"
  used 3; not_settled "$stale_run"
  echo "$words" > "$T/fail"
  start
  expect_status 1
  expect_output "$message"
  expect_no_call "gh pr edit"
  expect_no_call "gh pr comment"
  case "$words" in "workflow run"*) ;; *) expect_no_call "gh workflow run" ;; esac
  [ -z "$(find "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the temporary directory"
done <<'CALLS'
api repos/{owner}/{repo}/contents|whether it needs only a fresh ci run is not known, so it was neither stopped nor given one.
workflow run fix.yml|Pull request #7 could not be given a fresh ci run: GitHub did not start fix.yml.
CALLS

while IFS='|' read -r words message; do
  scenario "three rounds used: neither stops it nor starts anything when this fails: gh $words"
  used 3; not_settled
  echo "$words" > "$T/fail"
  start
  expect_status 1
  expect_output "$message"
  expect_no_call "gh pr edit"
  expect_no_call "gh pr comment"
  case "$words" in "workflow run"*) ;; *) expect_no_call "gh workflow run" ;; esac
  [ -z "$(find "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the temporary directory"
done <<'CALLS'
api repos/owner/myapp/actions/runs/900/jobs|what failed on it could not be read, so it was neither stopped nor checked again.
pr view 7 --json headRefOid |whether an engineer can fix what failed is not known, so it was neither stopped nor checked again.
workflow run fix.yml|The checks of pull request #7 could not be run again: GitHub did not start fix.yml.
CALLS

scenario "stops with a message, and starts nothing, when the rounds cannot be counted: that is not a pull request with none"
used 3
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
start
expect_status 1
expect_output "No fix round was started for pull request #7: its fix rounds could not be counted."
expect_no_call "gh workflow run"
expect_no_call "gh pr comment"

scenario "stops with a message when fix.yml could not be started, and does not try again"
used 1
echo "workflow run fix.yml" > "$T/fail"
start
expect_status 1
expect_output "The fix round for pull request #7 could not be started"
expect_no_output "a fix round was started"
[ "$(grep -c '^gh workflow run fix.yml' "$T/calls")" = 1 ] || fail "expected the workflow to be started once, and not again"

for words in "pr edit 7" "issue edit 12" "pr comment 7" "workflow run retro.yml"; do
  scenario "three rounds used: stops with a message when this fails: gh $words"
  used 3
  echo "$words" > "$T/fail"
  start
  expect_status 1
  expect_output "Pull request #7 has used its three fix rounds"
  expect_no_output "no fix round was started, and it waits for a person"
  expect_no_call "fix.yml"
done

# As the send-back job of approve-merge.yml calls it.
owner_start() { run env GH_TOKEN=workflow-token "$scripts/start-fix-round.sh" 7 repo-owner; }
three_used() { checks_failed; echo "[$round,$round,$round]" > "$T/comments.json"; }

scenario "the owner's round: starts fix.yml for a pull request the owner sent back, though it has used three rounds"
three_used; sent_back
owner_start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
[ "$out" = "the owner's fix round was started for pull request #7" ] || fail "expected one sentence saying the owner's fix round was started"
expect_no_call "issues/7/comments"
expect_no_call "retro.yml"
expect_no_call "gh pr edit"
expect_no_call "gh pr comment"

scenario "the owner's round: starts nothing, and stops nothing, when the owner's review does not stand"
three_used
reviewed 41 repo-owner CHANGES_REQUESTED 6666666666666666666666666666666666666666
owner_start
expect_status 0
expect_output "no fix round was started for pull request #7: the latest verdict of repo-owner does not ask for changes to the commit that is there now"
expect_no_call "gh workflow run"
expect_no_call "gh pr edit"
expect_no_call "gh pr comment"

scenario "the owner's round: starts nothing for a draft the owner sent back, whose engineer is still building it"
three_used; sent_back
echo true > "$T/draft"
owner_start
expect_status 0
expect_output "pull request #7 is a draft, which its engineer is still building: no fix round was started"
expect_no_call "gh workflow run"
expect_no_call "pulls/7/reviews"

scenario "without the owner, a review that asks for changes does not get a pull request past its three rounds"
three_used; sent_back
start
expect_status 0
expect_no_call "fix.yml"
expect_call "gh workflow run retro.yml -f pr=7"

for words in "pr view 7 --json headRefOid" "api repos/{owner}/{repo}/pulls/7/reviews"; do
  scenario "the owner's round: stops with a message, and starts nothing, when this fails: gh $words"
  three_used; sent_back
  echo "$words" > "$T/fail"
  owner_start
  expect_status 1
  expect_output "No fix round was started for pull request #7: whether repo-owner sent it back could not be read."
  expect_no_call "gh workflow run"
done

scenario "the owner's round: stops with a message when fix.yml could not be started, and does not try again"
three_used; sent_back
echo "workflow run fix.yml" > "$T/fail"
owner_start
expect_status 1
expect_output "The fix round for pull request #7 could not be started"
expect_no_output "was started for pull request #7"
[ "$(grep -c '^gh workflow run fix.yml' "$T/calls")" = 1 ] || fail "expected the workflow to be started once, and not again"

scenario "starts no round for a pull request labelled waits-for-main, flags it so that it holds no place, and says the next merge tests it"
used 0; waits_for_main
start
expect_status 0
expect_no_call "gh workflow run"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh pr comment"
expect_no_call "gh issue edit"
expect_output "pull request #7 is labelled waits-for-main, as what failed lies outside it: no fix round was started, and the next merge tests it again"

scenario "a labelled pull request that has used its three rounds is not stopped: it waits for its retest"
used 3; waits_for_main
start
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "Three fix rounds"

scenario "fails, and says it still holds a place, when a labelled pull request could not be flagged"
used 0; waits_for_main
echo "pr edit 7 --add-label" > "$T/fail"
start
expect_status 1
expect_no_call "gh workflow run"
expect_output "Pull request #7 is labelled waits-for-main, and needs-human could not be added to it"

scenario "the owner's round is started for a labelled pull request the owner sent back"
used 0; waits_for_main; sent_back
owner_start
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"

scenario "leaves nothing behind"
used 0
start
used 3
start
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
