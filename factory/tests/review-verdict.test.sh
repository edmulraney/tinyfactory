#!/usr/bin/env bash
# Tests for factory/scripts/review-verdict.sh: the verdict a review ended with, from its saved result or the action.
. "$(dirname "$0")/helpers.sh"

pass='{"findings":[],"assumptions":[]}'
fail='{"findings":[{"file":"a.ts","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}]}'

session() {
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"assistant"},%s]\n' "$1" > "$T/session.json"
}
finished() { session "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"terminal_reason\":\"completed\",\"num_turns\":$1,\"structured_output\":$2}"; }

# verdict_only <execution-file>: only stdout kept, where the verdict is printed.
verdict_only() {
  run bash -c '"$0" "$1" 2>/dev/null' "$scripts/review-verdict.sh" "$1"
}
expect_verdict() {
  expect_status 0
  [ "$out" = "$1" ] || fail "expected this verdict and nothing else: $1"$'\n'"got: $out"
}

scenario "a session that ended with a verdict after more turns than the limit has it read from the file"
finished 56 "$fail"
OUTPUT="" verdict_only "$T/session.json"
expect_verdict "$fail"

scenario "a verdict read from the file, the action having given none, says so apart from the verdict"
finished 56 "$pass"
OUTPUT="" run "$scripts/review-verdict.sh" "$T/session.json"
expect_status 0
expect_output "the action gave no verdict: it is read from the session's saved result"

scenario "the action's verdict is printed when the saved result holds none"
session '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","result":"done"}'
OUTPUT="$pass" verdict_only "$T/session.json"
expect_verdict "$pass"

scenario "the last session's saved verdict comes before one the action gave for an earlier session"
finished 56 "$pass"
OUTPUT="$fail" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict "$pass"

scenario "a result saved as one object, not a list"
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"structured_output\":$pass}" > "$T/session.json"
OUTPUT="" verdict_only "$T/session.json"
expect_verdict "$pass"

scenario "a session out of turns has no saved verdict"
# Not marked as an error, and holding a verdict, so that the subtype alone is what refuses it.
session "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":false,\"terminal_reason\":\"max_turns\",\"num_turns\":40,\"structured_output\":$pass}"
OUTPUT="" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict ""

scenario "a session the model's API cut short has no saved verdict, whatever its result holds"
session "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"terminal_reason\":\"api_error\",\"api_error_status\":529,\"structured_output\":$pass}"
OUTPUT="" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict ""

scenario "a session that ended with no result has no saved verdict"
session "{\"type\":\"assistant\",\"structured_output\":$pass}"
OUTPUT="" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict ""

scenario "a saved output with no list of findings is not a verdict, and the action's output is printed as given"
finished 12 '{"summary":"no findings"}'
OUTPUT="not json" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict "not json"

scenario "a file that cannot be read"
printf 'not json\n' > "$T/session.json"
OUTPUT="$fail" run "$scripts/review-verdict.sh" "$T/session.json"
expect_verdict "$fail"

scenario "a file that is missing"
OUTPUT="$pass" run "$scripts/review-verdict.sh" "$T/missing.json"
expect_verdict "$pass"

scenario "no file named and no output: the action saved nothing"
unset OUTPUT
run "$scripts/review-verdict.sh" ""
expect_verdict ""
