#!/usr/bin/env bash
# Tests for record-fix-round.sh: a fix round is counted only when the engineer's step left an execution file.
. "$(dirname "$0")/helpers.sh"

# A posted comment is listed as the workflow account's, so the count is read back as callers read it.
github() {
  echo '[{"id":1,"user":{"login":"repo-owner"},"body":"Looks good."}]' > "$T/comments.json"
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq "*) json "$(cat "$T/comments.json")" "$@" ;;
      "pr comment 7 --body "*)
        jq --arg body "$5" ". + [{id: (length + 1), user: {login: \"github-actions[bot]\"}, body: \$body}]" "$T/comments.json" > "$T/comments.new"
        mv "$T/comments.new" "$T/comments.json"
        echo "https://github.example/7#comment" ;;
      "pr edit 7 --add-label needs-human") echo "https://github.example/7" ;;
      "pr view 7 --json body "*) json "{\"body\":\"Closes #12\"}" "$@" ;;
      "issue edit 12 --add-label needs-human --remove-label in-progress") echo "https://github.example/12" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
a_session() { echo '[{"type":"result","terminal_reason":"completed","session_id":"abc-123"}]' > "$T/execution.json"; }
record() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/record-fix-round.sh" 7 "$@"; }
count() { env GH_TOKEN=workflow-token "$scripts/fix-rounds.sh" 7 "$@"; }
expect_count() {
  local now
  now=$(count)
  [ "$now" = "$1" ] || fail "expected the pull request to have $1 fix rounds counted, and it has $now"
}

scenario "counts a round whose engineer step left an execution file"
github; a_session
record "$T/execution.json"
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:fix-round -->Fix round 1 of 3: the engineer's session ran."
expect_output "counted fix round 1 of 3 for pull request #7"
expect_count 1
[ "$(count owner)" = 0 ] || fail "expected a counted round not to be recorded as the owner's"
expect_no_call "needs-human"

scenario "numbers each round after the ones before it"
github; a_session
record "$T/execution.json"
record "$T/execution.json"
expect_status 0
expect_call "Fix round 2 of 3"
expect_count 2

scenario "a round whose engineer step left no execution file leaves the count unchanged, adds needs-human and exits 1"
github; a_session
record "$T/execution.json"
record ""
expect_status 1
expect_count 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_first_line "gh pr comment 7 --body" "Start a new fix round on the [\`fix\` workflow's page](https://github.com/owner/myapp/actions/workflows/fix.yml), where \"Run workflow\" starts it with \`pr\` set to \`7\`."
expect_call "The fix round did not run: no engineer's session began, so nothing was fixed and the round is not counted."
expect_output "The fix round did not run"
expect_no_call "gh issue edit"

scenario "the owner's round, which begin-fix-round.sh says is not counted, is not: it is recorded as the owner's"
github; a_session
record "$T/execution.json"
record "$T/execution.json" false
expect_status 0
expect_output "the owner's fix round ran on pull request #7: it is recorded, and not counted"
expect_call "gh pr comment 7 --body <!-- factory:owner-round -->The owner's fix round: the engineer's session ran. It is not one of the three fix rounds."
expect_count 1
[ "$(count owner)" = 1 ] || fail "expected one round of the owner's to be recorded"
expect_no_call "needs-human"

scenario "the owner's round is recorded for the review it was begun for, and for no other"
github; a_session
record "$T/execution.json" false 5555555555555555555555555555555555555555 41
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:owner-round 41 -->The owner's fix round: the engineer's session ran. It is not one of the three fix rounds."
[ "$(count owner)" = 1 ] || fail "expected one round of the owner's to be recorded"
[ "$(count owner 41)" = 1 ] || fail "expected the owner's round to be recorded for the review it was begun for"
[ "$(count owner 42)" = 0 ] || fail "expected no owner's round to be recorded for another review"

scenario "a round begun with only a conflict to fix is not counted: it is recorded for the head it began with, and for no other"
github; a_session
record "$T/execution.json"
record "$T/execution.json" conflict 5555555555555555555555555555555555555555
expect_status 0
expect_output "the fix round for a conflict ran on pull request #7 at 5555555: it is recorded, and not counted"
expect_call "gh pr comment 7 --body <!-- factory:conflict-round 5555555555555555555555555555555555555555 -->The fix round for a conflict: the engineer's session ran, on 5555555. It is not one of the three fix rounds."
expect_count 1
[ "$(count owner)" = 0 ] || fail "expected a round for a conflict not to be recorded as the owner's"
[ "$(count conflict 5555555555555555555555555555555555555555)" = 1 ] || fail "expected one round for a conflict to be recorded for the head it began with"
[ "$(count conflict 6666666666666666666666666666666666666666)" = 0 ] || fail "expected no round for a conflict to be recorded for another head"
expect_no_call "needs-human"

scenario "a round for a conflict given no head, by fix.yml as it was before it passed one, is not counted and leaves no comment"
github; a_session
record "$T/execution.json" conflict
expect_status 0
expect_output "it is not counted, and not recorded, as the head it began with was not given"
expect_count 0
expect_no_call "gh pr comment"

scenario "a round for a conflict that ran fails, and says so, when it could not be recorded"
github; a_session
echo "pr comment 7" > "$T/fail"
record "$T/execution.json" conflict 5555555555555555555555555555555555555555
expect_status 1
expect_output "The fix round for a conflict on pull request #7 ran, but could not be recorded"

scenario "a round for a conflict whose session never began fails like any other, and leaves the ticket alone"
github
record "" conflict
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "The fix round did not run"
expect_no_call "gh issue edit"
expect_count 0

scenario "a round begun only to get a fresh ci run is not counted: it is recorded for the ci.yml main held, and for no other"
github; a_session
record "$T/execution.json" fresh-run:cccccccccccccccccccccccccccccccccccccccc 5555555555555555555555555555555555555555
expect_status 0
expect_output "the fix round for a fresh run ran on pull request #7: it is recorded, and not counted"
expect_call "gh pr comment 7 --body <!-- factory:fresh-run-round cccccccccccccccccccccccccccccccccccccccc -->The fix round for a fresh run: the engineer's session ran. It is not one of the three fix rounds."
expect_count 0
[ "$(count owner)" = 0 ] || fail "expected a round for a fresh run not to be recorded as the owner's"
[ "$(count fresh-run cccccccccccccccccccccccccccccccccccccccc)" = 1 ] || fail "expected one round for a fresh run to be recorded for the ci.yml main held"
[ "$(count fresh-run dddddddddddddddddddddddddddddddddddddddd)" = 0 ] || fail "expected no round for a fresh run to be recorded for another ci.yml"
expect_no_call "needs-human"

scenario "a round for a fresh run that ran fails, and says so, when it could not be recorded"
github; a_session
echo "pr comment 7" > "$T/fail"
record "$T/execution.json" fresh-run:cccccccccccccccccccccccccccccccccccccccc
expect_status 1
expect_output "The fix round for a fresh run on pull request #7 ran, but could not be recorded"

scenario "a round for a fresh run whose session never began fails like any other, records nothing and leaves the ticket alone"
github
record "" fresh-run:cccccccccccccccccccccccccccccccccccccccc
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "The fix round did not run"
expect_no_call "gh issue edit"
[ "$(count fresh-run cccccccccccccccccccccccccccccccccccccccc)" = 0 ] || fail "expected a round that never ran to leave no record"

scenario "the owner's round that ran fails, and says so, when it could not be recorded"
github; a_session
echo "pr comment 7" > "$T/fail"
record "$T/execution.json" false
expect_status 1
expect_output "The owner's fix round on pull request #7 ran, but could not be recorded"

scenario "a round is counted when told so, and when told nothing: fix.yml as it was before it said"
github; a_session
record "$T/execution.json" true
record "$T/execution.json" ""
expect_status 0
expect_count 2

scenario "the owner's round whose session never began fails like any other, and flags the ticket it had unflagged"
github
record "" false
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_output "The fix round did not run"
[ "$(count owner)" = 0 ] || fail "expected a round that never ran not to be recorded"

while IFS='|' read -r words message; do
  scenario "the owner's round that did not run: stops with a message when this fails: gh $words"
  github
  echo "$words" > "$T/fail"
  record "" false
  expect_status 1
  expect_output "$message"
  expect_call "gh pr edit 7 --add-label needs-human"
done <<'CALLS'
pr view 7|The ticket pull request #7 closes could not be read, so it was not flagged for a person.
issue edit 12|Could not add needs-human to issue #12, which pull request #7 closes.
CALLS

scenario "the same for a file that is named and is not there, and for one that is empty"
github
record "$T/never-written.json"
expect_status 1
: > "$T/empty.json"
record "$T/empty.json"
expect_status 1
expect_count 0
[ "$(grep -c '^gh pr edit 7 --add-label needs-human' "$T/calls")" = 2 ] || fail "expected needs-human to be added both times"

scenario "the comment for a round that did not run links the run, and is not one the count reads"
github
run env GH_TOKEN=workflow-token GITHUB_RUN_ID=900 GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/myapp "$scripts/record-fix-round.sh" 7 ""
expect_status 1
expect_call "The log says which: https://github.example/owner/myapp/actions/runs/900"
! grep '^gh pr comment' "$T/calls" | grep -qF "factory:fix-round" || fail "expected the comment to carry no marker"
expect_count 0

scenario "a round that ran is not counted, and says so, when the rounds before it cannot be read"
github; a_session
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
record "$T/execution.json"
expect_status 1
expect_output "ran, but could not be counted: the rounds before it could not be read"
expect_no_call "gh pr comment"

scenario "stops with a message when the comment that counts the round could not be posted"
github; a_session
echo "pr comment 7" > "$T/fail"
record "$T/execution.json"
expect_status 1
expect_output "ran, but could not be counted: the comment that counts it could not be posted"
expect_no_output "counted fix round"

for words in "pr comment 7" "pr edit 7"; do
  scenario "a round that did not run: stops with a message when this fails: gh $words"
  github
  echo "$words" > "$T/fail"
  record ""
  expect_status 1
  expect_output "The fix round did not run"
  expect_output "gh: failed: $words"
done

scenario "a round for a retest is not counted, and leaves no comment: the label that began it is already off"
github; a_session
record "$T/execution.json" retest 5555555555555555555555555555555555555555
expect_status 0
expect_output "the fix round for a retest ran on pull request #7: it is not counted"
expect_no_call "gh pr comment"
expect_count 0
[ "$(count owner)" = 0 ] || fail "expected a round for a retest not to be recorded as the owner's"

scenario "a round for a retest whose session never began fails like any other"
github
record "" retest
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "The fix round did not run"

scenario "a round to start the checks is not counted, and leaves no comment: approve-merge.sh starts one for a commit"
github; a_session
record "$T/execution.json" start-checks 5555555555555555555555555555555555555555
expect_status 0
expect_output "the fix round to start the checks ran on pull request #7: it is not counted"
expect_no_call "gh pr comment"
expect_count 0

scenario "a round to start the checks whose session never began fails like any other"
github
record "" start-checks
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "The fix round did not run"

scenario "leaves nothing behind"
github; a_session
record "$T/execution.json"
record ""
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"

# The attempt was refused, so it takes no place among the three, nor a head's one round of another kind (decisions A395d).
for counted in "" false conflict "fresh-run:6666666666666666666666666666666666666666"; do
  scenario "a round the Claude usage limit ended is not counted or recorded: ${counted:-a counted round}"
  github
  echo '[{"type":"result","is_error":true,"terminal_reason":"api_error","api_error":"usage_limit_reached","session_id":"abc-123"}]' > "$T/execution.json"
  record "$T/execution.json" $counted 5555555555555555555555555555555555555555
  expect_status 0
  expect_output "the Claude usage limit ended the fix round on pull request #7: it is not counted"
  [ ! -s "$T/calls" ] || fail "expected no comment and no label"
  expect_count 0
done
