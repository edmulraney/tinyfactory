#!/usr/bin/env bash
# Tests for save-session.sh: an agent's transcript, saved on the sessions branch by a script that never fails its job.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

transcript() { echo '{"turns": 3}' > "$T/out.json"; }
save() { run env GITHUB_RUN_ID=900 "$scripts/save-session.sh" "$@"; }
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
