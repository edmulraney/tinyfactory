#!/usr/bin/env bash
# Tests for hand-over.sh: marks a pull request ready only once GitHub reports the last commit as its head.
. "$(dirname "$0")/helpers.sh"

# branch: a clone on a pushed branch with one commit more than its remote; sets $earlier and $last.
# $T/head holds the commit GitHub reports as the head of pull request 7: the earlier one.
branch() {
  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" . 2>/dev/null
  git checkout -q -b feat/7-export-csv
  git commit -q --allow-empty -m "chore: start work on #7"
  git push -q -u origin HEAD
  earlier=$(git rev-parse HEAD)
  git commit -q --allow-empty -m "feat: export forecast as CSV"
  last=$(git rev-parse HEAD)
  echo "$earlier" > "$T/head"
  stub gh 'case "$*" in
    "api repos/{owner}/{repo}/pulls/7 --jq "*) json "{\"head\":{\"sha\":\"$(cat "$T/head")\"}}" "$@" ;;
    "pr ready 7") [ ! -e "$T/refuses" ] || { echo "gh: HTTP 502" >&2; exit 1; } ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
  stub sleep ':'
}
on_branch() { git --git-dir="$T/remote.git" rev-parse feat/7-export-csv; }

scenario "pushes the last commit and marks the pull request ready once it is the head"
branch
echo "$last" > "$T/head"
run "$scripts/hand-over.sh" 7
expect_status 0
[ "$(on_branch)" = "$last" ] || fail "expected the branch on GitHub to hold the last commit"
expect_calls 1 "gh pr ready 7"
expect_no_call "sleep"

scenario "marks nothing ready while the head is the earlier commit, and marks it once the head changes"
branch
# The branch holds the last commit by the third wait; the pull request's head follows it only then.
stub sleep 'echo wait >> "$T/waits"
  [ "$(git --git-dir="$T/remote.git" rev-parse feat/7-export-csv)" = "'"$last"'" ] || echo "the branch lacks the last commit" > "$T/unpushed"
  ! grep -q "^gh pr ready" "$T/calls" || echo "marked ready before the head changed" > "$T/early"
  [ "$(wc -l < "$T/waits")" -lt 3 ] || echo "'"$last"'" > "$T/head"'
run "$scripts/hand-over.sh" 7
expect_status 0
expect_calls 3 "sleep 5"
[ ! -e "$T/unpushed" ] || fail "expected the branch to hold the last commit while the script waits"
[ ! -e "$T/early" ] || fail "expected nothing marked ready while the head was the earlier commit"
expect_calls 1 "gh pr ready 7"
[ "$(tail -n 1 "$T/calls")" = "gh pr ready 7" ] || fail "expected marking it ready to be the last call"

scenario "stops with a message, and marks nothing ready, when the head never changes"
branch
run "$scripts/hand-over.sh" 7
expect_status 1
expect_calls 18 "sleep 5"
expect_output "After 90 seconds GitHub still reports $earlier as the head of pull request #7, not the last commit, $last."
expect_output "Pull request #7 was not marked ready: run hand-over.sh 7 again."
expect_no_call "gh pr ready"

scenario "run again after the head changed, pushes nothing new and marks it ready"
branch
run "$scripts/hand-over.sh" 7
echo "$last" > "$T/head"
: > "$T/calls"
run "$scripts/hand-over.sh" 7
expect_status 0
expect_calls 1 "gh pr ready 7"
expect_no_call "sleep"

scenario "stops with a message, and asks GitHub nothing, when the push fails"
branch
git remote set-url origin "$T/missing.git"
run "$scripts/hand-over.sh" 7
expect_status 1
expect_output "The push failed. Pull request #7 was not marked ready"
expect_no_call "gh"

scenario "stops with a message, and marks nothing ready, when the head cannot be read"
branch
stub gh 'echo "gh: HTTP 502" >&2; exit 1'
run "$scripts/hand-over.sh" 7
expect_status 1
expect_output "The head of pull request #7 could not be read from GitHub. Pull request #7 was not marked ready"
expect_no_call "gh pr ready"
expect_no_call "sleep"

scenario "stops with a message when GitHub refuses to mark it ready"
branch
echo "$last" > "$T/head"
: > "$T/refuses"
run "$scripts/hand-over.sh" 7
expect_status 1
expect_output "GitHub refused to mark it ready. Pull request #7 was not marked ready: run hand-over.sh 7 again."

scenario "stops with its usage when no pull request is named"
branch
run "$scripts/hand-over.sh"
expect_status 1
expect_output "Usage: hand-over.sh <pr-number>"
expect_no_call "gh"
