#!/usr/bin/env bash
# Tests for factory/scripts/session-ending.sh: one word for how a saved agent session ended.
. "$(dirname "$0")/helpers.sh"

session() { printf '%s\n' "$1" > "$T/session.json"; }

scenario "a session the model's API cut short"
session '[{"type":"system","subtype":"api_retry"},{"type":"assistant"},{"type":"result","is_error":true,"terminal_reason":"api_error","api_error_status":529}]'
run "$scripts/session-ending.sh" "$T/session.json"
expect_status 0
[ "$out" = api_error ] || fail "expected api_error"

# Cut down from a real one on the sessions branch (issue-187, 17 November 2026).
scenario "a session the Claude usage limit ended is told from any other API error"
session '[{"type":"assistant","error":"rate_limit","api_error_status":429,"api_error":"usage_limit_reached","api_error_params":{"rate_limit_info":{"status":"rejected","resetsAt":1795431600}}},{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"usage_limit_reached","result":"You'\''ve hit your Fable limit · resets Nov 23, 11am (UTC). Switch to another model to continue.","session_id":"c22ab626"}]'
run "$scripts/session-ending.sh" "$T/session.json"
expect_status 0
[ "$out" = usage_limit ] || fail "expected usage_limit"

scenario "the limit is known by its message alone, whichever limit it names"
session '[{"type":"result","is_error":true,"terminal_reason":"api_error","result":"You'\''ve hit your weekly limit · resets 3pm (UTC)."}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = usage_limit ] || fail "expected usage_limit"

scenario "and by the name of its error alone, when the result holds no message"
session '[{"type":"result","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"usage_limit_reached"}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = usage_limit ] || fail "expected usage_limit"

scenario "a rate limit with the same status is an API error, worth trying again"
session '[{"type":"result","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"rate_limit_error","result":"API Error: 429 Too many requests"}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = api_error ] || fail "expected api_error"

scenario "a session that finished by quoting the message is not one the limit ended"
session '[{"type":"result","is_error":false,"terminal_reason":"completed","result":"You'\''ve hit your Fable limit, the log said."}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = completed ] || fail "expected completed"

scenario "a session that finished"
session '[{"type":"assistant"},{"type":"result","is_error":false,"terminal_reason":"completed"}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = completed ] || fail "expected completed"

scenario "a session that ran out of turns is told from one cut short"
session '[{"type":"assistant"},{"type":"result","is_error":true,"terminal_reason":"max_turns"}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = max_turns ] || fail "expected max_turns"

scenario "a result saved as one object, not a list"
session '{"type":"result","is_error":true,"terminal_reason":"api_error"}'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = api_error ] || fail "expected api_error"

scenario "a session that stopped before any result"
session '[{"type":"assistant","terminal_reason":"not a result"}]'
run "$scripts/session-ending.sh" "$T/session.json"
expect_status 0
[ "$out" = none ] || fail "expected none"

scenario "a result that gives no reason"
session '[{"type":"result","is_error":true}]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = none ] || fail "expected none"

scenario "a file that cannot be read"
session 'not json'
run "$scripts/session-ending.sh" "$T/session.json"
expect_status 0
[ "$out" = none ] || fail "expected none"

scenario "an empty list"
session '[]'
run "$scripts/session-ending.sh" "$T/session.json"
[ "$out" = none ] || fail "expected none"

scenario "no file"
run "$scripts/session-ending.sh" "$T/missing.json"
expect_status 0
[ "$out" = none ] || fail "expected none"

scenario "no file named: the action saved nothing"
run "$scripts/session-ending.sh" ""
expect_status 0
[ "$out" = none ] || fail "expected none"
