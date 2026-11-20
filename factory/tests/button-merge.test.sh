#!/usr/bin/env bash
# Tests for button-merge.sh: after the merge button it finishes shipping when main passes, or takes back what broke it.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

# The owner pressed GitHub's merge button on pull request #7, which the factory opened and which closes ticket #12.
# finish <main> <before>: how the test of main ended as the merge left it, and as it was before the merge.
finish() {
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/ \
    FAILED="${printed-FAILED factory/tests/ship.test.sh: expected exit 0}" "$scripts/button-merge.sh" finish 7 "$@"
}
tested() { run env GH_TOKEN=workflow-token "$scripts/button-merge.sh" tested 7; }
passed='{"verdict":"pass","findings":[],"assumptions":[]}'
failed='{"findings":[{"file":"a.sh","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}],"assumptions":[]}'
unreviewed="gh pr comment 7 --body Merged with GitHub's merge button before both reviews had passed. The button counts as the owner's approval, so it ships like any other."
expect_shipped() {
  expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
  expect_call "gh issue close 12"
  expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
  expect_call "gh issue edit 12 --add-label deployed"
  expect_no_call "gh pr merge"
}
expect_nothing_taken_back() {
  expect_no_call "gh issue create"
  expect_no_call "gh workflow run implement.yml -f issue=30"
}
# Nothing that follows a merge: the ticket keeps its labels, nothing waits for production and nothing is marked deployed.
expect_nothing_finished() {
  expect_no_call "gh issue edit"
  expect_no_call "gh issue close"
  expect_no_call "gh pr edit"
  expect_no_call "curl"
  expect_no_call "deployed"
}

scenario "main passes: the factory finishes shipping and takes nothing back"
ready_to_ship
verdict "Adam (architecture and taste)" "$passed"
verdict "Ryan (correctness)" "$passed"
finish success ""
expect_status 0
expect_shipped
expect_nothing_taken_back
expect_no_call "before both reviews had passed"

scenario "main passes and a reviewer had failed the pull request: the same, and one line says it merged without both reviews"
ready_to_ship
verdict "Adam (architecture and taste)" "$passed"
verdict "Ryan (correctness)" "$passed"
verdict "Ryan (correctness)" "$failed"
finish success ""
expect_status 0
expect_shipped
expect_nothing_taken_back
expect_calls 1 "$unreviewed"

scenario "a reviewer that failed it and then passed it has passed it: no line"
ready_to_ship
verdict "Adam (architecture and taste)" "$passed"
verdict "Ryan (correctness)" "$failed"
verdict "Ryan (correctness)" "$passed"
finish success ""
expect_status 0
expect_shipped
expect_no_call "before both reviews had passed"

scenario "a pull request merged before a reviewer gave any verdict gets the line too"
ready_to_ship
verdict "Adam (architecture and taste)" "$passed"
finish success ""
expect_status 0
expect_shipped
expect_calls 1 "$unreviewed"

scenario "the line is not said a second time when the run is started again"
ready_to_ship
comment "Merged with GitHub's merge button before both reviews had passed. The button counts."
finish success ""
expect_status 0
expect_shipped
expect_no_call "gh pr comment 7 --body Merged with GitHub's merge button before"

scenario "a verdict in another account's comment is none: the line is said though a stranger's comments pass it"
ready_to_ship
verdict "Adam (architecture and taste)" "$passed"
verdict "Ryan (correctness)" "$passed" stranger
verdict "Ryan (correctness)" "$passed" github-actions
finish success ""
expect_status 0
expect_shipped
expect_calls 1 "$unreviewed"

scenario "the line is said though another account's comment already holds it"
ready_to_ship
comment "Merged with GitHub's merge button before both reviews had passed. The button counts." stranger
finish success ""
expect_status 0
expect_shipped
expect_calls 1 "$unreviewed"

scenario "says so and fails, having finished nothing, when the pull request's comments cannot be read"
ready_to_ship
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
finish success ""
expect_status 1
expect_nothing_finished
expect_call "nothing that follows a merge was done: GitHub did not return this pull request's comments, so whether both reviews had passed is not known."

scenario "ships, then fails, when the line could not be posted"
ready_to_ship
echo "pr comment 7 --body Merged with GitHub's merge button before" > "$T/fail"
finish success ""
expect_status 1
expect_shipped
expect_output "Pull request #7 could not be told that it merged before both reviews had passed."

scenario "main fails and passed before the merge: one take-back starts, and nothing that follows a merge is done"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
finish failure success
expect_status 0
expect_calls 1 "gh issue create --title Take back the button merge of pull request #7 --label factory --label ready --body ## Change"
expect_call "FAILED factory/tests/ship.test.sh: expected exit 0"
expect_calls 1 "gh workflow run implement.yml -f issue=30"
expect_nothing_finished
expect_call "gh pr comment 7 --body Taken back, with nothing for a person to do: \`main\` failed once this pull request was merged with GitHub's merge button, having passed before the merge, and ticket #30 takes back pull request #7: its build was started, and Fred opens the pull request that reverts abcdef0. Nothing that follows a merge was done."
expect_no_call "--add-label needs-human"

scenario "a take-back already filed for the merge is not filed twice"
ready_to_ship
echo '[{"number":30,"title":"Take back the button merge of pull request #7","state":"open"}]' > "$T/tickets.json"
finish failure success
expect_status 0
expect_nothing_taken_back
expect_nothing_finished
expect_call "ticket #30 already takes back pull request #7; no second one was filed"

scenario "main already failed before the merge: nothing is taken back, shipping is finished and a person is asked"
ready_to_ship
finish failure failure
expect_status 0
expect_nothing_taken_back
expect_shipped
expect_first_line "gh pr comment 7 --body" "Read below what the test of \`main\` printed, and file a ticket for what fails: the factory builds it."
expect_call "it already failed before the merge, so this pull request is not what broke it and nothing was taken back."
expect_call "FAILED factory/tests/ship.test.sh: expected exit 0"
expect_call "gh issue edit 12 --add-label needs-human"

scenario "a pull request that closes no ticket is flagged itself when main already failed"
ready_to_ship
echo "A change with no ticket." > "$T/body"
finish failure failure
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"

scenario "fails when the person could not be asked about a main that already failed"
ready_to_ship
echo "issue edit 12 --add-label needs-human" > "$T/fail"
finish failure failure
expect_status 1
expect_shipped
expect_output "\`needs-human\` could not be added for pull request #7, though \`main\` fails."

scenario "a fence in what the test printed does not end the comment's own"
ready_to_ship
printed='before
```
after' finish failure failure
expect_status 0
expect_call "
\`\`\`
before

after
\`\`\`"

for results in " " "failure " "failure cancelled" "cancelled "; do
  scenario "a test of main that ended with no result (\"$results\") takes nothing back, finishes nothing, says so and fails"
  ready_to_ship
  # shellcheck disable=SC2086
  finish ${results% *} "${results#* }"
  expect_status 1
  expect_nothing_taken_back
  expect_nothing_finished
  expect_first_line "gh pr comment 7 --body" "Run the failed \`approve-merge\` run for this pull request again: \`main\` is tested and what follows a merge is done then."
  expect_call "nothing that follows a merge was done: the test of \`main\` ended with no result"
done

scenario "a person's own pull request is finished as before, whatever main does: only the factory's own are taken back"
ready_to_ship
echo repo-owner > "$T/author"
finish "" ""
expect_status 0
expect_shipped
expect_nothing_taken_back

scenario "a pull request the factory merged gets nothing a second time"
ready_to_ship
echo app/github-actions > "$T/merged-by"
finish failure success
expect_status 0
expect_output "the factory merged pull request #7, and did what follows a merge then; nothing to do"
expect_nothing_taken_back
expect_nothing_finished

scenario "a pull request that is not merged gets nothing"
ready_to_ship
echo CLOSED > "$T/state"
finish failure success
expect_status 0
expect_output "pull request #7 is not merged; nothing to do"
expect_nothing_taken_back

scenario "does nothing, says so and fails when GitHub does not return the pull request"
ready_to_ship
echo "pr view 7 --json state,author,mergedBy" > "$T/fail"
finish failure success
expect_status 1
expect_nothing_taken_back
expect_nothing_finished
expect_call "nothing that follows a merge was done: GitHub did not return this pull request, so whether the factory opened it is not known."

scenario "asks GitHub again for the pull request when it fails once"
ready_to_ship
echo "1 pr view 7 --json state,author,mergedBy" > "$T/flaky"
finish success ""
expect_status 0
expect_shipped

scenario "says so and fails, having finished nothing, when the take-back could not be started"
ready_to_ship
echo "issue create" > "$T/fail"
finish failure success
expect_status 1
expect_nothing_finished
expect_no_call "gh workflow run"
expect_first_line "gh pr comment 7 --body" "Run the failed \`approve-merge\` run for this pull request again: \`main\` is tested and what follows a merge is done then."
expect_call "the ticket that takes it back could not be filed or its build started."

scenario "fails when the pull request could not be told that it is being taken back"
ready_to_ship
echo "pr comment 7 --body Taken back" > "$T/fail"
finish failure success
expect_status 1
expect_calls 1 "gh issue create"
expect_output "Pull request #7 could not be told that it is being taken back."

scenario "says the pull request was tested when its checks passed with main as it was before the merge"
ready_to_ship
tested
expect_status 0
[ "$(grep -x 'tested=.*' <<<"$out")" = "tested=true" ] || fail "expected tested=true, alone on a line"
expect_call "gh api repos/{owner}/{repo}/commits/$merged --jq .parents[0].sha"

scenario "says it was not when its checks passed with an older main only"
ready_to_ship
tested_with_an_older_main
tested
expect_status 0
[ "$(grep -x 'tested=.*' <<<"$out")" = "tested=false" ] || fail "expected tested=false, alone on a line"
expect_output "did not pass with \`main\` as it was before the merge, aaaaaaa, so \`main\` is tested."

scenario "says it was not when the commit has no ci run"
ready_to_ship
rm "$T/runs/$head"
tested
expect_status 0
[ "$(grep -x 'tested=.*' <<<"$out")" = "tested=false" ] || fail "expected tested=false, alone on a line"

for words in "pr view 7 --json headRefOid,mergeCommit" "api repos/{owner}/{repo}/commits/$merged" "run list --workflow ci.yml --commit" "api repos/{owner}/{repo}/actions/runs/900/artifacts"; do
  scenario "has main tested, and says why, when GitHub does not answer: $words"
  ready_to_ship
  echo "$words" > "$T/fail"
  tested
  expect_status 0
  [ "$(grep -x 'tested=.*' <<<"$out")" = "tested=false" ] || fail "expected tested=false, alone on a line"
  expect_output "GitHub did not "
  expect_output "so \`main\` is tested."
done

# A change to either side must fail here: nothing else tests main or takes a merge back when a person presses the button.
scenario "approve-merge.yml tests main for the factory's own pull requests, with a token that only reads, and hands the result on"
workflow="$root/factory/workflows/approve-merge.yml"
job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflow"; }
test_main=$(job test-main); ship=$(job ship)
grep -qF "github.event_name == 'pull_request_target' && github.event.pull_request.merged == true &&" <<<"$test_main" \
  && grep -qF "github.event.pull_request.user.login == 'claude[bot]'" <<<"$test_main" \
  || fail "the test-main job does not run for a merged pull request the factory opened, and then alone"
[ "$(sed -n '/^    permissions:$/,/^    env:$/p' <<<"$test_main" | grep -cE '^      [a-z-]+: ')" = "$(sed -n '/^    permissions:$/,/^    env:$/p' <<<"$test_main" | grep -cE '^      [a-z-]+: read( |$)')" ] \
  || fail "the test-main job, which runs code no reviewer may have passed, holds a permission that is not read"
! grep -qF 'secrets.' <<<"$test_main" || fail "the test-main job is given a secret"
# shellcheck disable=SC2016
grep -qF 'ref: ${{ github.event.pull_request.merge_commit_sha }}' <<<"$test_main" || fail "the test-main job does not test main as the merge left it"
grep -qF 'TEST: pnpm install --frozen-lockfile && env -u GITHUB_WORKFLOW_REF pnpm lint && pnpm typecheck && pnpm test && pnpm build' <<<"$test_main" \
  || fail "the test-main job does not run every check a pull request must pass"
[ "$(grep -cF 'bash -c "$TEST"' <<<"$test_main")" = 2 ] || fail "the test-main job does not run the same test on main as the merge left it and as it was before"
grep -A4 -F 'id: before' <<<"$test_main" | grep -qF "if: steps.main.outcome == 'failure'" || fail "main as it was before the merge is not tested only when the merge fails"
# shellcheck disable=SC2016
grep -qF "main: \${{ steps.tested.outputs.tested == 'true' && 'success' || steps.main.outcome }}" <<<"$test_main" \
  || fail "a pull request that passed with main as it was before the merge does not count as a main that passes"
grep -qxF '    needs: test-main' <<<"$ship" || fail "the ship job does not wait for the test of main"
grep -qF '!cancelled() &&' <<<"$ship" || fail "the ship job would be skipped whenever test-main is, as for an approval"
# shellcheck disable=SC2016
grep -B11 -F 'run: factory/scripts/button-merge.sh finish "$PR" "$MAIN" "$BEFORE"' <<<"$ship" | grep -qF "if: github.event_name == 'pull_request_target'" \
  || fail "approve-merge.yml does not run button-merge.sh when a pull request is merged, and then alone"
# shellcheck disable=SC2016
for line in 'MAIN: ${{ needs.test-main.outputs.main }}' 'BEFORE: ${{ needs.test-main.outputs.before }}' 'FAILED: ${{ needs.test-main.outputs.failed }}'; do
  grep -qF "$line" <<<"$ship" || fail "the ship job is not given: $line"
done
