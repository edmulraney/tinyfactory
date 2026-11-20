#!/usr/bin/env bash
# Tests for approve-merge.sh: a pull request the owner approved waits to merge once its checks passed.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

approve() { run env GH_TOKEN=workflow-token "$scripts/approve-merge.sh" 7 repo-owner; }
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

scenario "adds to those that wait to merge a pull request the owner approved, with the commit they approved"
ready_to_ship
approve
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->This pull request waits to merge at 5555555."
expect_call "gh workflow run merge-group.yml"

scenario "does nothing, in silence, for a pull request that is not open"
ready_to_ship
jq '.state = "MERGED"' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
approve
expect_status 0
expect_output "pull request #7 is not open; nothing to do"
expect_no_call "gh workflow run merge-group.yml"
expect_no_call "gh pr comment"

scenario "does nothing, in silence, when the owner approved an older commit"
ready_to_ship
reviews repo-owner APPROVED "$older"
approve
expect_status 0
expect_output "the owner has not approved commit 5555555; nothing to do"
expect_no_call "gh workflow run merge-group.yml"
expect_no_call "gh pr comment"

scenario "does nothing when the owner's latest review is not the approval"
ready_to_ship
reviews repo-owner APPROVED "$head" repo-owner CHANGES_REQUESTED "$head"
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"

scenario "does nothing when only someone else approved"
ready_to_ship
reviews someone-else APPROVED "$head"
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"

scenario "does nothing when nobody has reviewed"
ready_to_ship
reviews
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"

scenario "adds to those that wait to merge when reading the pull request fails twice and then answers"
ready_to_ship
printf '2 %s\n' "pr view 7 --json state,headRefOid,reviews" "run list --workflow ci.yml" > "$T/flaky"
approve
expect_status 0
expect_calls 3 "gh pr view 7 --json state,headRefOid,reviews"
expect_calls 1 "gh workflow run merge-group.yml"

for words in "pr view 7 --json state,headRefOid,reviews" "run list --workflow ci.yml"; do
  scenario "fails with one comment naming the reason when GitHub never answers: gh $words"
  ready_to_ship
  echo "$words" > "$T/fail"
  approve
  expect_failure
  expect_no_call "gh workflow run merge-group.yml"
  expect_calls 1 "gh pr comment 7"
  expect_call "Not merged: GitHub did not return "
  expect_first_line "gh pr comment 7 --body" "Approve this pull request again: the merge is tried again then."
  expect_call "gh pr edit 7 --add-label needs-human"
done

# Each refusal for checks that have not passed ends green, so no retro starts (decisions M78).
scenario "says so and does not merge when the checks failed, naming the jobs"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo '{"jobs":[{"name":"checks","conclusion":"failure"},{"name":"e2e","conclusion":"skipped"},{"name":"review","conclusion":"cancelled"},{"name":"merge","conclusion":"skipped"}]}' > "$T/jobs/900"
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: the checks for 5555555 have not passed (ci failed: checks, review)."

scenario "says so and does not merge while the checks are still running"
ready_to_ship
echo '[{"databaseId":900,"status":"in_progress","conclusion":""}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: the checks for 5555555 have not passed (ci: none has finished)."
expect_call "gh pr edit 7 --add-label needs-human"

for words in "pr comment 7" "pr edit 7 --add-label needs-human"; do
  scenario "fails when the checks have not passed and the owner could not be told: gh $words"
  ready_to_ship
  echo '[{"databaseId":900,"status":"in_progress","conclusion":""}]' > "$T/runs/$head"
  echo "$words" > "$T/fail"
  approve
  expect_failure
  expect_no_call "gh workflow run merge-group.yml"
done

scenario "says so and does not merge when the checks were cancelled"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"cancelled"}]' > "$T/runs/$head"
approve
expect_status 0
expect_call "have not passed (ci: cancelled)"
expect_no_call "gh workflow run"

# A push that is also marked ready starts two runs, and the later one can be all skipped (decisions M205).
scenario "adds to those that wait to merge when a passed ci run has a later, skipped one for the same commit"
ready_to_ship
echo '[{"databaseId":901,"status":"completed","conclusion":"skipped"},{"databaseId":900,"status":"completed","conclusion":"success"}]' > "$T/runs/$head"
approve
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->This pull request waits to merge at 5555555."
expect_no_call "runs/901"

# started <commit> [login]: the comment that records that the checks of the commit were started, the factory's unless a login is given.
started() {
  jq --arg body "<!-- factory:checks-started $1 -->Nothing to do" --arg login "${2:-github-actions[bot]}" \
    '. + [{id: 5, user: {login: $login}, body: $body}]' "$T/rounds" > "$T/rounds.new"
  mv "$T/rounds.new" "$T/rounds"
}
only_skipped() { echo '[{"databaseId":901,"status":"completed","conclusion":"skipped"}]' > "$T/runs/$head"; }

scenario "starts the checks of a commit whose only ci run was skipped, says so, and asks for no second approval"
ready_to_ship; only_skipped
approve
expect_status 0
expect_calls 1 "gh workflow run fix.yml -f pr=7"
expect_first_line "gh pr comment 7 --body <!-- factory:checks-started $head -->Nothing to do: the factory is starting the checks for 5555555, and this pull request merges when they pass, with the approval it" "has."
expect_calls 1 "gh pr comment 7"
expect_no_call "Approve this pull request again"
expect_no_call "needs-human"
expect_no_call "gh workflow run merge-group.yml"

scenario "a second call for the same commit starts nothing more, and says what a person must do and what stopped the factory"
ready_to_ship; only_skipped; started "$head"
approve
expect_status 0
expect_no_call "gh workflow run"
expect_first_line "gh pr comment 7 --body" "Convert this pull request to a draft, then mark it ready for review: that starts its checks, and it merges when they pass."
expect_call "Not merged: no ci run of 5555555 ran its jobs, and the fix round the factory started for that commit left it so."
expect_no_call "Approve this pull request again"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "starts the checks of a commit that has no ci run at all"
ready_to_ship
rm "$T/runs/$head"
approve
expect_status 0
expect_calls 1 "gh workflow run fix.yml -f pr=7"
expect_no_call "Approve this pull request again"

scenario "starts the checks of a commit though they were started for an earlier one, or a person quotes the record"
ready_to_ship; only_skipped; started "$older"; started "$head" repo-owner
approve
expect_status 0
expect_calls 1 "gh workflow run fix.yml -f pr=7"

scenario "starts no checks for a draft, which its engineer is still building: says they have not passed"
ready_to_ship; only_skipped
jq '.isDraft = true' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
approve
expect_status 0
expect_no_call "gh workflow run"
expect_call "Not merged: the checks for 5555555 have not passed (ci: none has finished)."

scenario "starts no checks for a pull request the factory did not open, which gets no fix round: says they have not passed"
ready_to_ship; only_skipped
jq '.author.login = "repo-owner"' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
approve
expect_status 0
expect_no_call "gh workflow run"
expect_call "Not merged: the checks for 5555555 have not passed (ci: none has finished)."

scenario "starts no checks while a ci run of the commit is still running"
ready_to_ship
echo '[{"databaseId":900,"status":"in_progress","conclusion":""}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh workflow run"

scenario "fails, and starts nothing, when the comments that say whether the checks were started cannot be read"
ready_to_ship; only_skipped
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
approve
expect_failure
expect_no_call "gh workflow run"
expect_call "Not merged: GitHub did not return this pull request's comments, so whether the checks for 5555555 were started before is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "fails, and starts nothing, when the pull request cannot be told that the checks are being started"
ready_to_ship; only_skipped
echo "pr comment 7" > "$T/fail"
approve
expect_failure
expect_no_call "gh workflow run"
expect_output "GitHub did not take the comment that says the checks for 5555555 are being started, so they were not started"

scenario "fails, asked once, and says how to start the fix round and what stopped it, when fix.yml cannot be started"
ready_to_ship; only_skipped
echo "workflow run fix.yml" > "$T/fail"
approve
expect_failure
[ "$(grep -c '^gh workflow run fix.yml' "$T/calls")" = 1 ] || fail "expected fix.yml to be asked for once"
expect_first_line "gh pr comment 7 --body" "Start the fix round: \`gh workflow run fix.yml -f pr=7\`. It starts the checks, and this pull request merges when they pass."
expect_call "Not merged: no ci run of 5555555 ran its jobs, and GitHub did not start \`fix.yml\`, the fix round that starts them."
expect_call "gh pr edit 7 --add-label needs-human"

for words in "pr comment 7" "pr edit 7 --add-label needs-human"; do
  scenario "fails when the checks were started once already and the owner could not be told: gh $words"
  ready_to_ship; only_skipped; started "$head"
  echo "$words" > "$T/fail"
  approve
  expect_failure
  expect_no_call "gh workflow run"
done

scenario "retries the merge when the ci run failed only because its merge did"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":32,"name":"merge","conclusion":"failure"}]}' > "$T/jobs/900"
approve
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"
expect_call "gh workflow run merge-group.yml"

scenario "does not merge when the ci run failed and no job says why"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
approve
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "have not passed (ci failed)"

scenario "does not merge when the jobs of a failed ci run cannot be read"
ready_to_ship
echo '[{"databaseId":900,"status":"completed","conclusion":"failure"}]' > "$T/runs/$head"
echo "api repos/{owner}/{repo}/actions/runs/900/jobs" > "$T/fail"
approve
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_calls 1 "gh pr comment 7"
expect_call "Not merged: GitHub did not return the jobs of the checks"

scenario "asks six times, then fails and asks a person to start the workflow, when merge-group.yml cannot be started: the pull request keeps its place"
ready_to_ship
echo "workflow run merge-group.yml" > "$T/fail"
approve
expect_failure
expect_first_line "gh pr comment 7 --body Start the \`merge-group\` workflow from the Actions tab: this pull request waits to merge, and that run tests and merges" "it."
expect_calls 6 "gh workflow run merge-group.yml"
expect_no_call "Approve this pull request again"
expect_call "gh pr edit 7 --add-label needs-human"
