#!/usr/bin/env bash
# Tests for fix-rounds.sh: a pull request's fix rounds are counted only from the factory's own record (decisions A28).
. "$(dirname "$0")/helpers.sh"

marker='<!-- factory:fix-round -->'

# comment <author> <text>: one comment, as GitHub's REST API lists it.
comment() { jq -nc --arg login "$1" --arg body "$2" '{id: 1, user: {login: $login}, body: $body}'; }
comments() {
  printf '%s\n' "$@" | jq -sc . > "$T/comments.json"
  stub gh 'case "$*" in
    "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq "*) json "$(cat "$T/comments.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
expect_count() {
  expect_status 0
  [ "$out" = "$1" ] || fail "expected it to print exactly: $1"
}

scenario "one announcement and three comments that quote the marker count as one"
comments \
  "$(comment 'github-actions[bot]' "**Ryan (correctness): FAIL**"$'\n'"The count reads any comment that holds \`$marker\`.")" \
  "$(comment 'github-actions[bot]' "${marker}Fix round 1 of 3: the engineer is addressing the failed checks and reviews.")" \
  "$(comment 'claude[bot]' "Fix round 1. The filter for $marker now looks at the author.")" \
  "$(comment 'github-actions[bot]' "**Adam (architecture and taste): PASS**"$'\n'"$marker is counted once.")"
run "$scripts/fix-rounds.sh" 7
expect_count 1

scenario "an announcement by any other author counts as none"
comments \
  "$(comment 'claude[bot]' "${marker}Fix round 1 of 3: the engineer is addressing the failed checks and reviews.")" \
  "$(comment 'repo-owner' "${marker}Fix round 2 of 3")" \
  "$(comment 'github-actions' "${marker}Fix round 3 of 3")"
run "$scripts/fix-rounds.sh" 7
expect_count 0

scenario "the factory's own comment that only quotes the marker, even on a line of its own, counts as none"
comments "$(comment 'github-actions[bot]' "**Ryan (correctness): FAIL**"$'\n'"${marker}Fix round 1 of 3")"
run "$scripts/fix-rounds.sh" 7
expect_count 0

scenario "every announced round is counted"
round=$(comment 'github-actions[bot]' "${marker}Fix round")
comments "$round" "$(comment 'vercel[bot]' "[vc]: preview")" "$round" "$round"
run "$scripts/fix-rounds.sh" 7
expect_count 3

scenario "the owner's rounds are not among the three, and are counted when asked for"
comments "$round" \
  "$(comment 'github-actions[bot]' "<!-- factory:owner-round -->The owner's fix round: the engineer's session ran.")" \
  "$(comment 'repo-owner' "<!-- factory:owner-round -->Not the factory's record.")" \
  "$(comment 'github-actions[bot]' "**Adam (architecture and taste): PASS**"$'\n'"<!-- factory:owner-round --> is quoted here.")"
run "$scripts/fix-rounds.sh" 7
expect_count 1
run "$scripts/fix-rounds.sh" 7 owner
expect_count 1

scenario "the rounds for a conflict are counted for the head asked about, and are in neither other count"
a=5555555555555555555555555555555555555555; b=6666666666666666666666666666666666666666
comments "$round" \
  "$(comment 'github-actions[bot]' "<!-- factory:conflict-round $a -->The fix round for a conflict: the engineer's session ran.")" \
  "$(comment 'repo-owner' "<!-- factory:conflict-round $a -->Not the factory's record.")" \
  "$(comment 'github-actions[bot]' "**Ryan (correctness): PASS**"$'\n'"<!-- factory:conflict-round $a --> is quoted here.")"
run "$scripts/fix-rounds.sh" 7 conflict "$a"
expect_count 1
run "$scripts/fix-rounds.sh" 7 conflict "$b"
expect_count 0
run "$scripts/fix-rounds.sh" 7
expect_count 1
run "$scripts/fix-rounds.sh" 7 owner
expect_count 0

scenario "the rounds for a fresh run are counted for the ci.yml asked about, and are in no other count"
a=cccccccccccccccccccccccccccccccccccccccc; b=dddddddddddddddddddddddddddddddddddddddd
comments "$round" \
  "$(comment 'github-actions[bot]' "<!-- factory:fresh-run-round $a -->The fix round for a fresh run: the engineer's session ran.")" \
  "$(comment 'repo-owner' "<!-- factory:fresh-run-round $a -->Not the factory's record.")" \
  "$(comment 'github-actions[bot]' "**Ryan (correctness): PASS**"$'\n'"<!-- factory:fresh-run-round $a --> is quoted here.")"
run "$scripts/fix-rounds.sh" 7 fresh-run "$a"
expect_count 1
run "$scripts/fix-rounds.sh" 7 fresh-run "$b"
expect_count 0
run "$scripts/fix-rounds.sh" 7
expect_count 1
run "$scripts/fix-rounds.sh" 7 owner
expect_count 0
run "$scripts/fix-rounds.sh" 7 conflict "$a"
expect_count 0

scenario "anything else asked for is refused, and nothing is read"
comments "$round"
run "$scripts/fix-rounds.sh" 7 everyone
expect_status 2
expect_output "Usage: fix-rounds.sh <pr-number> [owner | conflict <head> | fresh-run <ci.yml-id>]"
run "$scripts/fix-rounds.sh" 7 fresh-run
expect_status 2
run "$scripts/fix-rounds.sh" 7 fresh-run 'cc") or true or ("'
expect_status 2
run "$scripts/fix-rounds.sh" 7 conflict
expect_status 2
run "$scripts/fix-rounds.sh" 7 conflict '55") or true or ("'
expect_status 2
expect_no_call "gh api"

scenario "no comments count as none"
comments
run "$scripts/fix-rounds.sh" 7
expect_count 0

scenario "stops with a message when the comments cannot be read: that is not a pull request with no fix round"
stub gh 'echo "gh: HTTP 502: Bad Gateway" >&2; exit 1'
run "$scripts/fix-rounds.sh" 7
expect_status 1
expect_output "Could not read the comments of pull request #7 from GitHub"
run "$scripts/fix-rounds.sh" 7 owner
expect_status 1
[ "$(grep -cx '[0-9]*' <<<"$out")" = 0 ] || fail "expected it to print no count"
