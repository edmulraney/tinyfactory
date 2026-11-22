#!/usr/bin/env bash
# Tests for save-session.sh: an agent's transcript, saved on the sessions branch by a script that never fails its job.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

transcript() { echo '{"turns": 3}' > "$T/out.json"; }
# A home of the test's own, so that the sessions of whoever runs the tests are never read.
save() { run env GITHUB_RUN_ID=900 HOME="$T/home" "$scripts/save-session.sh" "$@"; }
session_file() {
  local file="$T/home/.claude/projects/$1/$2.jsonl"
  mkdir -p "$(dirname "$file")"
  shift 2
  printf '%s\n' "$@" > "$file"
}
saved() { pushed_files | grep -E "^$1/[0-9]{8}T[0-9]{6}Z-$2-run900\.json$"; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"
}

scenario "saves the transcript in the ticket's folder, named by time, role and run"
sessions_remote sessions
transcript
save esme issue-12 "$T/out.json"
expect_status 0
file=$(saved issue-12 esme) || fail "expected issue-12/<time>-esme-run900.json, found: $(pushed_files)"
expect_output "saved esme session as $file"
[ "$(on_github show "sessions:$file")" = '{"turns": 3}' ] || fail "expected the transcript's own contents"
[ "$(on_github log -1 --format=%s sessions)" = "session: esme issue-12" ] || fail "expected the commit to name the role and the folder"
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the earlier transcript to still be on the branch"
expect_nothing_left

scenario "makes the sessions branch when there is none, with the file that stops Vercel deploying it"
sessions_remote
transcript
save adam pr-7 "$T/out.json"
expect_status 0
saved pr-7 adam >/dev/null || fail "expected the transcript on a new sessions branch, found: $(pushed_files)"
on_github show sessions:apps/web/vercel.json | grep -q '"deploymentEnabled": false' || fail "expected vercel.json to turn deployments off"

scenario "saves a lesson under the key it is given"
sessions_remote sessions
transcript
save lesson lessons "$T/out.json"
expect_status 0
saved lessons lesson >/dev/null || fail "expected lessons/<time>-lesson-run900.json, found: $(pushed_files)"

scenario "tries again when the push loses a race, and then saves"
sessions_remote sessions
transcript
refuses_pushes 1
save ryan pr-7 "$T/out.json"
expect_status 0
expect_call "sleep"
expect_output "saved ryan session as pr-7/"
saved pr-7 ryan >/dev/null || fail "expected the transcript on the branch after the second try"

scenario "says so and still exits 0 when the transcript cannot be pushed"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
transcript
refuses_pushes
save esme issue-12 "$T/out.json"
expect_status 0
expect_output "could not save the esme session (push kept failing)"
expect_no_output "saved esme session"
[ "$(pushes)" = 6 ] || fail "expected six pushes, got $(pushes)"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"
expect_nothing_left

scenario "exits 0 when GitHub cannot be reached at all"
sessions_remote sessions
transcript
rm -rf "$T/remote.git"
save esme issue-12 "$T/out.json"
expect_status 0
expect_output "could not save the esme session"
expect_nothing_left

scenario "exits 0, having pushed nothing, when the agent left no transcript"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
save esme issue-12 "$T/missing.json"
expect_status 0
expect_output "no transcript to save for esme"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"

scenario "exits 0 when no transcript file was named"
sessions_remote sessions
save esme issue-12 ""
expect_status 0
expect_output "no transcript to save for esme"

scenario "saves the session file Claude Code wrote as it ran when no transcript was named, as one array, and says so"
sessions_remote sessions
session_file -work-repo abc '{"type":"user","timestamp":"2026-11-20T05:00:00Z"}' '{"type":"assistant","timestamp":"2026-11-20T05:59:00Z"}'
save esme issue-12 ""
expect_status 0
file=$(saved issue-12 esme) || fail "expected issue-12/<time>-esme-run900.json, found: $(pushed_files)"
expect_output "no transcript was given for esme: saving the session file Claude Code wrote as it ran, $T/home/.claude/projects/-work-repo/abc.jsonl"
expect_output "saved esme session as $file"
[ "$(on_github show "sessions:$file" | jq -c .)" = '[{"type":"user","timestamp":"2026-11-20T05:00:00Z"},{"type":"assistant","timestamp":"2026-11-20T05:59:00Z"}]' ] \
  || fail "expected the session file's lines as one JSON array, found: $(on_github show "sessions:$file")"
expect_nothing_left

scenario "saves the session file when the transcript named was never written"
sessions_remote sessions
session_file -work-repo abc '{"type":"user"}'
save esme issue-12 "$T/missing.json"
expect_status 0
saved issue-12 esme >/dev/null || fail "expected the session file saved, found: $(pushed_files)"

scenario "saves the transcript it is given, and not the session file, when both are there"
sessions_remote sessions
transcript
session_file -work-repo abc '{"type":"user"}'
save esme issue-12 "$T/out.json"
expect_status 0
file=$(saved issue-12 esme) || fail "expected the transcript saved, found: $(pushed_files)"
[ "$(on_github show "sessions:$file")" = '{"turns": 3}' ] || fail "expected the transcript's own contents"
expect_no_output "no transcript was given"

scenario "saves the newest of several session files, whichever project folder holds it"
sessions_remote sessions
session_file -work-repo new '{"session":"new"}'
session_file -work-other old '{"session":"old"}'
session_file -work-repo older '{"session":"older"}'
touch -t 202611200500 "$T/home/.claude/projects/-work-other/old.jsonl"
touch -t 202611200400 "$T/home/.claude/projects/-work-repo/older.jsonl"
touch -t 202611200600 "$T/home/.claude/projects/-work-repo/new.jsonl"
save esme issue-12 ""
expect_status 0
file=$(saved issue-12 esme) || fail "expected the session file saved, found: $(pushed_files)"
[ "$(on_github show "sessions:$file" | jq -c .)" = '[{"session":"new"}]' ] || fail "expected the newest session file, found: $(on_github show "sessions:$file")"

scenario "leaves out a line the session's end cut off, and saves the lines before it"
sessions_remote sessions
session_file -work-repo abc '{"type":"user"}' '{"type":"assis'
save esme issue-12 ""
expect_status 0
file=$(saved issue-12 esme) || fail "expected the session file saved, found: $(pushed_files)"
[ "$(on_github show "sessions:$file" | jq -c .)" = '[{"type":"user"}]' ] || fail "expected only the whole lines, found: $(on_github show "sessions:$file")"

scenario "does not save a subagent's file, which sits a folder deeper"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
session_file -work-repo/abc/subagents agent-1 '{"type":"user"}'
save esme issue-12 ""
expect_status 0
expect_output "no transcript to save for esme"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"

scenario "never saves a session file as a lesson"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
session_file -work-repo abc '{"type":"user"}'
save lesson lessons "$T/missing.json"
expect_status 0
expect_output "no transcript to save for lesson"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"

scenario "says so, exits 0 and pushes nothing when the session file cannot be read"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
session_file -work-repo abc '{"type":"user"}'
stub jq 'exit 5'
save esme issue-12 ""
expect_status 0
expect_output "could not save the esme session (the session file $T/home/.claude/projects/-work-repo/abc.jsonl could not be read)"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"
expect_nothing_left

scenario "says so, exits 0 and pushes nothing when no temporary file can be made"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
session_file -work-repo abc '{"type":"user"}'
stub mktemp 'exit 1'
save esme issue-12 ""
expect_status 0
expect_output "could not save the esme session (no temporary file)"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"

scenario "says so and leaves nothing behind when the session file cannot be pushed"
sessions_remote sessions
session_file -work-repo abc '{"type":"user"}'
refuses_pushes
save esme issue-12 ""
expect_status 0
expect_output "could not save the esme session (push kept failing)"
expect_nothing_left
