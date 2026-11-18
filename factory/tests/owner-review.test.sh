#!/usr/bin/env bash
# Tests for owner-review.sh: whether the repo's owner sent a pull request back, and what the owner asked for.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

other=6666666666666666666666666666666666666666

run_owner_review() { run env GH_TOKEN=workflow-token "$scripts/owner-review.sh" 7 repo-owner "$@"; }
expect_sent_back() { expect_status 0; [ "$out" = 41 ] || fail "expected it to print the review's id, 41, and nothing else"; }
expect_not_sent_back() { expect_status 0; [ -z "$out" ] || fail "expected it to print nothing"; }

scenario "prints the id of the owner's review that asks for changes to the commit that is there now"
checks_failed; sent_back
run_owner_review
expect_sent_back
[ "$(grep -c '^gh ' "$T/calls")" = 2 ] || fail "expected it to read the head and the reviews, and nothing else, when given no file"

scenario "given a file, adds what the owner asked for to it: the summary and the comments on lines"
checks_failed; sent_back
echo "===== failed job: checks =====" > "$T/failed.txt"
run_owner_review "$T/failed.txt"
expect_sent_back
grep -qxF "===== failed job: checks =====" "$T/failed.txt" || fail "expected what the file already held to be kept"
grep -qxF "===== the owner asked for changes =====" "$T/failed.txt" || fail "expected a heading for what the owner asked for"
grep -qxF "Not like this: keep the old column order." "$T/failed.txt" || fail "expected the review's summary"
grep -qxF -- "--- src/export.ts, line 12" "$T/failed.txt" || fail "expected the file and line of the owner's comment"
grep -qxF "Dates first, as before." "$T/failed.txt" || fail "expected the owner's comment on a line"

scenario "only the owner's review counts, and only its own comments are passed on"
checks_failed; sent_back
run_owner_review "$T/failed.txt"
! grep -qF "A comment of another review." "$T/failed.txt" || fail "expected no comment of another review"
! grep -qF "Not the owner's." "$T/failed.txt" || fail "expected no summary of another review"
checks_failed
reviewed 40 someone-else CHANGES_REQUESTED
run_owner_review "$T/none.txt"
expect_not_sent_back
[ ! -e "$T/none.txt" ] || fail "expected no file to be written when the owner asked for nothing"

scenario "a review with comments on lines and no summary is passed on without one"
checks_failed; sent_back
jq 'map(if .id == 41 then .body = null else . end)' "$T/reviews.json" > "$T/reviews.new"; mv "$T/reviews.new" "$T/reviews.json"
run_owner_review "$T/failed.txt"
expect_sent_back
grep -qxF "Dates first, as before." "$T/failed.txt" || fail "expected the owner's comment on a line"
! grep -qxF "null" "$T/failed.txt" || fail "expected a missing summary to be left out"

scenario "nothing when the owner has reviewed nothing"
checks_failed
run_owner_review
expect_not_sent_back

scenario "nothing when the review is of an earlier commit: a push answered it"
checks_failed
reviewed 41 repo-owner CHANGES_REQUESTED "$other"
run_owner_review
expect_not_sent_back

scenario "nothing when the owner approved afterwards, or dismissed the review"
checks_failed; sent_back
reviewed 42 repo-owner APPROVED
run_owner_review
expect_not_sent_back
checks_failed
reviewed 41 repo-owner DISMISSED
run_owner_review
expect_not_sent_back

scenario "a later review that only comments does not take the request back"
checks_failed; sent_back
reviewed 42 repo-owner COMMENTED
run_owner_review
expect_sent_back

scenario "the latest request is the one passed on"
checks_failed; sent_back
reviewed 43 repo-owner CHANGES_REQUESTED "$head" "And rename the button."
run_owner_review "$T/failed.txt"
[ "$out" = 43 ] || fail "expected the id of the latest review, 43"
grep -qxF "And rename the button." "$T/failed.txt" || fail "expected the latest review's summary"

scenario "refuses anything that is not a pull request number or a login"
checks_failed; sent_back
run env GH_TOKEN=workflow-token "$scripts/owner-review.sh" '7; echo' repo-owner
expect_status 1
run env GH_TOKEN=workflow-token "$scripts/owner-review.sh" 7 'x" or true or "'
expect_status 1
expect_no_call "gh "

while IFS='|' read -r words message; do
  scenario "stops with a message, and writes nothing, when this fails: gh $words"
  checks_failed; sent_back
  echo "$words" > "$T/fail"
  echo "===== failed job: checks =====" > "$T/failed.txt"
  run_owner_review "$T/failed.txt"
  expect_status 1
  expect_output "$message"
  [ "$(tail -n 1 <<<"$out")" != 41 ] || fail "expected it not to say the owner sent the pull request back"
  [ "$(cat "$T/failed.txt")" = "===== failed job: checks =====" ] || fail "expected the file to be left as it was"
done <<'CALLS'
pr view 7 --json headRefOid|Could not read pull request #7 from GitHub, so whether its owner sent it back is not known.
api repos/{owner}/{repo}/pulls/7/reviews?per_page|Could not read the reviews of pull request #7 from GitHub, so whether its owner sent it back is not known.
api repos/{owner}/{repo}/pulls/7/reviews/41|Could not read review 41 of pull request #7 from GitHub, so what its owner asked for is not known.
api repos/{owner}/{repo}/pulls/7/comments|Could not read the comments of review 41 on pull request #7 from GitHub, so what its owner asked for is not known.
CALLS

scenario "leaves nothing behind but what it adds to the file"
checks_failed; sent_back
run_owner_review "$T/failed.txt"
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
