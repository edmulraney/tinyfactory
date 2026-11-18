#!/usr/bin/env bash
# Tests for factory/scripts/shipping.sh, which the shipping scripts source for `retry` and `not_merged`.
. "$(dirname "$0")/helpers.sh"

# sourcing <lines> [VAR=value...]: a script that sources it, as the shipping scripts do, and runs the lines.
sourcing() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\npr=7\n. "%s/shipping.sh"\n%s\n' "$scripts" "$1" > "$T/caller.sh"
  stub sleep ':'
  stub gh '
    remaining=$(cat "$T/failures" 2>/dev/null || echo 0)
    if [ "$remaining" -gt 0 ]; then echo $((remaining - 1)) > "$T/failures"; echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi
    case "$*" in "pr view"*) echo "half an answer"; echo "the answer" ;; esac'
  run env -u GITHUB_RUN_ID "${@:2}" bash "$T/caller.sh"
}
count() { grep -c "^$1" "$T/calls" || true; }

scenario "retry gives the answer of a call that works at once, and asks once"
sourcing 'response=$(retry gh pr view 7); echo "got: $response"'
expect_status 0
expect_output "got: half an answer"
expect_output "the answer"
[ "$(count "gh pr view")" = 1 ] || fail "expected one call, got $(count "gh pr view")"
expect_no_call "sleep"

scenario "retry asks again after a failure, ten seconds apart, and gives only the answer that came"
echo 2 > "$_base/$((_count))/failures"
sourcing 'response=$(retry gh pr view 7 2>/dev/null); echo "got: $response"'
expect_status 0
expect_output "got: half an answer"
expect_no_output "502"
[ "$(count "gh pr view")" = 3 ] || fail "expected three calls, got $(count "gh pr view")"
[ "$(count "sleep 10")" = 2 ] || fail "expected two waits, got $(count "sleep 10")"

scenario "retry gives up after six failures and fails, having waited five times"
echo 99 > "$_base/$((_count))/failures"
sourcing 'response=$(retry gh pr view 7) || { echo "gave up with: [$response]"; exit 3; }'
expect_status 3
expect_output "gave up with: []"
[ "$(count "gh pr view")" = 6 ] || fail "expected six calls, got $(count "gh pr view")"
[ "$(count "sleep 10")" = 5 ] || fail "expected five waits, got $(count "sleep 10")"

scenario "not_merged says why on the pull request, adds needs-human and stops the script"
sourcing 'not_merged "GitHub was out"; echo "went on"'
expect_status 1
expect_first_line "gh pr comment 7 --body" "Approve this pull request again: the merge is tried again then."
expect_call "Not merged: GitHub was out."
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_output "went on"
expect_no_call "actions/runs"
[ "$(count "gh pr comment")" = 1 ] || fail "expected one comment, got $(count "gh pr comment")"

scenario "not_merged points at the log of the run it is in"
sourcing 'not_merged "GitHub was out"' GITHUB_RUN_ID=900 GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/myapp
expect_status 1
expect_call "Not merged: GitHub was out. The log has what GitHub answered: https://github.example/owner/myapp/actions/runs/900"

scenario "not_merged still fails, with the reason in the log, when GitHub takes no comment"
echo 99 > "$_base/$((_count))/failures"
sourcing 'not_merged "GitHub was out"'
expect_status 1
expect_output "Not merged: GitHub was out."
expect_output "and the pull request could not be told so"

scenario "notify_not_merged says why and flags the pull request, and the script goes on"
sourcing 'notify_not_merged "the checks have not passed"; echo "went on"'
expect_status 0
expect_call "Not merged: the checks have not passed."
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "went on"

scenario "notify_not_merged fails when GitHub takes no comment"
echo 99 > "$_base/$((_count))/failures"
sourcing 'notify_not_merged "the checks have not passed" || { echo "not told"; exit 3; }'
expect_status 3
expect_output "and the pull request could not be told so"
