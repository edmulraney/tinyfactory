#!/usr/bin/env bash
# Tests for sessions-branch.sh: push_to_sessions puts a caller's files on the branch, trying six times before it fails.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

# pushing [bash]: a caller that sources the script, with the given bash run before it pushes.
pushing() {
  cat > "$T/caller.sh" <<CALLER
#!/usr/bin/env bash
set -euo pipefail
. "$scripts/sessions-branch.sh"
add_note() { echo "staged in a clone" >> "$T/staged"; mkdir -p "\$2/\$1" && echo "\${NOTE:-note}" > "\$2/\$1/note.txt"; }
${1:-}
if push_to_sessions "note: added" add_note notes; then echo "returned 0"; else echo "returned \$?"; fi
CALLER
  # A runner has no committer identity of its own.
  run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL bash "$T/caller.sh"
}
count() { grep -c "^$1" "$T/calls" || true; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"
}

scenario "puts the caller's files on the branch in one commit, by the bot, and keeps what was there"
sessions_remote sessions
before=$(on_github rev-parse main)
pushing
expect_status 0
expect_output "returned 0"
[ "$(on_github show sessions:notes/note.txt)" = note ] || fail "expected notes/note.txt on the branch"
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcript to still be on the branch"
[ "$(on_github log -1 --format='%s by %an <%ae>' sessions)" = "note: added by github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ] \
  || fail "expected the commit message given, made by the bot, got: $(on_github log -1 --format='%s by %an <%ae>' sessions)"
[ "$(on_github rev-list --count sessions)" = 2 ] || fail "expected one commit added to the branch"
[ "$(on_github rev-parse main)" = "$before" ] || fail "expected main not to move"
[ "$(on_github for-each-ref --format='%(refname)' | sort | tr '\n' ' ')" = "refs/heads/main refs/heads/sessions " ] \
  || fail "expected no branch but main and sessions"
expect_no_call "sleep"
expect_nothing_left

scenario "the caller's command is given its own arguments and then the clone"
sessions_remote sessions
pushing
expect_status 0
[ "$(pushed_files | grep note.txt)" = "notes/note.txt" ] || fail "expected the file in the folder the caller named, found: $(pushed_files)"

scenario "makes the branch when there is none, sharing no history with main"
sessions_remote
pushing
expect_status 0
expect_output "returned 0"
[ "$(on_github show sessions:notes/note.txt)" = note ] || fail "expected the file on a new sessions branch"
[ "$(on_github rev-list --count sessions)" = 1 ] || fail "expected a branch of one commit"
[ -z "$(on_github merge-base main sessions)" ] || fail "expected no shared history with main"

scenario "adds the file that stops Vercel deploying the branch when it is missing"
sessions_remote sessions
pushing
expect_status 0
on_github show sessions:apps/web/vercel.json | grep -q '"deploymentEnabled": false' || fail "expected vercel.json to turn deployments off"

scenario "leaves that file alone when the branch has it"
sessions_remote sessions
pushing
vercel=$(on_github rev-parse sessions:apps/web/vercel.json)
NOTE=another pushing
expect_status 0
[ "$(on_github rev-parse sessions:apps/web/vercel.json)" = "$vercel" ] || fail "expected vercel.json unchanged"
[ "$(on_github show sessions:notes/note.txt)" = another ] || fail "expected the second push's file"

scenario "pushes nothing, and still returns 0, when the branch already holds exactly these files"
sessions_remote sessions
pushing
tip=$(on_github rev-parse sessions)
pushing
expect_status 0
expect_output "returned 0"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected no new commit on the branch"

scenario "tries again from a fresh clone when a push loses a race"
sessions_remote sessions
refuses_pushes 2
pushing
expect_status 0
expect_output "returned 0"
[ "$(pushes)" = 3 ] || fail "expected three pushes, got $(pushes)"
[ "$(count sleep)" = 2 ] || fail "expected two waits, got $(count sleep)"
[ "$(wc -l < "$T/staged" | tr -d ' ')" = 3 ] || fail "expected the files staged in three clones"
[ "$(on_github show sessions:notes/note.txt)" = note ] || fail "expected the file on the branch after the third try"
[ "$(on_github rev-list --count sessions)" = 2 ] || fail "expected one commit added, and none from the refused tries"
expect_nothing_left

scenario "returns non-zero after six failed pushes, having said nothing and left nothing"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
refuses_pushes
pushing
expect_status 0
expect_output "returned 1"
[ "$out" = "returned 1" ] || fail "expected it to print nothing of its own"
[ "$(pushes)" = 6 ] || fail "expected six pushes, got $(pushes)"
[ "$(count sleep)" = 5 ] || fail "expected five waits, got $(count sleep)"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"
expect_nothing_left

scenario "returns non-zero when GitHub cannot be reached at all"
sessions_remote sessions
rm -rf "$T/remote.git"
pushing
expect_status 0
expect_output "returned 1"
expect_nothing_left

scenario "returns non-zero when the caller's command fails, and pushes nothing"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
pushing 'add_note() { return 1; }'
expect_status 0
expect_output "returned 1"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"
expect_nothing_left

scenario "pushes to this repo only: another repo's address leads nowhere"
sessions_remote sessions
tip=$(on_github rev-parse sessions)
export GITHUB_REPOSITORY=owner/other
# The real git would go to the network for an address the test did not map; it is refused instead.
printf '[url "file://%s/nowhere.git"]\n  insteadOf = https://\n' "$T" >> "$T/gitconfig"
pushing
expect_output "returned 1"
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected the branch as it was"

scenario "never shows the token, even when every push fails"
sessions_remote sessions
refuses_pushes
pushing
expect_no_output "secret"
