#!/usr/bin/env bash
# Tests for ship.sh: merges only what was tested with main as it is now, never twice, and never fails in silence.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

ship() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" 7 "$head"; }

scenario "ships: merges, tidies the labels, confirms the deploy and marks the ticket deployed"
ready_to_ship
ship
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_call "gh issue close 12"
expect_call "curl -fsS --max-time 10 https://myapp.example/api/health"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "gh workflow run"
expect_no_call "gh run rerun"

scenario "the place the merge freed goes to a ticket that waits with ready"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
ship
expect_status 0
expect_calls 1 "gh workflow run"
expect_call "gh workflow run implement.yml -f issue=20"
expect_output "started the build of issue #20, which waited with ready"
[ "$(grep -n '^gh workflow run implement.yml' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue edit 12 --remove-label in-progress' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the merged one gave up its place"

scenario "the merged ticket is closed and loses in-progress before the queue is read"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
ship
expect_status 0
read_at=$(grep -n -m 1 -F 'issues?state=open&labels=ready' "$T/calls" | cut -d: -f1)
[ "$(grep -n '^gh issue close 12' "$T/calls" | cut -d: -f1)" -lt "$read_at" ] || fail "expected ticket #12 to be closed before the queue was read"
[ "$(grep -n '^gh issue edit 12 --remove-label in-progress' "$T/calls" | cut -d: -f1)" -lt "$read_at" ] || fail "expected in-progress to come off ticket #12 before the queue was read"

scenario "a ticket that could not be closed is named on the pull request, and the waiting ticket is still started"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
echo "issue close 12" > "$T/fail"
ship
expect_status 1
expect_call "gh workflow run implement.yml -f issue=20"
expect_call "- ticket #12 could not be closed"

scenario "a waiting ticket that comes after the merged ticket is started, though GitHub still lists that ticket as open"
ready_to_ship
echo '[{"number":20,"body":"After #12\n"}]' > "$T/ready.json"
ship
expect_status 0
expect_call "gh workflow run implement.yml -f issue=20"
expect_no_call "gh issue comment 20"

scenario "a waiting ticket that cannot be started is said on the pull request, and the merge stands"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
echo "workflow run implement.yml" > "$T/fail"
ship
expect_status 1
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "the tickets that wait with \`ready\` were not all started"

scenario "merges exactly the commit that was checked, never a later push"
ready_to_ship
cp "$T/runs/$head" "$T/runs/1234567"
run env GH_TOKEN=workflow-token "$scripts/ship.sh" 7 1234567
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit 1234567"

scenario "ships a pull request that closes no ticket, and labels no ticket"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh pr comment 7 --body Deployed:"
expect_no_call "gh issue edit"

scenario "says on the ticket what it cost, in four lines, after everything else"
ready_to_ship
ship
expect_status 0
expect_call "gh issue comment 12 --body - **Claude usage:** \$1.50 at API prices, in 1 session on claude-fable-5-2"
expect_call "- **Actions minutes:** 4, in 1 run"
expect_call "- **Fix rounds:** 0"
expect_call "- **Ready to merged:** 30 min"
[ "$(tail -n 4 "$T/calls" | head -n 1 | cut -c1-20)" = "gh issue comment 12 " ] || fail "expected the cost comment to be the last call"

scenario "still ships, and passes, when what the ticket cost cannot be worked out: the log says so and no comment is posted"
ready_to_ship
echo "api repos/{owner}/{repo}/git/trees/sessions" > "$T/fail"
ship
expect_status 0
expect_call "gh issue edit 12 --add-label deployed"
expect_output "what ticket #12 cost could not be worked out, so it was not posted on it and its measures were not recorded"
expect_no_call "gh issue comment"
[ -z "$(recorded)" ] || fail "expected no line of measures"
expect_no_call "but not everything that follows a merge finished"

scenario "still passes when the cost cannot be posted on the ticket, and the log says so"
ready_to_ship
echo "issue comment 12" > "$T/fail"
ship
expect_status 0
expect_output "what ticket #12 cost could not be posted on it"
expect_no_call "but not everything that follows a merge finished"

scenario "a pull request that closes no ticket gets no cost comment and no line of measures"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_no_call "gh issue comment"
expect_no_call "git/trees"
[ -z "$(recorded)" ] || fail "expected no line of measures"

scenario "a merge appends one line of measures to the record on the sessions branch, before the cost comment"
ready_to_ship
echo '[{"number":15,"labels":[{"name":"proposal"}],"body":"Seen in pull request #7"}]' > "$T/issues.json"
ship
expect_status 0
[ "$(recorded | wc -l | tr -d ' ')" = 1 ] || fail "expected one line, found: $(recorded)"
[ "$(recorded | jq -c '[.pr, .issue, .cost_usd, .minutes, .fix_rounds, .seconds, .stops, .opened]')" = "[7,12,1.5,4,0,1800,0,[15]]" ] \
  || fail "expected the ticket's measures, found: $(recorded)"
expect_calls 1 "git/trees/sessions"
[ "$(tail -n 4 "$T/calls" | head -n 1 | cut -c1-20)" = "gh issue comment 12 " ] || fail "expected the cost comment to be the last call"

scenario "a line of measures that cannot be written is said, and does not stop the merge or the cost comment"
ready_to_ship
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/github/owner/myapp.git/hooks/pre-receive"
chmod +x "$T/github/owner/myapp.git/hooks/pre-receive"
ship
expect_status 0
expect_output "The measures of ticket #12 could not be written to measures.jsonl on the sessions branch, so no table will hold them."
expect_output "the measures of ticket #12 were not recorded"
[ -z "$(recorded)" ] || fail "expected no line of measures"
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh issue comment 12 --body - **Claude usage:**"
expect_no_call "but not everything that follows a merge finished"

scenario "stops before merging when the pull request cannot be read"
ready_to_ship
echo "pr view 7 --json body" > "$T/fail"
ship
expect_failure
expect_output "Could not read pull request #7"
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return this pull request's description"

scenario "tries a refused merge three times, then says on the pull request that it did not merge and why, and marks nothing deployed"
ready_to_ship
echo "pr merge 7" > "$T/fail"
ship
expect_failure
expect_calls 3 "gh pr merge 7"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub failed or refused the merge three times, and \`main\` holds no commit for this pull request. Its last answer was: gh: failed: pr merge 7"
expect_call "Approving this pull request again retries it."
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"
expect_no_call "curl"

scenario "still confirms the deploy when the labels could not be tidied, then fails and names them on the pull request"
ready_to_ship
printf 'pr edit 7\nissue edit 12 --remove-label\n' > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- the \`needs-human\` label could not be taken off this pull request"
expect_call "- the \`in-progress\` and \`needs-human\` labels could not be taken off ticket #12"

scenario "says merged, and that the deploy was not checked, when the merge commit cannot be read anywhere"
ready_to_ship
echo "pr view 7 --json mergeCommit" > "$T/fail"
ship
expect_failure
expect_calls 1 "gh pr merge 7"
expect_call "- GitHub did not return the merge commit, so the deploy was not checked"
expect_no_call "gh pr comment 7 --body Deployed"
expect_no_call "--add-label deployed"

scenario "takes the merge commit from main when the pull request does not give it"
ready_to_ship
echo "pr view 7 --json mergeCommit" > "$T/fail"
echo "$put_on_main" > "$T/merge"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."

scenario "starts a retro after a run that needed a fix round"
ready_to_ship
echo "[$round,{\"id\":3,\"user\":{\"login\":\"repo-owner\"},\"body\":\"Looks good.\"}]" > "$T/rounds"
ship
expect_status 0
expect_call "gh workflow run retro.yml -f pr=7"

scenario "starts a retro after a run the owner sent back, whose rounds are not among the three"
ready_to_ship
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:owner-round -->The owner's fix round: the engineer's session ran.\"}]" > "$T/rounds"
ship
expect_status 0
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "starts no retro after a clean run whose reviews only quote the fix-round marker"
ready_to_ship
jq -c '.user.login = "claude[bot]"' <<<"$round" > "$T/quoted"
echo "[{\"id\":3,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"**Ryan (correctness): PASS**\\nThe count reads <!-- factory:fix-round --> only at the start.\"},$(cat "$T/quoted")]" > "$T/rounds"
ship
expect_status 0
expect_no_call "gh workflow run retro.yml"

scenario "confirms the deploy and then fails, naming it, when the fix rounds cannot be counted: that is not a clean run"
ready_to_ship
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
ship
expect_failure
expect_output "Could not read the comments of pull request #7 from GitHub"
expect_no_call "gh workflow run retro.yml"
expect_call "gh pr comment 7 --body Deployed"
expect_call "- the fix rounds could not be counted, so no retro was started"

scenario "fails when the retro could not be started"
ready_to_ship
echo "[$round]" > "$T/rounds"
echo "workflow run retro.yml" > "$T/fail"
ship
expect_failure
expect_call "- the retro could not be started"

a_changed_workflow_waits() {
  echo '[{"number":40}]' > "$T/waiting.json"
  echo '[{"user":{"login":"github-actions[bot]"},"created_at":"2026-11-16T10:00:00Z","body":"Installed in abc1234\n\n<!-- factory:installed ci.yml -->"}]' > "$T/rounds-40"
}

scenario "after a merge, starts a retro for the first run of a workflow an earlier pull request changed"
ready_to_ship
a_changed_workflow_waits
echo '[{"id":901,"created_at":"2026-11-16T10:05:00Z","conclusion":"success","html_url":"https://github.example/runs/901"}]' > "$T/first-runs.json"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh workflow run retro.yml -f pr=40 -f run=901"
expect_call "gh pr comment 40 --body <!-- factory:first-run ci.yml -->"
expect_call "gh pr edit 40 --remove-label proof"
expect_no_call "a retro was not started"

scenario "confirms the deploy and then fails, saying so on the merged pull request, when the first runs could not be looked for"
ready_to_ship
a_changed_workflow_waits
echo "api --method GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs" > "$T/fail"
ship
expect_status 1
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed:"
expect_no_call "gh workflow run retro.yml"
expect_call "- a retro was not started for every first run of a changed workflow"

scenario "a merge with no changed workflow waiting for its first run asks once and is told nothing"
ready_to_ship
ship
expect_status 0
expect_calls 1 "gh pr list --state merged --label proof"
expect_no_call "a retro was not started"

scenario "starts the workflow installer after a merge that changed a workflow's source"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"},{"filename":"factory/decisions.md"}]' > "$T/files.json"
ship
expect_status 0
expect_call "gh workflow run install-workflows.yml -f pr=7"

scenario "does not start the installer for a file that only looks like a workflow's source"
ready_to_ship
echo '[{"filename":"docs/factory/workflows/ci.yml"},{"filename":".github/workflows/ci.yml"}]' > "$T/files.json"
ship
expect_status 0
expect_no_call "gh workflow run install-workflows.yml"

scenario "confirms the deploy and then fails when the installer could not be started"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
echo "workflow run install-workflows.yml" > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- the workflow installer could not be started, so the changed workflows are not installed"

scenario "confirms the deploy and then fails when the changed files could not be listed"
ready_to_ship
# Both listings fail, apply-setup.sh's and ship.sh's own: neither may read as "changed nothing".
# From the merge on: before it, ship.sh reads the list to see whether main overtook a workflow change.
echo 'printf "api repos/owner/myapp/pulls/7/files\napi repos/{owner}/{repo}/pulls/7/files\n" > "$T/fail"' > "$T/merge"
ship
expect_status 1
expect_no_output "nothing to apply"
expect_no_call "gh workflow run install-workflows.yml"
expect_call "gh pr comment 7 --body Deployed:"

scenario "fails when only its own listing of the changed files failed: that is not a merge that changed no workflow"
ready_to_ship
echo 'echo "api repos/{owner}/{repo}/pulls/7/files" > "$T/fail"' > "$T/merge"
ship
expect_status 1
expect_output "changed no setup script; nothing to apply"
expect_call "gh pr comment 7 --body Deployed:"

scenario "confirms the deploy and then fails when the setup changes could not be applied"
ready_to_ship
echo "repo view" > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- the changes to setup scripts, if there were any, could not be applied"

scenario "says the deploy was not confirmed when there is no production to ask"
ready_to_ship
run env GH_TOKEN=workflow-token "$scripts/ship.sh" 7 "$head"
expect_status 0
expect_output "merged as abcdef0; no PRODUCTION_URL is set, so the deploy was not confirmed"
expect_no_call "curl"
expect_no_call "--add-label deployed"
expect_no_call "gh pr comment"

scenario "after a merge and a failed deploy check, fails with one comment that says merged and names the deploy check, and marks nothing deployed"
ready_to_ship
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
ship
expect_status 1
expect_calls 1 "gh pr merge 7"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- the deploy check: production at https://myapp.example/ did not report that commit within 10 minutes. Check the Vercel deployment"
expect_no_call "Not merged"
expect_no_call "gh pr comment 7 --body Deployed"
expect_no_call "--add-label deployed"

scenario "fails and marks nothing deployed when production cannot be reached"
ready_to_ship
rm "$T/health"
ship
expect_status 1
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything"
expect_call "- the deploy check: production at https://myapp.example/ did not report"
expect_no_call "--add-label deployed"

scenario "passes when Vercel skipped the deployment of a merge that changes no app code, says nothing was deployed, and does not mark the ticket deployed"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"},{"filename":".claude/skills/implement/SKILL.md"}]' > "$T/files.json"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
ship
expect_status 0
expect_calls 1 "curl "
expect_call "gh pr comment 7 --body Merged as abcdef0. Nothing was deployed: this pull request changes no app code"
expect_no_call "not everything that follows a merge finished"
expect_no_call "--add-label deployed"

scenario "fails when Vercel skipped the deployment and the files the merge changes cannot be read"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
echo "api repos/owner/myapp/pulls/7/files" > "$T/fail"
ship
expect_status 1
expect_call "- the deploy check: Vercel skipped the deployment of this commit"
expect_no_call "Nothing was deployed"
expect_no_call "--add-label deployed"

scenario "fails when the merge changes no app code, Vercel skipped it, and the comment saying so cannot be posted"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
echo "pr comment 7 --body Merged as abcdef0. Nothing was deployed" > "$T/fail"
ship
expect_status 1
expect_output "the comment saying so could not be posted"
expect_no_call "--add-label deployed"

scenario "says at once that Vercel skipped the deployment of a merge that changes app code, and does not mark the ticket deployed"
ready_to_ship
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
ship
expect_status 1
expect_calls 1 "curl "
expect_call "gh api repos/{owner}/{repo}/commits/$merged/statuses"
expect_call "- the deploy check: Vercel skipped the deployment of this commit"
expect_no_call "did not report that commit within 10 minutes"
expect_no_call "--add-label deployed"

scenario "fails when the deploy was confirmed and the ticket could not be marked deployed"
ready_to_ship
echo "issue edit 12 --add-label deployed" > "$T/fail"
ship
expect_failure

scenario "fails when the deploy was confirmed and the comment could not be posted"
ready_to_ship
echo "pr comment 7" > "$T/fail"
ship
expect_failure
expect_call "gh issue edit 12 --add-label deployed"


scenario "refuses to merge on a result for an older main: runs fits-main again and says so"
ready_to_ship
tested_with_an_older_main
ship
expect_status 0
expect_call "gh run rerun --job 31"
expect_call "gh pr comment 7 --body <!-- factory:fits-main $main -->Not merged yet: \`main\` has moved to aaaaaaa"
expect_call "so fits-main is running again for pull request #7."
expect_no_call "gh pr merge"
expect_no_call "gh issue edit"
expect_no_call "curl"

scenario "refuses to merge when the ci run holds no record at all"
ready_to_ship
echo '{"artifacts":[]}' > "$T/artifacts/900"
ship
expect_status 0
expect_call "gh run rerun --job 31"
expect_no_call "gh pr merge"

scenario "merges on a record left by fits-main run again, beside the older one from the checks"
ready_to_ship
echo "{\"artifacts\":[{\"name\":\"tested-with-main-$older\"},{\"name\":\"tested-with-main-$main\"}]}" > "$T/artifacts/900"
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_no_call "gh run rerun"

scenario "does not take a record for a commit that only starts like main"
ready_to_ship
echo "{\"artifacts\":[{\"name\":\"tested-with-main-${main}b\"},{\"name\":\"not-tested-with-main-$main\"}]}" > "$T/artifacts/900"
ship
expect_call "gh run rerun --job 31"
expect_no_call "gh pr merge"

scenario "asked from the ci run that holds the result, hands the re-run to the workflow that waits for the run to end"
ready_to_ship
tested_with_an_older_main
echo '[{"databaseId":900,"status":"in_progress"}]' > "$T/runs/$head"
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" 7 "$head"
expect_status 0
expect_call "gh workflow run rerun-fits-main.yml -f pr=7"
expect_call "so fits-main will run again for pull request #7 as soon as this run has ended."
expect_no_call "gh run rerun"
expect_no_call "gh pr merge"

scenario "stops for a person, and asks no third time, when fits-main was already run again for this main and left no result"
ready_to_ship
tested_with_an_older_main
echo "{\"comments\":[{\"body\":\"<!-- factory:fits-main $main -->Not merged yet\"}]}" > "$T/comments"
ship
expect_failure
expect_call "gh pr comment 7 --body Not merged: \`fits-main\` was already run again"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh run rerun"
expect_no_call "gh pr merge"

scenario "runs fits-main again when it was asked for before, but for an older main than this one"
ready_to_ship
tested_with_an_older_main
echo "{\"comments\":[{\"body\":\"<!-- factory:fits-main $older -->Not merged yet\"}]}" > "$T/comments"
ship
expect_status 0
expect_call "gh run rerun --job 31"
expect_no_call "gh pr merge"

scenario "merges as before a pull request whose ci run began before fits-main was installed"
ready_to_ship
echo '{"artifacts":[]}' > "$T/artifacts/900"
echo '{"jobs":[{"id":30,"name":"checks"},{"id":32,"name":"merge"}]}' > "$T/jobs/900"
ship
expect_status 0
expect_output "began before fits-main was installed"
expect_call "gh pr merge 7 "
expect_no_call "gh run rerun"

scenario "does not merge when the latest ci run is another one, still waiting to start: no fits-main job there does not mean before the install"
ready_to_ship
echo '[{"databaseId":901,"status":"queued"}]' > "$T/runs/$head"
echo '{"artifacts":[]}' > "$T/artifacts/901"
echo '{"jobs":[]}' > "$T/jobs/901"
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" 7 "$head"
expect_status 0
expect_output "a newer ci run for 5555555 is still going"
expect_no_output "began before fits-main was installed"
expect_no_call "gh pr merge"
expect_no_call "gh run rerun"
expect_no_call "gh workflow run"
expect_call "gh pr comment 7 --body Not merged yet: a newer ci run for 5555555 is still going"

scenario "merges as before from the merge gate of a run that began before fits-main was installed, though that run has not ended"
ready_to_ship
echo '[{"databaseId":900,"status":"in_progress"}]' > "$T/runs/$head"
echo '{"artifacts":[]}' > "$T/artifacts/900"
echo '{"jobs":[{"id":30,"name":"checks"},{"id":32,"name":"merge"}]}' > "$T/jobs/900"
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" 7 "$head"
expect_status 0
expect_output "began before fits-main was installed"
expect_call "gh pr merge 7 "

scenario "merges on a record for main as it is now, though the run holding it has not ended"
ready_to_ship
echo '[{"databaseId":900,"status":"in_progress"}]' > "$T/runs/$head"
ship
expect_status 0
expect_call "gh pr merge 7 "

scenario "stops before merging when there is no ci run for the commit"
ready_to_ship
rm "$T/runs/$head"
ship
expect_failure
expect_output "there is no ci run for 5555555"
expect_no_call "gh pr merge"

# A failed read must stop the script, never read as "tested".
for words in "pr view 7 --json baseRefName" "api repos/{owner}/{repo}/commits/main" "run list --workflow ci.yml" \
  "api repos/{owner}/{repo}/actions/runs/900/artifacts"; do
  scenario "stops before merging when this fails: gh $words"
  ready_to_ship
  echo "$words" > "$T/fail"
  ship
  expect_failure
  expect_output "gh: failed: $words"
  expect_no_call "gh pr merge"
  expect_no_call "gh run rerun"
  expect_calls 6 "gh $words"
  expect_calls 1 "gh pr comment 7"
  expect_call "gh pr comment 7 --body Not merged: GitHub did not "
  expect_call "gh pr edit 7 --add-label needs-human"
done

# A failed read must not read as "run it again", "never asked before" or "began before fits-main was installed".
for words in "api repos/{owner}/{repo}/actions/runs/900/jobs" "pr view 7 --json comments"; do
  scenario "stops, merging nothing and running nothing again, when this fails: gh $words"
  ready_to_ship
  tested_with_an_older_main
  echo "$words" > "$T/fail"
  ship
  expect_failure
  expect_output "gh: failed: $words"
  expect_no_call "gh pr merge"
  expect_no_call "gh run rerun"
  expect_calls 1 "gh pr comment 7"
  expect_call "gh pr comment 7 --body Not merged: GitHub did not "
done

scenario "fails and says so on the pull request when fits-main could not be started again"
ready_to_ship
tested_with_an_older_main
echo "run rerun" > "$T/fail"
ship
expect_failure
expect_call "gh pr comment 7 --body Not merged: \`main\` has moved to aaaaaaa since this pull request was last tested with it, and \`fits-main\` could not be started again."
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "Not merged yet"
expect_no_call "gh pr merge"

scenario "fails when the re-run started and the pull request could not be told"
ready_to_ship
tested_with_an_older_main
echo "pr comment 7" > "$T/fail"
ship
expect_failure
expect_no_call "gh pr merge"


scenario "merges when each read fails twice and then answers"
ready_to_ship
printf '2 %s\n' "pr view 7 --json body" "pr view 7 --json baseRefName" "api repos/{owner}/{repo}/commits/main" \
  "run list --workflow ci.yml" "api repos/{owner}/{repo}/actions/runs/900/artifacts" \
  "api repos/{owner}/{repo}/commits?sha=main" "pr view 7 --json mergeCommit" > "$T/flaky"
ship
expect_status 0
expect_output "HTTP 502: Bad Gateway: pr view 7 --json baseRefName"
expect_calls 3 "gh pr view 7 --json baseRefName"
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_calls 1 "gh pr comment 7"

scenario "after a merge call that failed though GitHub made the commit, merges no second time, sets the labels and checks the deploy"
ready_to_ship
echo "$put_on_main; echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1" > "$T/merge"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_call "gh issue close 12"
expect_call "curl -fsS --max-time 10 https://myapp.example/api/health"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "gh pr view 7 --json mergeCommit"
expect_calls 1 "gh pr comment 7"

scenario "does not merge a pull request whose commit main already holds, when it is shipped again, and finishes what follows a merge"
ready_to_ship
on_main
ship
expect_status 0
expect_output "\`main\` already holds this pull request's commit, abcdef0; not merged a second time"
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"

scenario "leaves for a person a pull request GitHub still shows as open though main holds its commit"
ready_to_ship
on_main
echo OPEN > "$T/state"
ship
expect_status 1
expect_no_call "gh pr merge"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- GitHub does not show this pull request as merged, though \`main\` holds its commit. It was not merged a second time"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "merges on the second call when the first failed and left nothing on main"
ready_to_ship
echo 'if [ "$(grep -c "^gh pr merge" "$T/calls")" -eq 1 ]; then echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi' > "$T/merge"
ship
expect_status 0
expect_calls 2 "gh pr merge 7"
expect_calls 2 "gh api repos/{owner}/{repo}/commits?sha=main"
expect_call "gh issue edit 12 --add-label deployed"

scenario "does not call the merge again when main cannot be read after a merge call that failed"
ready_to_ship
echo 'echo "api repos/{owner}/{repo}/commits?sha=main" > "$T/fail"; echo "gh: HTTP 502: Bad Gateway" >&2; exit 1' > "$T/merge"
ship
expect_failure
expect_calls 1 "gh pr merge 7"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not list the commits on \`main\`, so whether this pull request is already merged there is not known"
expect_no_call "curl"

scenario "does not merge when main cannot be read before the merge"
ready_to_ship
echo "api repos/{owner}/{repo}/commits?sha=main" > "$T/fail"
ship
expect_failure
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"

scenario "ends with a failing exit and the reason in the log when GitHub takes no comment either"
ready_to_ship
printf '%s\n' "pr view 7 --json baseRefName" "pr comment 7" "pr edit 7" > "$T/fail"
ship
expect_failure
expect_output "Not merged: GitHub did not say which branch this pull request merges into"
expect_output "and the pull request could not be told so"
expect_no_call "gh pr merge"


scenario "after a merge, starts a fix round for each open factory pull request in conflict, and for no other"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 9 app/claude MERGEABLE
also_open 10 repo-owner CONFLICTING
also_open 11 app/claude CONFLICTING
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"
expect_no_call "gh workflow run fix.yml -f pr=9"
expect_no_call "gh workflow run fix.yml -f pr=10"
expect_calls 2 "gh workflow run"
expect_output "a fix round was started for pull request #8"
expect_no_call "gh run rerun"
expect_call "gh pr comment 7 --body Deployed:"

scenario "starts the fix round for a conflicting pull request without a ci run: its head, pushed in conflict, has none"
ready_to_ship
also_open 8 app/claude CONFLICTING
rm "$T/runs/$(cat "$T/heads/8")"
ship
expect_status 0
expect_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh run list --workflow ci.yml --commit 8888"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"

scenario "leaves a conflicting pull request that has used its three fix rounds, and still starts a fix round for one that has a round left"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "[$round,$round,$round,{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"Three fix rounds have not got this pull request to green.\"}]" > "$T/rounds-8"
echo "[$round,$round]" > "$T/rounds-11"
ship
expect_status 0
expect_output "pull request #8 conflicts with main, but has used its three fix rounds"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh pr comment 8"
expect_no_call "gh workflow run retro.yml"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "leaves a conflicting pull request a round for a conflict already ran for at its head, and starts one where that round was for an older head"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "[{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $(cat "$T/heads/8") -->The fix round for a conflict\"}]" > "$T/rounds-8"
echo "[{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $older -->The fix round for a conflict\"}]" > "$T/rounds-11"
ship
expect_status 0
expect_output "pull request #8 conflicts with main, but a fix round for a conflict already ran for its head 8888888"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh pr comment 8"
expect_no_call "gh workflow run retro.yml"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "confirms the deploy and then fails, starting nothing for it, when a conflicting pull request's fix rounds could not be read"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "api repos/{owner}/{repo}/issues/8/comments" > "$T/fail"
ship
expect_status 1
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "- a fix round was not started for every open pull request this merge left in conflict"

scenario "starts no fix round for a draft the merge left in conflict: its engineer is still building it"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo 8 > "$T/drafts"
ship
expect_status 0
expect_output "pull request #8 is a draft, which its engineer is still building: no fix round was started"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "starts nothing when the merge left no pull request in conflict"
ready_to_ship
also_open 8 app/claude MERGEABLE
ship
expect_status 0
expect_no_call "gh workflow run"

scenario "asks again while GitHub is still working out which pull requests conflict"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo 2 > "$T/unknown"
ship
expect_status 0
expect_call "gh workflow run fix.yml -f pr=8"

scenario "leaves a pull request GitHub never gave an answer for, says so, and asks only six times"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo 99 > "$T/unknown"
ship
expect_status 0
expect_output "GitHub has not said whether pull request #8 conflicts with main"
expect_no_call "gh workflow run"
[ "$(grep -c '^gh pr list --state open --base main' "$T/calls")" = 6 ] || fail "expected six askings, got $(grep -c '^gh pr list --state open --base main' "$T/calls")"

scenario "confirms the deploy and then fails when the open pull requests could not be listed"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo "pr list" > "$T/fail"
ship
expect_status 1
expect_no_call "gh workflow run"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"

scenario "confirms the deploy and then fails when the fix round could not be started for one, having still started it for the other"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "workflow run fix.yml -f pr=8" > "$T/fail"
ship
expect_status 1
expect_output "The fix round for pull request #8 could not be started"
expect_call "gh workflow run fix.yml -f pr=11"
expect_call "gh pr comment 7 --body Deployed:"

# Pull request #7 is the branch `second` of overtaking.sh, and changes the workflow source `first` changes.
changes_a_workflow() {
  ready_to_ship; two_branches
  echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
}
ship_second() {
  cp "$T/runs/$head" "$T/runs/$second"
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" 7 "$second"
}

scenario "refuses a workflow change main has overtaken, names the pull request that overtook it, and starts the round that merges main"
changes_a_workflow; merge_first
ship_second
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh workflow run install-workflows.yml"
expect_call "gh pr comment 7 --body Not merged: \`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6 after this pull request's diff of it was made. The installer would refuse the change once merged, and \`pnpm lint\` would fail on \`main\` for every pull request. Its engineer merges \`main\` into the branch first: a fix round was started for pull request #7. The new commit is then checked and merged like any other."
expect_calls 1 "gh workflow run"
expect_call "gh workflow run fix.yml -f pr=7"
expect_calls 1 "gh pr comment 7"
expect_no_call "needs-human"
expect_no_call "gh run list"
expect_no_call "gh run rerun"

scenario "ships the same pull request once main is merged into its branch"
changes_a_workflow; merge_first; merge_main_into_second
ship_second
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $second"
expect_call "gh workflow run install-workflows.yml -f pr=7"
expect_no_call "gh workflow run fix.yml"

scenario "ships a workflow change when main has changed only other files since"
changes_a_workflow
on_main_commit "feat: something else (#5)" "echo changed > apps/page.tsx; echo 'name: fix it' > factory/workflows/fix.yml"
ship_second
expect_status 0
expect_call "gh pr merge 7 "
expect_no_call "gh workflow run fix.yml"

scenario "an overtaken workflow change with no fix round left waits for a person, who is told how to merge main"
changes_a_workflow; merge_first
echo "[$round,$round,$round]" > "$T/rounds"
ship_second
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
expect_call "gh pr comment 7 --body Not merged: \`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6"
expect_call "This pull request gets no fix round to merge \`main\` into the branch, so a person does: \`git fetch origin main && git merge origin/main\`, then push. The new commit is then checked and merged like any other."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "an overtaken workflow change whose head already had its round for a conflict waits for a person"
changes_a_workflow; merge_first
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $second -->The fix round for a conflict\"}]" > "$T/rounds"
ship_second
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
expect_call "This pull request gets no fix round to merge \`main\` into the branch"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "an overtaken workflow change a person opened gets no fix round, and its author is told how to merge main"
changes_a_workflow; merge_first
echo repo-owner > "$T/author"
ship_second
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
expect_call "This pull request gets no fix round to merge \`main\` into the branch, so a person does: \`git fetch origin main && git merge origin/main\`"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "says so, and fails, when who opened an overtaken change cannot be read"
changes_a_workflow; merge_first
echo "pr view 7 --json author" > "$T/fail"
ship_second
expect_status 1
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
expect_call "GitHub did not say who opened this pull request, so no fix round was started to merge \`main\` into the branch. Approving this pull request again retries it."

scenario "a round for a conflict at an earlier head does not use up the round for this one"
changes_a_workflow; merge_first
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $older -->The fix round for a conflict\"}]" > "$T/rounds"
ship_second
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh workflow run fix.yml -f pr=7"

while IFS='|' read -r call; do
  scenario "does not merge a workflow change when whether main overtook it cannot be read: $call"
  changes_a_workflow; merge_first
  echo "$call" > "$T/fail"
  ship_second
  expect_status 1
  expect_no_call "gh pr merge"
  expect_no_call "gh workflow run"
  expect_call "gh pr comment 7 --body Not merged: GitHub did not say whether \`main\` has changed a workflow source this pull request changes, and the installer refuses such a change once it is merged. Approving this pull request again retries it."
  expect_call "gh pr edit 7 --add-label needs-human"
done <<'CALLS'
api repos/{owner}/{repo}/pulls/7/files
api repos/{owner}/{repo}/compare/
api --method GET repos/{owner}/{repo}/contents/factory/workflows
api --method GET repos/{owner}/{repo}/commits
CALLS

scenario "says so, and fails, when the round that merges main into an overtaken change cannot be started"
changes_a_workflow; merge_first
echo "workflow run fix.yml" > "$T/fail"
ship_second
expect_status 1
expect_no_call "gh pr merge"
expect_calls 1 "gh workflow run fix.yml"
expect_call "gh pr comment 7 --body Not merged: \`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6"
expect_call "The fix round that merges \`main\` into the branch could not be started. Approving this pull request again retries it."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "says so, and fails, when the fix rounds of an overtaken change cannot be counted"
changes_a_workflow; merge_first
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
ship_second
expect_status 1
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
expect_call "Its fix rounds could not be counted, so none was started to merge \`main\` into the branch. Approving this pull request again retries it."

scenario "a merged revert reopens the ticket it took back as reverted, before the wait for production"
ready_to_ship
echo "Take back pull request #5" > "$T/title"
ship
expect_status 0
expect_call "gh issue reopen 3"
expect_call "gh issue edit 3 --add-label reverted --remove-label deployed"
expect_call "gh issue comment 3 --body Taken back: pull request #7 reverted pull request #5"
[ "$(grep -n "^gh issue reopen 3" "$T/calls" | cut -d: -f1)" -lt "$(grep -n "^curl" "$T/calls" | head -n 1 | cut -d: -f1)" ] \
  || fail "expected the ticket to be reopened before production was asked"
expect_call "gh issue edit 12 --add-label deployed"

scenario "any other merge reopens no ticket"
ready_to_ship
ship
expect_status 0
expect_call "gh issue view 12 --json title"
expect_no_call "gh issue reopen"

scenario "a pull request that closes no ticket is not asked whether it took one back"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_no_call "gh issue view"

scenario "a merged revert whose ticket cannot be reopened still ships, says so and fails"
ready_to_ship
echo "Take back pull request #5" > "$T/title"
echo "issue reopen 3" > "$T/fail"
ship
expect_status 1
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- if this pull request took a ticket back, that ticket was not reopened as \`reverted\` (\`revert.sh\` failed)"
expect_output "Ticket #3 could not be reopened."

# waits <number> <who opened it> [draft]: an open pull request labelled waits-for-main, and flagged as one is.
waits() {
  jq --argjson n "$1" --arg login "$2" --argjson draft "${3:-false}" \
    '. + [{number: $n, author: {login: $login}, isDraft: $draft, labels: [{name: "needs-human"}, {name: "waits-for-main"}]}]' \
    <(cat "$T/marked.json" 2>/dev/null || echo "[]") > "$T/marked.new"
  mv "$T/marked.new" "$T/marked.json"
}

scenario "after a merge, starts the fix round that tests a pull request labelled waits-for-main again, and touches no other"
ready_to_ship
waits 8 app/claude
also_open 9 app/claude MERGEABLE
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh workflow run fix.yml -f pr=8"
expect_calls 1 "gh workflow run"
expect_output "started the fix round that tests pull request #8 with main again"
expect_no_call "gh pr edit 9"
expect_no_call "gh pr comment 9"
[ "$(grep -n '^gh workflow run fix.yml -f pr=8' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh pr merge 7' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the round to be started after the merge"

scenario "a labelled pull request the merge left in conflict gets one round, its retest, and not a second for the conflict"
ready_to_ship
waits 8 app/claude
also_open 8 app/claude CONFLICTING
ship
expect_status 0
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_output "pull request #8 is labelled waits-for-main, as what failed lies outside it: no fix round was started, and the next merge tests it again"

scenario "ships and then fails, saying so on the pull request, when the labelled pull requests could not be listed"
ready_to_ship
echo "pr list --state open --limit 100 --json number,author,labels,isDraft" > "$T/fail"
ship
expect_status 1
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- not every pull request labelled \`waits-for-main\` is tested again (\`start-retests.sh\` failed); the next merge tests it"

