#!/usr/bin/env bash
# Tests for factory/scripts/retro-lesson.sh: the lesson a retro returned, from the action's output or its saved result.
. "$(dirname "$0")/helpers.sh"

lesson='{"summary":"three fix rounds","cause":"check-missing"}'

session() {
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"assistant"},%s]\n' "$1" > "$T/session.json"
}

# lesson_only <execution-file>: no output from the action, and only stdout kept, where the lesson is printed.
lesson_only() {
  OUTPUT="" run bash -c '"$0" "$1" 2>/dev/null' "$scripts/retro-lesson.sh" "$1"
}

expect_no_lesson() {
  expect_status 1
  expect_output "the retro returned no lesson"
  [[ "$out" != *'"cause"'* ]] || fail "expected no lesson to be printed"
}

scenario "the action gave the lesson: it is printed as it is"
session '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":12,"structured_output":{"summary":"from the file","cause":"ticket"}}'
OUTPUT="$lesson" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_status 0
[ "$out" = "$lesson" ] || fail "expected the action's lesson and nothing else"

scenario "a session that ended with a result after more turns than the limit has its lesson read from the file"
session '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":56,"structured_output":{"summary":"three fix rounds","cause":"check-missing"}}'
lesson_only "$T/session.json"
expect_status 0
[ "$out" = "$lesson" ] || fail "expected the lesson in the saved result"

scenario "a lesson read from the file says so, apart from the lesson"
session '{"type":"result","subtype":"success","is_error":false,"num_turns":56,"structured_output":{"summary":"three fix rounds","cause":"check-missing"}}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_status 0
expect_output "read from the session's saved result"

scenario "a result saved as one object, not a list"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"summary":"three fix rounds","cause":"check-missing"}}' > "$T/session.json"
lesson_only "$T/session.json"
expect_status 0
[ "$out" = "$lesson" ] || fail "expected the lesson in the saved result"

scenario "a session that ended with no result has no lesson"
session '{"type":"assistant","structured_output":{"summary":"not a result","cause":"ticket"}}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "a session out of turns has no lesson"
# Not marked as an error, and holding a lesson, so that the subtype alone is what refuses it.
session '{"type":"result","subtype":"error_max_turns","is_error":false,"terminal_reason":"max_turns","num_turns":40,"structured_output":{"summary":"half","cause":"outside"}}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "a session the model's API cut short has no lesson, whatever its result holds"
session '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"structured_output":{"summary":"half","cause":"outside"}}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "a finished session that returned no lesson"
session '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","result":"done"}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "a result whose output is not a lesson"
session '{"type":"result","subtype":"success","is_error":false,"structured_output":{"summary":"no cause"}}'
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "an output that is not a lesson, and no result to read"
OUTPUT='not json' run "$scripts/retro-lesson.sh" "$T/missing.json"
expect_no_lesson

scenario "a file that cannot be read"
printf 'not json\n' > "$T/session.json"
OUTPUT="" run "$scripts/retro-lesson.sh" "$T/session.json"
expect_no_lesson

scenario "no file named: the action saved nothing"
unset OUTPUT
run "$scripts/retro-lesson.sh" ""
expect_no_lesson

# The workflow's schema and what the skill tells the agent are kept alike here (decisions A184a, A184b).
schema=$(sed -n "s/^  LESSON_SCHEMA: '\(.*\)'$/\1/p" "$root/factory/workflows/retro.yml")
skill="$root/.claude/skills/retro/SKILL.md"

scenario "the schema accepts the cause process, one of eight"
run jq -r '.properties.cause.enum | "\(length) causes: \(join(" "))"' <<<"$schema"
expect_status 0
expect_output "8 causes: "
expect_output " process "

scenario "the schema makes a change say what it removes"
run jq -e '.properties.change | (.properties.removes.type == "string") and (.required | index("removes") != null)' <<<"$schema"
expect_status 0

scenario "the retro skill names every cause and every part of a change the schema holds, and what a change removes"
run jq -r '.properties.cause.enum[], (.properties.change.properties | keys[])' <<<"$schema"
expect_status 0
[ -n "$out" ] || fail "expected the schema to list its causes"
for word in $out removes; do
  grep -qF "\`$word\`" "$skill" || fail "expected the skill to name \`$word\`"
done
