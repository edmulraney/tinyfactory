#!/usr/bin/env bash
# Tests for begin-fix-round.sh: whether a fix round goes ahead, and for whom; only gh and sleep are stand-ins.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"
. "$(dirname "$0")/sessions-remote.sh"

round='{"id":2,"user":{"login":"github-actions[bot]"},"body":"<!-- factory:fix-round -->Fix round"}'

begin() {
  : > "$T/outputs"
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_OUTPUT="$T/outputs" "$scripts/begin-fix-round.sh" "${1:-7}" "$T/failed.txt" repo-owner
}
expect_written() { grep -qxF -- "$1" "$T/outputs" || fail "expected it to write: $1"; }
expect_no_round() {
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_no_call "gh pr comment"
}

expect_stopped() {
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_call "gh pr edit 7 --add-label needs-human"
  expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
  expect_call "Three fix rounds have not got this pull request to green, and no fourth starts by itself."
  expect_call "gh workflow run retro.yml -f pr=7"
  expect_no_call "is addressing what failed"
}

scenario "goes ahead for an open pull request the factory opened, with a round left and a failed check"
checks_failed
begin
expect_status 0
expect_written "go=true"
expect_written "round=1"
expect_written "counted=true"
expect_written "branch=feat/12-export-forecast-csv"
expect_written "head=$head"
grep -qF "src/page.tsx: unused variable" "$T/failed.txt" || fail "expected what failed to be in the file the engineer is given"

scenario "whoever built it fixes it: Fred for a factory ticket"
checks_failed
begin
expect_written "name=Fred"
expect_written "role=fred-fix"
expect_written "skill=.claude/skills/factory-engineer/SKILL.md"
expect_call "gh pr comment 7 --body Fix round 1 of 3: Fred is addressing what failed."
expect_written "tools=Read,Write,Edit,Glob,Grep,Bash"

scenario "Rosa for a research ticket, with the web to read and only her own commands to run"
checks_failed
echo '{"labels":[{"name":"research"},{"name":"in-progress"}]}' > "$T/labels"
begin
expect_written "name=Rosa"
expect_written "role=rosa-fix"
expect_written "skill=.claude/skills/research/SKILL.md"
grep -qE '^tools=.*WebSearch,WebFetch' "$T/outputs" || fail "expected her tools to hold web search and fetch"
! grep -qE '^tools=.*(Bash,|Bash$)' "$T/outputs" || fail "expected no unrestricted Bash beside the web tools"
# Her build's list is a second copy, in implement.yml, and the two must not drift (decisions A33d).
grep -qF "$(sed 's/^tools=/tools="/; s/$/"/' <(grep '^tools=' "$T/outputs"))" "$root/factory/workflows/implement.yml" \
  || fail "expected implement.yml to give Rosa the same tools for a build"
expect_call "gh pr comment 7 --body Fix round 1 of 3: Rosa is addressing what failed."

scenario "Esme for any other ticket, and for a pull request that closes none"
checks_failed
echo '{"labels":[{"name":"tweak"}]}' > "$T/labels"
begin
expect_written "name=Esme"
expect_written "role=esme-fix"
expect_written "skill=.claude/skills/implement/SKILL.md"
expect_written "tools=Read,Write,Edit,Glob,Grep,Bash"
echo "No ticket." > "$T/body"
begin
expect_status 0
expect_written "name=Esme"
[ "$(grep -c '^gh issue view' "$T/calls")" = 1 ] || fail "expected no ticket to be read for a pull request that closes none"

scenario "the comment that says the round has begun is not one the count reads, and links the run"
checks_failed
run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID=900 GITHUB_SERVER_URL=https://github.example "$scripts/begin-fix-round.sh" 7 "$T/failed.txt"
expect_status 0
expect_call "gh pr comment 7 --body Fix round 1 of 3: Fred is addressing what failed. https://github.example/owner/myapp/actions/runs/900"
! grep '^gh pr comment' "$T/calls" | grep -qF "factory:fix-round" || fail "expected the comment to carry no marker"

scenario "numbers the round after the ones counted, and goes ahead for the third"
checks_failed
echo "[$round,$round]" > "$T/comments.json"
begin
expect_written "go=true"
expect_written "round=3"
expect_call "Fix round 3 of 3"

scenario "goes ahead for a pull request in conflict that has no ci run for its head"
checks_failed; in_conflict; no_ci_run
begin
expect_status 0
expect_written "go=true"
grep -qF "===== conflict with main =====" "$T/failed.txt" || fail "expected the conflict to be in the file the engineer is given"

scenario "a round begun with only a conflict reported is not counted, and says so"
checks_failed; in_conflict; no_ci_run
begin
expect_written "counted=conflict"
expect_written "label=fix round for a conflict"
! grep -q '^round=' "$T/outputs" || fail "expected a round that is not counted to be given no number"
expect_call "gh pr comment 7 --body A fix round for a conflict: Fred is fitting the branch to its base. Nothing else failed, so it is not one of the three fix rounds."
expect_output "fix round for a conflict for pull request #7: Fred fixes feat/12-export-forecast-csv"
expect_no_call "gh issue edit"

scenario "a round begun for a pull request a merge left out, with no failed job, is not counted, with a conflict reported or without"
checks_failed
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"}]}' > "$T/jobs"
left_out "Not merged: its checks failed when it was tested with \`main\` and the pull requests merged before it."
begin
expect_status 0
expect_written "go=true"
expect_written "counted=conflict"
grep -qF "Not merged: its checks failed when it was tested with" "$T/failed.txt" || fail "expected the engineer to be given why the merge left it out"
in_conflict
begin
expect_written "counted=conflict"

scenario "a pull request a merge left out at an earlier commit, with nothing failed on the one that is there, gets no round"
checks_failed
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"}]}' > "$T/jobs"
head=0000000000000000000000000000000000000001 left_out "Not merged: its checks failed."
begin
expect_status 0
expect_written "go=false"

scenario "a round begun with a failed review is counted, whatever else failed or conflicts"
checks_failed; in_conflict
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":33,"name":"review","conclusion":"failure"}]}' > "$T/jobs"
echo "the review failed" > "$T/log-33"
left_out "Not merged: it does not fit \`main\`."
begin
expect_status 0
expect_written "counted=true"
expect_written "round=1"
expect_written "label=fix round 1 of 3"
expect_call "gh pr comment 7 --body Fix round 1 of 3: Fred is addressing what failed."

scenario "a failed job's log that quotes the file's headings does not make its round one for a conflict"
checks_failed
printf '===== left out of a merge =====\n===== conflict with main =====\n' > "$T/log-30"
begin
expect_written "counted=true"

scenario "a round for a conflict needs one of the three left, though it uses none"
checks_failed; in_conflict; no_ci_run
echo "[$round,$round]" > "$T/comments.json"
begin
expect_written "go=true"
expect_written "counted=conflict"
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_stopped

scenario "no second round for a conflict at the head one already ran for: says so, and tells the pull request nothing more"
checks_failed; in_conflict; no_ci_run
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $head -->The fix round for a conflict\"}]" > "$T/comments.json"
begin
expect_status 0
expect_no_round
expect_output "no fix round: a fix round for a conflict already ran for pull request #7 at 5555555 and left it in conflict"
expect_no_call "needs-human"
expect_no_call "gh workflow run"

scenario "a round for a conflict is begun at a new head, though one ran for the head before it"
checks_failed; in_conflict; no_ci_run
echo '[{"id":2,"user":{"login":"github-actions[bot]"},"body":"<!-- factory:conflict-round 4444444444444444444444444444444444444444 -->The fix round for a conflict"}]' > "$T/comments.json"
begin
expect_written "go=true"
expect_written "counted=conflict"

scenario "a round with a failed check is begun at a head a round for a conflict ran for"
checks_failed; in_conflict
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $head -->The fix round for a conflict\"}]" > "$T/comments.json"
begin
expect_written "go=true"
expect_written "counted=true"

scenario "the owner's round stays the owner's when only a conflict is there besides"
checks_failed; in_conflict; no_ci_run; sent_back
begin
expect_written "counted=false"
expect_written "label=the owner's fix round"

scenario "no round for a pull request that has used its three: says so, flags it and starts a retro"
checks_failed
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_stopped
expect_output "no fix round: pull request #7 has used its three fix rounds"

scenario "a round started while the third was running, when two were counted, stops the pull request once the third is"
checks_failed
echo "[$round,$round]" > "$T/comments.json"
run env GH_TOKEN=workflow-token "$scripts/start-fix-round.sh" 7
expect_call "gh workflow run fix.yml -f pr=7"
expect_no_call "gh pr edit"
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_stopped

scenario "says nothing to a pull request that has used its three rounds when nothing is there to fix: the third fixed it"
checks_failed; nothing_failed
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_no_round
expect_no_call "gh pr edit"
expect_no_call "gh workflow run"
expect_output "nothing is there to fix on pull request #7"

for words in "pr edit 7" "issue edit 12" "pr comment 7" "workflow run retro.yml"; do
  scenario "three rounds used: stops with a message, and begins no round, when this fails: gh $words"
  checks_failed
  echo "[$round,$round,$round]" > "$T/comments.json"
  echo "$words" > "$T/fail"
  begin
  expect_status 1
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_output "Pull request #7 has used its three fix rounds"
  expect_output "No fix round was begun for pull request #7."
done

recorded() {
  local counted
  counted=$(sed -n 's/^counted=fresh-run://p' "$T/outputs")
  echo "[$(fresh_run_round "$counted")]" > "$T/comments.json"
}

scenario "a pull request with three rounds used, whose checks failed only because the run is an install behind, is neither stopped nor left waiting: a round for a fresh run begins"
checks_failed; not_settled "$stale_run"
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_written "go=true"
expect_written "counted=fresh-run:$ci_yml"
expect_written "label=fix round for a fresh run"
expect_written "head=$head"
expect_written "name=Fred"
! grep -q '^round=' "$T/outputs" || fail "expected a round that is not counted to be given no number"
expect_call "gh pr comment 7 --body A fix round for a fresh run: Fred is merging the base into the branch."
expect_call "Nothing else failed, so it is not one of the three fix rounds."
expect_output "fix round for a fresh run for pull request #7: Fred fixes feat/12-export-forecast-csv"
grep -qF "git fetch origin main && git merge origin/main" "$T/failed.txt" || fail "expected the engineer to be given what gets the pull request a fresh run"
expect_no_call "--add-label needs-human"
expect_no_call "retro.yml"
expect_no_call "gh run rerun"
expect_no_call "gh issue edit"

scenario "a ci run whose ci.yml differs from main's at review time gets a round for a fresh run, and no needs-human"
checks_failed; reviews_behind
begin
expect_status 0
expect_written "go=true"
expect_written "counted=fresh-run:$ci_yml"
grep -qF "Adam (architecture and taste): not reviewed. $review_behind" "$T/failed.txt" || fail "expected what the review job said to be in the file the engineer is given"
expect_no_call "--add-label needs-human"
expect_no_call "retro.yml"

scenario "the same request made twice for one head begins one round for a fresh run: the second goes on as any other failure does"
checks_failed; not_settled "$stale_run"
begin
expect_written "counted=fresh-run:$ci_yml"
recorded
begin
expect_status 0
expect_written "go=true"
expect_written "counted=true"
expect_written "round=1"
expect_call "Fix round 1 of 3"

scenario "made twice for a pull request with three rounds used, the second request stops it for a person"
checks_failed; not_settled "$stale_run"
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_written "counted=fresh-run:$ci_yml"
echo "[$round,$round,$round,$(fresh_run_round)]" > "$T/comments.json"
: > "$T/calls"
begin
expect_status 0
expect_stopped

scenario "a round for a fresh run begins again once main holds another ci.yml"
checks_failed; not_settled "$stale_run"
echo "[$(fresh_run_round)]" > "$T/comments.json"
echo dddddddddddddddddddddddddddddddddddddddd > "$T/ci-yml"
begin
expect_written "counted=fresh-run:dddddddddddddddddddddddddddddddddddddddd"

scenario "the owner's round stays the owner's when the run is an install behind besides"
checks_failed; not_settled "$stale_run"; sent_back
begin
expect_written "counted=false"
expect_written "label=the owner's fix round"

# The last is the read that counts the rounds: collect-failures.sh reads the comments too, for another reason.
for words in "api repos/{owner}/{repo}/contents/.github" "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq .[] "; do
  scenario "the run an install behind: stops with a message, and begins no round, when this fails: gh $words"
  checks_failed; not_settled "$stale_run"
  echo "$words" > "$T/fail"
  begin
  expect_status 1
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_output "Whether pull request #7 needs only a fresh ci run is not known, so no fix round was begun."
  expect_no_call "gh pr comment"
done

scenario "the owner's round: goes ahead for a pull request the owner sent back, though nothing failed"
checks_failed; nothing_failed; sent_back
begin
expect_status 0
expect_written "go=true"
expect_written "counted=false"
expect_written "name=Fred"
! grep -q '^round=' "$T/outputs" || fail "expected the owner's round to be given no number"
grep -qxF "Not like this: keep the old column order." "$T/failed.txt" || fail "expected what the owner asked for to be in the file the engineer is given"
expect_call "gh pr comment 7 --body The owner's fix round: Fred is making the changes the owner asked for. It is not one of the three fix rounds."
expect_output "the owner's fix round for pull request #7"

scenario "the owner's round goes ahead for a pull request that has used its three rounds"
checks_failed; sent_back
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_written "go=true"
expect_written "counted=false"
expect_no_call "retro.yml"
expect_no_call "--add-label needs-human"
grep -qF "src/page.tsx: unused variable" "$T/failed.txt" || fail "expected what failed to be in the file as well as what the owner asked for"
grep -qxF "===== the owner asked for changes =====" "$T/failed.txt" || fail "expected what the owner asked for to be in the file"

owner_round() { echo "{\"id\":4,\"user\":{\"login\":\"$1\"},\"body\":\"<!-- factory:owner-round $2 -->The owner's fix round: the engineer's session ran.\"}"; }

scenario "no second owner's round for a request that has had one: a merge that landed while that round ran started this one"
checks_failed; sent_back
echo "[$(owner_round 'github-actions[bot]' 41)]" > "$T/comments.json"
begin
expect_status 0
expect_no_round
expect_no_call "--remove-label"
expect_output "no fix round: the owner's fix round already ran for what repo-owner asked for on pull request #7, and pushed nothing: it waits for its owner"

scenario "a second request sent while the first one's round ran gets its own round, though that round was recorded after it"
checks_failed; sent_back
reviewed 42 repo-owner CHANGES_REQUESTED "$head" "And put the totals last."
echo "[$(owner_round 'github-actions[bot]' 41)]" > "$T/comments.json"
begin
expect_status 0
expect_written "go=true"
expect_written "counted=false"
expect_written "review=42"
grep -qxF "And put the totals last." "$T/failed.txt" || fail "expected what the second request asked for to be in the file the engineer is given"

scenario "only the factory's own record of an owner's round counts: a comment that quotes it refuses no round"
checks_failed; sent_back
echo "[$(owner_round 'claude[bot]' 41)]" > "$T/comments.json"
begin
expect_status 0
expect_written "go=true"
expect_written "counted=false"
expect_written "review=41"

scenario "the owner's round takes needs-human off the pull request and its ticket, which is in progress again"
checks_failed; sent_back
begin
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh issue edit 12 --remove-label needs-human --add-label in-progress"
echo "No ticket." > "$T/body"
: > "$T/calls"
begin
expect_status 0
expect_call "gh pr edit 7 --remove-label needs-human"
expect_no_call "gh issue edit"

scenario "every other round takes needs-human off the pull request too, and leaves its ticket as it is"
checks_failed
begin
expect_call "gh pr edit 7 --remove-label needs-human"
expect_no_call "gh issue edit"
: > "$T/calls"
in_conflict; nothing_failed
begin
expect_written "counted=conflict"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_no_call "gh issue edit"

scenario "a round that could not take needs-human off its pull request is not begun"
checks_failed
echo "pr edit 7 --remove-label" > "$T/fail"
begin
expect_status 1
expect_written "go=false"
[ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
expect_output "Could not take needs-human off pull request #7, so no fix round was begun."

scenario "the round begins when GitHub fails once to take needs-human off: the call is made again"
checks_failed; sent_back
echo "pr edit 7 --remove-label" > "$T/fail-once"
begin
expect_status 0
expect_written "go=true"
[ "$(grep -c '^gh pr edit 7 --remove-label needs-human$' "$T/calls")" = 2 ] || fail "expected the label to be taken off at the second call"
expect_call "sleep 10"
expect_no_call "Start the fix round again"

scenario "a read that fails once is made again, and the round begins"
checks_failed
printf '%s\n' "pr view 7 --json state" "issue view 12" > "$T/fail-once"
begin
expect_status 0
expect_written "go=true"
expect_written "name=Fred"

scenario "the announcement that fails once is made again, and the round begins"
checks_failed
echo "pr comment 7" > "$T/fail-once"
begin
expect_status 0
expect_written "go=true"
[ "$(grep -c '^gh pr comment 7 --body Fix round 1 of 3' "$T/calls")" = 2 ] || fail "expected the announcement to be made a second time"

scenario "a round announced whose label never comes off: one comment says no round began and how to start one, and it ends with an error"
checks_failed; sent_back
echo "pr edit 7 --remove-label" > "$T/fail"
: > "$T/outputs"
run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_OUTPUT="$T/outputs" GITHUB_RUN_ID=900 GITHUB_SERVER_URL=https://github.example "$scripts/begin-fix-round.sh" 7 "$T/failed.txt" repo-owner
expect_status 1
expect_written "go=false"
[ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
[ "$(grep -c '^gh pr edit 7 --remove-label needs-human$' "$T/calls")" = 6 ] || fail "expected the label call to be made six times"
expect_first_line "gh pr comment 7 --body" "Start the fix round again on the [\`fix\` workflow's page](https://github.example/owner/myapp/actions/workflows/fix.yml), where \"Run workflow\" starts it with \`pr\` set to \`7\`."
[ "$(grep -c '^gh pr comment 7 --body Start the fix round again' "$T/calls")" = 1 ] || fail "expected one comment saying no round began"
expect_call "No fix round began, though the comment before this one says one did: GitHub did not take the \`needs-human\` label off this pull request. The log has what GitHub answered: https://github.example/owner/myapp/actions/runs/900"
expect_output "Could not take needs-human off pull request #7, so no fix round was begun."
expect_no_call "gh issue edit"

scenario "the owner's round whose ticket could not be marked in progress says on the pull request that no round began"
checks_failed; sent_back
echo "issue edit 12" > "$T/fail"
begin
expect_status 1
expect_first_line "gh pr comment 7 --body" "Start the fix round again on the [\`fix\` workflow's page](https://github.com/owner/myapp/actions/workflows/fix.yml), where \"Run workflow\" starts it with \`pr\` set to \`7\`."
expect_call "GitHub did not mark ticket #12 as in progress again."

scenario "a round not announced gets no comment saying none began"
checks_failed
echo "pr comment 7" > "$T/fail"
begin
expect_status 1
[ "$(grep -c '^gh pr comment 7 --body Fix round 1 of 3' "$T/calls")" = 6 ] || fail "expected the announcement to be tried six times"
expect_no_call "Start the fix round again"
expect_no_call "--remove-label"

scenario "says so, and still ends with its error, when the comment that no round began cannot be posted"
checks_failed
printf '%s\n' "pr edit 7 --remove-label" "pr comment 7 --body Start" > "$T/fail"
begin
expect_status 1
expect_written "go=false"
expect_output "Could not say on pull request #7 that no fix round began."
expect_output "Could not take needs-human off pull request #7, so no fix round was begun."

scenario "only the owner's review makes the round the owner's: another reviewer's, or one a push answered, does not"
checks_failed; nothing_failed
reviewed 40 someone-else CHANGES_REQUESTED
begin
expect_status 0
expect_no_round
expect_output "its owner has not sent it back"
checks_failed
echo "[$round,$round,$round]" > "$T/comments.json"
reviewed 41 repo-owner CHANGES_REQUESTED 6666666666666666666666666666666666666666
begin
expect_stopped

scenario "no round is the owner's when no owner is given: fix.yml as it was before it passed one"
checks_failed; nothing_failed; sent_back
: > "$T/outputs"
run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_OUTPUT="$T/outputs" "$scripts/begin-fix-round.sh" 7 "$T/failed.txt"
expect_status 0
expect_no_round
expect_no_call "pulls/7/reviews"

scenario "no owner's round for a pull request the factory did not open: it is its author's to change"
checks_failed; sent_back
echo '{"state":"OPEN","author":{"login":"someone-else"},"headRefName":"feat/own-work","baseRefName":"main","labels":[]}' > "$T/pull"
begin
expect_status 0
expect_no_round
expect_no_call "--remove-label"

while IFS='|' read -r words message; do
  scenario "the owner's round: stops with a message, and begins no round, when this fails: gh $words"
  checks_failed; sent_back
  echo "$words" > "$T/fail"
  begin
  expect_status 1
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_output "$message"
  expect_no_output "the owner's fix round for pull request #7"
done <<'CALLS'
pr view 7 --json headRefOid --jq|What repo-owner asked for on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/pulls/7/reviews?per_page|What repo-owner asked for on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/pulls/7/reviews/41|What repo-owner asked for on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/pulls/7/comments|What repo-owner asked for on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq .[] |The owner's fix rounds of pull request #7 could not be counted, so no fix round was begun.
pr comment 7|Could not say on pull request #7 that a fix round has begun, so it was not begun.
pr edit 7 --remove-label|Could not take needs-human off pull request #7, so no fix round was begun.
issue edit 12|Could not mark issue #12 as in progress again, so the owner's fix round on pull request #7 was not begun.
CALLS

scenario "what the owner asked for could not be read: the file is not left with only part of what there is to fix"
checks_failed; sent_back
echo "api repos/{owner}/{repo}/pulls/7/comments" > "$T/fail"
begin
[ ! -e "$T/failed.txt" ] || fail "expected the file to be taken away"

scenario "needs-human stays on a pull request whose owner's round could not be announced"
checks_failed; sent_back
echo "pr comment 7" > "$T/fail"
begin
expect_no_call "--remove-label"

scenario "no round for a pull request the factory did not open"
checks_failed
echo '{"state":"OPEN","author":{"login":"repo-owner"},"headRefName":"feat/own-work","baseRefName":"main","labels":[]}' > "$T/pull"
begin
expect_status 0
expect_no_round
expect_output "was not opened by the factory"
expect_no_call "gh api"

scenario "no round for a pull request that is not open"
checks_failed
echo '{"state":"MERGED","author":{"login":"app/claude"},"headRefName":"feat/12-export-forecast-csv","baseRefName":"main","labels":[]}' > "$T/pull"
begin
expect_status 0
expect_no_round
expect_output "pull request #7 is not open"

scenario "no round when nothing is there to fix: no failed job in the latest ci run, and no conflict"
checks_failed; nothing_failed
begin
expect_status 0
expect_no_round
expect_output "nothing is there to fix on pull request #7"

# GitHub started a ci run for the head only while it took the pull request for a draft (decisions A543a).
only_skipped_run() { echo '[{"databaseId":901,"conclusion":"skipped"}]' > "$T/runs"; }

scenario "a pull request whose head has only a skipped ci run gets a round to start the checks: not counted, and only marking it ready again to do"
checks_failed; only_skipped_run
begin
expect_status 0
expect_written "go=true"
expect_written "counted=start-checks"
expect_written "label=fix round to start the checks"
! grep -q '^round=' "$T/outputs" || fail "expected no number among the three for a round to start the checks"
expect_call "gh pr comment 7 --body A fix round to start the checks: Fred is marking this pull request ready for review again, which starts the checks its last commit 5555555 never had. Nothing failed, so it is not one of the three fix rounds."
grep -qxF "Run: gh pr ready 7 --undo && gh pr ready 7" "$T/failed.txt" || fail "expected the engineer to be told to mark the pull request ready again"
grep -qF "Push nothing and change nothing else in this round." "$T/failed.txt" || fail "expected the engineer to be told to push nothing"
expect_no_call "runs/901/jobs"

scenario "the same for a head with no ci run at all, and for a pull request that has used its three rounds, whose count is not read"
checks_failed; no_ci_run
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_written "counted=start-checks"
expect_no_call "issues/7/comments?per_page=100 --paginate --jq .[] "
expect_no_call "retro.yml"

scenario "a labelled pull request with no ci run that ran gets the round to start the checks, not a retest: main may hold nothing to merge"
checks_failed; only_skipped_run; waits_for_main
begin
expect_status 0
expect_written "counted=start-checks"
expect_call "gh pr edit 7 --remove-label needs-human --remove-label waits-for-main"

scenario "no round to start the checks of a draft, which its engineer is still building"
checks_failed; only_skipped_run
echo true > "$T/draft"
begin
expect_status 0
expect_no_round
expect_output "nothing is there to fix on pull request #7"

scenario "the owner's round stays the owner's when no ci run of the head ran its jobs"
checks_failed; only_skipped_run; sent_back
begin
expect_status 0
expect_written "counted=false"

scenario "stops with a message, and begins no round, when the ci runs cannot be listed to tell whether one ran its jobs"
checks_failed; only_skipped_run
# collect-failures.sh lists them first, and is answered: every later listing fails.
mv "$T/bin/gh" "$T/bin/github"
stub gh 'case "$*" in *"/actions/workflows/ci.yml/runs?"*) [ "$(grep -c "/actions/workflows/ci.yml/runs?" "$T/calls")" -le 2 ] || { echo "gh: failed: $*" >&2; exit 1; } ;; esac; exec "$T/bin/github" "$@"'
begin
expect_status 1
expect_written "go=false"
[ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
expect_output "Could not list the ci runs for 5555555, the head of pull request #7, so no fix round was begun."
expect_no_call "gh pr comment"

scenario "refuses anything that is not a pull request number"
checks_failed
begin '7; echo'
expect_status 1
expect_no_round
expect_no_call "gh "

scenario "no round when checks failed because the workflows on main had not settled: checks is run again"
checks_failed; not_settled
begin
expect_status 0
expect_no_round
expect_call "gh run rerun --job 30"
expect_output "no fix round: the checks of pull request #7 failed because the workflows on main had not settled"
expect_no_call "gh pr edit"
expect_no_call "gh workflow run"

scenario "the same for a pull request that has used its three rounds: it is not stopped"
checks_failed; not_settled "$never_installed"
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_no_round
expect_call "gh run rerun --job 30"
expect_no_call "needs-human"
expect_no_call "retro.yml"

scenario "a round goes ahead when checks failed that way a second time, in a later attempt of the run"
checks_failed; not_settled
echo '[{"databaseId":900,"attempt":2}]' > "$T/runs"
begin
expect_status 0
expect_written "go=true"
expect_no_call "gh run rerun"

scenario "the owner's round goes ahead though checks failed that way: what the owner asked for is there to fix"
checks_failed; not_settled; sent_back
begin
expect_status 0
expect_written "go=true"
expect_written "counted=false"
expect_no_call "gh run rerun"

# The head's read failing is covered by false-alarm.test.sh: owner-review.sh makes that read first.
scenario "workflows not settled: stops with a message, and begins no round, when the attempt of the ci run cannot be read"
checks_failed; not_settled
mv "$T/bin/gh" "$T/bin/github"
stub gh 'case "$*" in *"/actions/workflows/ci.yml/runs?"*"(.attempt)"*) echo "gh: failed: $*" >&2; exit 1 ;; esac; exec "$T/bin/github" "$@"'
begin
expect_status 1
expect_no_round
expect_output "Whether an engineer can fix what failed on pull request #7 is not known, so no fix round was begun."
expect_no_call "gh run rerun"

scenario "workflows not settled: stops with a message, and begins no round, when this fails: gh run rerun --job 30"
checks_failed; not_settled
echo "run rerun --job 30" > "$T/fail"
begin
expect_status 1
expect_no_round
expect_output "and could not be run again"

while IFS='|' read -r words message; do
  scenario "stops with a message, and begins no round, when this fails: gh $words"
  checks_failed
  echo "$words" > "$T/fail"
  begin
  expect_status 1
  expect_written "go=false"
  [ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"
  expect_output "$message"
  expect_no_output "fix round 1 of 3 for pull request #7"
done <<'CALLS'
pr view 7 --json state|Could not read pull request #7 from GitHub, so no fix round was begun.
api repos/{owner}/{repo}/pulls/7/reviews|What repo-owner asked for on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq .[] |The fix rounds of pull request #7 could not be counted, so no fix round was begun.
pr view 7 --json headRefOid,baseRefName|What failed on pull request #7 could not be read, so no fix round was begun.
api repos/{owner}/{repo}/actions/workflows/ci.yml/runs|What failed on pull request #7 could not be read, so no fix round was begun.
api repos/owner/myapp/actions/runs/900/jobs|What failed on pull request #7 could not be read, so no fix round was begun.
pr view 7 --json body|The ticket pull request #7 closes could not be read, so who built it is not known.
issue view 12|Issue #12 could not be read from GitHub, so who built pull request #7 is not known.
pr comment 7|Could not say on pull request #7 that a fix round has begun, so it was not begun.
CALLS

scenario "a pull request labelled waits-for-main gets a round for a retest: not counted, the label off, and only the merge of main to make"
checks_failed; waits_for_main
begin
expect_status 0
expect_written "go=true"
expect_written "counted=retest"
expect_written "label=fix round for a retest"
! grep -q '^round=' "$T/outputs" || fail "expected no number among the three for a round for a retest"
expect_call "gh pr comment 7 --body A fix round for a retest: Fred is merging \`main\` into the branch, which runs its checks again."
expect_call "so it is not one of the three fix rounds."
expect_call "gh pr edit 7 --remove-label needs-human --remove-label waits-for-main"
grep -qF "git fetch origin main && git merge origin/main" "$T/failed.txt" || fail "expected the engineer to be told to merge main"
grep -qF "Change nothing else in this round." "$T/failed.txt" || fail "expected the engineer to be told to change nothing else"
! grep -qF "src/page.tsx: unused variable" "$T/failed.txt" || fail "expected the failure that lay outside the pull request not to be given as work"

scenario "a round for a retest is begun for a pull request that has used its three rounds, and does not read the count"
checks_failed; waits_for_main
echo "[$round,$round,$round]" > "$T/comments.json"
begin
expect_status 0
expect_written "counted=retest"
expect_no_call "issues/7/comments?per_page=100 --paginate --jq .[] "
expect_no_call "retro.yml"

scenario "a pull request without the label keeps it off the call, and its round is counted"
checks_failed
begin
expect_written "counted=true"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_no_call "--remove-label waits-for-main"

scenario "the owner's round on a labelled pull request is its retest as well: the label off, and main to merge beside what the owner asked for"
checks_failed; waits_for_main; sent_back
begin
expect_status 0
expect_written "counted=false"
expect_written "label=the owner's fix round"
expect_call "gh pr edit 7 --remove-label needs-human --remove-label waits-for-main"
grep -qF "Not like this" "$T/failed.txt" || fail "expected what the owner asked for to be in the file the engineer is given"
grep -qF "git fetch origin main && git merge origin/main" "$T/failed.txt" || fail "expected the engineer to be told to merge main as well"
! grep -qF "Change nothing else in this round." "$T/failed.txt" || fail "expected the engineer not to be kept from what the owner asked for"

scenario "a counted round's engineer is told how to label a pull request whose failure lies outside it; no other round's is"
checks_failed
begin
grep -qF "gh pr edit 7 --add-label waits-for-main" "$T/failed.txt" || fail "expected the file to say how to label the pull request"
grep -qF "say in one pull request comment what the pull request waits for" "$T/failed.txt" || fail "expected the file to ask for a comment saying what it waits for"
in_conflict; nothing_failed
begin
expect_written "counted=conflict"
! grep -qF "waits-for-main" "$T/failed.txt" || fail "expected a round for a conflict not to be told of the label"
checks_failed; sent_back
begin
expect_written "counted=false"
! grep -qF "waits-for-main" "$T/failed.txt" || fail "expected the owner's round not to be told of the label"

scenario "a round for a retest that could not take the labels off is not begun, and the label stays for the next merge"
checks_failed; waits_for_main
echo "pr edit 7 --remove-label" > "$T/fail"
begin
expect_status 1
expect_written "go=false"
[ "$(wc -l < "$T/outputs")" -eq 1 ] || fail "expected it to write go=false and nothing else"

scenario "leaves nothing behind but the file the engineer is given"
checks_failed
begin
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"

scenario "while the Claude usage limit holds every agent no round begins: the run keeps its place, and the pull request is told when it starts"
checks_failed
sessions_remote sessions
hold_is 99999999999
: > "$T/outputs"
run env GITHUB_OUTPUT="$T/outputs" GITHUB_RUN_ID=900 "$scripts/begin-fix-round.sh" 7 "$T/failed.txt"
expect_status 0
[ "$(cat "$T/outputs")" = "held=true"$'\n'"kept=true"$'\n'"go=false" ] || fail "expected it to write held=true, kept=true and go=false, got: $(cat "$T/outputs")"
expect_output "no fix round: the Claude usage limit holds every agent until 5138-11-16 09:46 UTC: a fix round starts after it"
[ "$(the_hold)" = "99999999999"$'\n'"run 900" ] || fail "expected run 900 to keep its place on the sessions branch, got: $(the_hold)"
expect_first_line "gh issue comment 7 --body" "Nothing to do: a fix round starts after the Claude usage limit resets on 5138-11-16 09:46 UTC."
expect_no_call "gh pr edit"
expect_no_call "gh pr comment"
[ ! -e "$T/failed.txt" ] || fail "expected nothing to be collected for a round that does not begin"

scenario "stops with a message, and begins no round, when the hold of the usage limit cannot be read"
checks_failed
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
begin
expect_status 1
expect_output "Whether the Claude usage limit holds every agent is not known, so no fix round was begun for pull request #7."
expect_no_call "gh pr edit"
expect_no_call "gh pr comment"
