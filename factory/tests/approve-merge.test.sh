#!/usr/bin/env bash
# Tests for factory/scripts/approve-merge.sh: ship a pull request the owner approved once its checks passed.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

approve() { run env GH_TOKEN=workflow-token PRODUCTION_URL=https://myapp.example/ "$scripts/approve-merge.sh" 7 repo-owner; }
# The owner's review, and any before it: <state> <commit> pairs, oldest first.
reviews() {
  local list="[]"
  while [ $# -gt 0 ]; do
    list=$(jq --arg login "$1" --arg state "$2" --arg oid "$3" '. + [{author: {login: $login}, state: $state, commit: {oid: $oid}}]' <<<"$list")
    shift 3
  done
  jq --argjson reviews "$list" '.reviews = $reviews' "$T/view.json" > "$T/view.new"
  mv "$T/view.new" "$T/view.json"
}

scenario "ships a pull request the owner approved, with the commit they approved"
ready_to_ship
approve
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_call "gh issue edit 12 --add-label deployed"

scenario "does nothing, in silence, for a pull request that is not open"
ready_to_ship
jq '.state = "MERGED"' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
approve
expect_status 0
expect_output "pull request #7 is not open; nothing to do"
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"

scenario "does nothing, in silence, when the owner approved an older commit"
ready_to_ship
reviews repo-owner APPROVED "$older"
approve
expect_status 0
expect_output "the owner has not approved commit 5555555; nothing to do"
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"

scenario "does nothing when the owner's latest review is not the approval"
ready_to_ship
reviews repo-owner APPROVED "$head" repo-owner CHANGES_REQUESTED "$head"
approve
expect_status 0
expect_no_call "gh pr merge"

scenario "does nothing when only someone else approved"
ready_to_ship
reviews someone-else APPROVED "$head"
approve
expect_status 0
expect_no_call "gh pr merge"

scenario "does nothing when nobody has reviewed"
ready_to_ship
reviews
approve
expect_status 0
expect_no_call "gh pr merge"

scenario "ships when reading the pull request fails twice and then answers"
ready_to_ship
printf '2 %s\n' "pr view 7 --json state,headRefOid,reviews" "run list --workflow ci.yml" > "$T/flaky"
approve
expect_status 0
expect_calls 3 "gh pr view 7 --json state,headRefOid,reviews"
expect_calls 1 "gh pr merge 7"

for words in "pr view 7 --json state,headRefOid,reviews" "run list --workflow ci.yml"; do
  scenario "fails with one comment naming the reason when GitHub never answers: gh $words"
  ready_to_ship
  echo "$words" > "$T/fail"
  approve
  expect_failure
  expect_no_call "gh pr merge"
  expect_calls 1 "gh pr comment 7"
  expect_call "gh pr comment 7 --body Not merged: GitHub did not return "
  expect_call "Approving this pull request again retries it."
  expect_call "gh pr edit 7 --add-label needs-human"
done

# Each refusal for checks that have not passed ends green, so no retro starts (decisions M78).
scenario "says so and does not merge when the checks failed, naming the jobs"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo '{"jobs":[{"name":"checks","conclusion":"failure"},{"name":"e2e","conclusion":"skipped"},{"name":"adam","conclusion":"cancelled"},{"name":"merge","conclusion":"skipped"}]}' > "$T/jobs/900"
approve
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: the checks for 5555555 have not passed (ci failed: checks, adam). Approving this pull request again retries it."

scenario "says so and does not merge while the checks are still running"
ready_to_ship
echo '[{"databaseId":900,"status":"in_progress","conclusion":""}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: the checks for 5555555 have not passed (ci: none has finished)."
expect_call "gh pr edit 7 --add-label needs-human"

for words in "pr comment 7" "pr edit 7 --add-label needs-human"; do
  scenario "fails when the checks have not passed and the owner could not be told: gh $words"
  ready_to_ship
  echo '[{"databaseId":900,"status":"in_progress","conclusion":""}]' > "$T/runs/$head"
  echo "$words" > "$T/fail"
  approve
  expect_failure
  expect_no_call "gh pr merge"
done

scenario "says so and does not merge when the checks were cancelled, or never ran"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"cancelled"}]' > "$T/runs/$head"
approve
expect_status 0
expect_call "have not passed (ci: cancelled)"
rm "$T/runs/$head"
approve
expect_status 0
expect_call "have not passed (ci: none has finished)"
expect_no_call "gh pr merge"

# A push that is also marked ready starts two runs, and the later one can be all skipped (decisions M205).
scenario "ships when a passed ci run has a later, skipped one for the same commit"
ready_to_ship
echo '[{"databaseId":901,"status":"completed","conclusion":"skipped"},{"databaseId":900,"status":"completed","conclusion":"success"}]' > "$T/runs/$head"
approve
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_call "gh api repos/{owner}/{repo}/actions/runs/900/artifacts"
expect_no_call "runs/901"

scenario "says so and does not merge when the only ci run for the commit was skipped"
ready_to_ship
echo '[{"databaseId":901,"status":"completed","conclusion":"skipped"}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: the checks for 5555555 have not passed (ci: none has finished)."

scenario "retries the merge when the ci run failed only because its merge did"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":31,"name":"fits-main","conclusion":"skipped"},{"id":32,"name":"merge","conclusion":"failure"}]}' > "$T/jobs/900"
approve
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh issue edit 12 --add-label deployed"

scenario "does not merge when the ci run failed and no job says why"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh pr merge"
expect_call "have not passed (ci failed)"

scenario "does not merge when the jobs of a failed ci run cannot be read"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo "api repos/{owner}/{repo}/actions/runs/900/jobs" > "$T/fail"
approve
expect_failure
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return the jobs of the checks"

scenario "passes on what ship.sh says when it does not merge"
ready_to_ship
echo "pr merge 7" > "$T/fail"
approve
expect_failure
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub failed or refused the merge three times"
