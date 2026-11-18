#!/usr/bin/env bash
# Tests for factory/scripts/apply-setup.sh, which runs each merged setup script the factory holds a credential for.
. "$(dirname "$0")/helpers.sh"

merged=abcdef0123456789abcdef0123456789abcdef01
setup=".claude/skills/bootstrap/scripts"

# merged_change <script>...: $T/body, $T/merge.json and $T/files.json answer gh; $T/fail lists the gh calls that fail.
merged_change() {
  local name tree="$T/src/owner-myapp-abcdef0"
  mkdir -p "$tree/$setup"
  for name in "$@"; do
    cat > "$tree/$setup/$name" <<EOF
#!/usr/bin/env bash
echo "the merged copy of $name ran with: \$*"
[ -f "$setup/$name" ] && echo "from the root of the merged tree"
echo "GH_TOKEN=\${GH_TOKEN:-unset} BOARD_TOKEN=\${BOARD_TOKEN:-unset}"
EOF
    chmod +x "$tree/$setup/$name"
  done
  tar -czf "$T/tree.tgz" -C "$T/src" owner-myapp-abcdef0
  printf '%s\n' "$@" | jq -R --arg dir "$setup" '{filename: ($dir + "/" + .)}' | jq -s '. + [{filename: "factory/decisions.md"}]' > "$T/files.json"
  printf 'Closes #12\n' > "$T/body"
  echo "{\"mergeCommit\":{\"oid\":\"$merged\"}}" > "$T/merge.json"
  : > "$T/fail"
  export merged
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "repo view --json nameWithOwner "*) json "{\"nameWithOwner\":\"owner/myapp\"}" "$@" ;;
      "api repos/owner/myapp/pulls/7/files "*) json "$(cat "$T/files.json")" "$@" ;;
      "pr view 7 --json mergeCommit "*) json "$(cat "$T/merge.json")" "$@" ;;
      "api repos/owner/myapp/tarball/$merged") cat "$T/tree.tgz" ;;
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "pr comment 7 --body-file "*) cp "$5" "$T/comment" ;;
      "issue comment 12 --body-file "*) cp "$5" "$T/ticket-comment" ;;
      "issue edit 12 --add-label needs-human" | "pr edit 7 --add-label needs-human") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
apply() { run env GH_TOKEN=workflow-token "$@" "$scripts/apply-setup.sh" 7; }
comment_says() {
  [[ "$(cat "$T/comment" 2>/dev/null)" == *"$1"* ]] || fail "expected the comment on the pull request to hold: $1"
}
ticket_says() {
  [[ "$(cat "$T/ticket-comment" 2>/dev/null)" == *"$1"* ]] || fail "expected the comment on the ticket to hold: $1"
}
comment_lacks() {
  [[ "$(cat "$T/comment" 2>/dev/null)" != *"$1"* ]] || fail "expected the comment on the pull request not to hold: $1"
}
left_nothing_behind() {
  [ -z "$(ls -A "$TMPDIR")" ] || fail "left behind in the temporary directory: $(ls -A "$TMPDIR")"
}

scenario "does nothing for a pull request that changed no setup script"
merged_change
apply
expect_status 0
expect_output "pull request #7 changed no setup script; nothing to apply"
expect_no_call "gh pr comment"
expect_no_call "tarball"

scenario "ignores a changed file that is not a setup script itself"
merged_change
echo "[{\"filename\":\"$setup/lib/board.sh\"},{\"filename\":\"$setup/notes.md\"},{\"filename\":\"factory/scripts/board.sh\"}]" > "$T/files.json"
apply
expect_status 0
expect_output "nothing to apply"

scenario "runs the merged copy of board.sh with the board token and nothing else"
merged_change board.sh
apply BOARD_TOKEN=board-token
expect_status 0
comment_says 'Applied `board.sh` (as merged in abcdef0):'
comment_says "the merged copy of board.sh ran with: myapp"
comment_says "from the root of the merged tree"
comment_says "GH_TOKEN=board-token BOARD_TOKEN=unset"
comment_lacks "workflow-token"
expect_no_call "needs-human"
left_nothing_behind

scenario "leaves board.sh to the owner when the run was given no board token"
merged_change board.sh
apply
expect_status 0
comment_says '`board.sh` changed, and this run was not given the `BOARD_TOKEN` secret'
comment_says "\`$setup/board.sh myapp\`"
comment_lacks "the merged copy of board.sh ran"
[ "$(sed -n 1p "$T/comment")" = "Run by hand, with your own logins, each setup script below that failed or was not run: the factory does not run it again." ] && [ -z "$(sed -n 2p "$T/comment")" ] || fail "expected the comment's first line to say what a person must do, got: $(head -n 1 "$T/comment")"
expect_call "gh issue edit 12 --add-label needs-human"

scenario "runs the merged copy of labels.sh with the workflow's own token, and keeps the board token from it"
merged_change labels.sh
apply BOARD_TOKEN=board-token
expect_status 0
comment_says 'Applied `labels.sh` (as merged in abcdef0):'
comment_says "the merged copy of labels.sh ran with: owner/myapp"
comment_says "from the root of the merged tree"
comment_says "GH_TOKEN=workflow-token BOARD_TOKEN=unset"
expect_no_call "needs-human"
left_nothing_behind

# failing_labels: the merged labels.sh fails with exit 3.
failing_labels() {
  printf '#!/usr/bin/env bash\necho "could not create the label"\nexit 3\n' > "$T/src/owner-myapp-abcdef0/$setup/labels.sh"
  tar -czf "$T/tree.tgz" -C "$T/src" owner-myapp-abcdef0
}

scenario "flags the ticket with the output of a merged script that failed, and fails"
merged_change labels.sh
failing_labels
apply
expect_status 1
ticket_says 'Ran `labels.sh` (as merged in abcdef0 by pull request #7) and it failed with exit 3'
ticket_says "could not create the label"
[ "$(head -n 1 "$T/ticket-comment")" = "Run by hand, with your own logins, each setup script below that failed or was not run: the factory does not run it again." ] || fail "expected the comment's first line to say what a person must do, got: $(head -n 1 "$T/ticket-comment")"
expect_call "gh issue edit 12 --add-label needs-human"
expect_no_call "gh pr comment"
expect_output "a setup script failed after the merge of pull request #7"
left_nothing_behind

scenario "tells the ticket what the other scripts did too, when one of them failed"
merged_change board.sh labels.sh vercel.sh
failing_labels
apply BOARD_TOKEN=board-token
expect_status 1
ticket_says 'Applied `board.sh`'
ticket_says 'Ran `labels.sh`'
ticket_says '`vercel.sh` changed'
expect_call "gh issue edit 12 --add-label needs-human"

scenario "flags the pull request itself, with the output, when a failed script's pull request closes no ticket"
merged_change labels.sh
failing_labels
echo "A person's own pull request." > "$T/body"
apply
expect_status 1
comment_says "could not create the label"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue"

scenario "fails without a flag when the ticket could not be told of a failed script"
merged_change labels.sh
failing_labels
echo "issue comment 12" > "$T/fail"
apply
expect_failure
expect_no_call "needs-human"
left_nothing_behind

scenario "fails when the ticket of a failed script could not be flagged"
merged_change labels.sh
failing_labels
echo "issue edit 12" > "$T/fail"
apply
expect_failure
ticket_says "could not create the label"
expect_no_output "a setup script failed after the merge"

scenario "neither runs nor flags a script that changes nothing in a project already set up"
merged_change preflight.sh scaffold.sh purpose.sh bootstrap.sh
apply BOARD_TOKEN=board-token
expect_status 0
expect_output "scaffold.sh changed; it has nothing to apply"
expect_no_output "the merged copy of"
expect_no_call "gh pr comment"
expect_no_call "needs-human"

scenario "never runs a script it holds no credential for, and leaves it to the owner"
merged_change vercel.sh github.sh
apply BOARD_TOKEN=board-token
expect_status 0
comment_says '`vercel.sh` changed, and the factory holds no credential that can run it'
comment_says '`github.sh` changed, and the factory holds no credential that can run it'
comment_lacks "the merged copy of"
expect_call "gh issue edit 12 --add-label needs-human"

scenario "treats a script nobody has classified as needing the owner"
merged_change brand-new-step.sh
apply BOARD_TOKEN=board-token
expect_status 0
comment_says '`brand-new-step.sh` changed, and the factory holds no credential that can run it'
comment_lacks "the merged copy of"
expect_call "gh issue edit 12 --add-label needs-human"

scenario "applies each changed script in one comment"
merged_change board.sh labels.sh vercel.sh
apply BOARD_TOKEN=board-token
expect_status 0
comment_says 'Applied `board.sh`'
comment_says 'Applied `labels.sh`'
comment_says '`vercel.sh` changed'
expect_call "gh issue edit 12 --add-label needs-human"

scenario "flags the pull request itself when it closes no ticket"
merged_change vercel.sh
echo "A person's own pull request." > "$T/body"
apply
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"

scenario "has nothing to apply for a script the pull request deleted"
merged_change board.sh
rm "$T/src/owner-myapp-abcdef0/$setup/board.sh"
tar -czf "$T/tree.tgz" -C "$T/src" owner-myapp-abcdef0
apply BOARD_TOKEN=board-token
expect_status 0
expect_no_call "gh pr comment"
expect_no_call "needs-human"
left_nothing_behind

scenario "refuses a pull request that is not merged"
merged_change board.sh
echo '{"mergeCommit":null}' > "$T/merge.json"
apply BOARD_TOKEN=board-token
expect_status 1
expect_output "pull request #7 is not merged; nothing to apply"
expect_no_call "tarball"
expect_no_call "gh pr comment"

scenario "stops when the repo cannot be named"
merged_change board.sh
echo "repo view" > "$T/fail"
apply BOARD_TOKEN=board-token
expect_failure
expect_no_call "gh pr comment"

scenario "stops when the changed files cannot be listed: that is not a change with no setup script"
merged_change board.sh
echo "api repos/owner/myapp/pulls/7/files" > "$T/fail"
apply BOARD_TOKEN=board-token
expect_failure
expect_no_output "nothing to apply"
expect_no_call "gh pr comment"

scenario "stops when the merge commit cannot be read"
merged_change board.sh
echo "pr view 7 --json mergeCommit" > "$T/fail"
apply BOARD_TOKEN=board-token
expect_failure
expect_no_call "tarball"
expect_no_call "gh pr comment"

scenario "stops, runs nothing and leaves nothing behind when the merged tree cannot be downloaded"
merged_change board.sh
echo "api repos/owner/myapp/tarball" > "$T/fail"
apply BOARD_TOKEN=board-token
expect_failure
expect_no_call "gh pr comment"
expect_no_call "needs-human"
left_nothing_behind

scenario "fails when the comment could not be posted, and leaves nothing behind"
merged_change board.sh
echo "pr comment 7" > "$T/fail"
apply BOARD_TOKEN=board-token
expect_failure
left_nothing_behind

scenario "fails when the ticket could not be flagged for a person"
merged_change vercel.sh
echo "issue edit 12" > "$T/fail"
apply
expect_failure

scenario "fails when the ticket to flag could not be found"
merged_change vercel.sh
echo "pr view 7 --json body" > "$T/fail"
apply
expect_failure
expect_output "Could not read pull request #7"

scenario "applies with the merge commit it is handed, without asking GitHub for it"
merged_change labels.sh
echo '{"mergeCommit":null}' > "$T/merge.json"
run env GH_TOKEN=workflow-token "$scripts/apply-setup.sh" 7 "$merged"
expect_status 0
comment_says "Applied \`labels.sh\` (as merged in abcdef0)"
expect_no_call "gh pr view 7 --json mergeCommit"
