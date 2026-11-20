#!/usr/bin/env bash
# Tests for merge-queue.sh: which pull requests wait to merge, in which order, and what takes one out.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/group-on-github.sh"

seven=7777777777777777777777777777777777777777
eight=8888888888888888888888888888888888888888
nine=9999999999999999999999999999999999999999
export GITHUB_REPOSITORY=repo-owner/myapp

github() {
  echo '[]' > "$T/open.json"
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "workflow run merge-group.yml" | "pr edit "*" --add-label needs-human") ;;
      *) queue_on_github "$@" ;;
    esac'
  stub sleep ':'
}
# open <number> <head> [draft | sent-back | approved]
open() {
  local draft=false reviews='[]'
  case "${3:-}" in
    draft) draft=true ;;
    sent-back) reviews='[{"author":{"login":"repo-owner"},"state":"APPROVED"},{"author":{"login":"repo-owner"},"state":"CHANGES_REQUESTED"},{"author":{"login":"repo-owner"},"state":"COMMENTED"},{"author":{"login":"someone"},"state":"APPROVED"}]' ;;
    approved) reviews='[{"author":{"login":"repo-owner"},"state":"CHANGES_REQUESTED"},{"author":{"login":"repo-owner"},"state":"APPROVED"},{"author":{"login":"someone"},"state":"CHANGES_REQUESTED"}]' ;;
  esac
  jq --argjson n "$1" --arg head "$2" --argjson draft "$draft" --argjson reviews "$reviews" \
    '. + [{number: $n, headRefOid: $head, isDraft: $draft, reviews: $reviews}]' "$T/open.json" > "$T/open.new"
  mv "$T/open.new" "$T/open.json"
}
add() { run "$scripts/merge-queue.sh" add "$1" "$2"; : > "$T/calls"; }
list() { run "$scripts/merge-queue.sh" list; }

scenario "a pull request that is added waits to merge: it is told so, and merge-group.yml is started"
github
open 7 "$seven"
run "$scripts/merge-queue.sh" add 7 "$seven"
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $seven -->This pull request waits to merge at 7777777."
expect_call "gh workflow run merge-group.yml"
list
expect_status 0
[ "$out" = "7 $seven" ] || fail "expected #7 to wait at its commit, got: $out"

scenario "the pull requests are listed in the order they were added, not in the order of their numbers"
github
open 7 "$seven"; open 8 "$eight"; open 9 "$nine"
add 9 "$nine"; add 7 "$seven"; add 8 "$eight"
list
[ "$out" = "9 $nine"$'\n'"7 $seven"$'\n'"8 $eight" ] || fail "expected #9, #7, #8, got: $out"

scenario "a pull request that was never added does not wait, whatever a person writes in a comment"
github
open 7 "$seven"; open 8 "$eight"
add 8 "$eight"
echo "[{\"id\":5,\"user\":{\"login\":\"claude\"},\"body\":\"<!-- factory:merge-queue added $seven -->This pull request waits to merge.\"}]" > "$T/comments-7"
list
[ "$out" = "8 $eight" ] || fail "expected #8 alone, got: $out"

scenario "a pull request pushed to since it was added does not wait: its new commit is added when it passes"
github
open 7 "$seven"
add 7 "$seven"
echo '[]' > "$T/open.json"; open 7 "$eight"
list
expect_status 0
[ -z "$out" ] || fail "expected nothing to wait, got: $out"

scenario "a draft, and a pull request its owner has sent back since, do not wait; one approved after being sent back does"
github
open 7 "$seven" draft; open 8 "$eight" sent-back; open 9 "$nine" approved
add 7 "$seven"; add 8 "$eight"; add 9 "$nine"
list
[ "$out" = "9 $nine" ] || fail "expected #9 alone, got: $out"

scenario "a pull request that was removed waits no longer, and the comment that removed it is what its engineer reads"
github
open 7 "$seven"
add 7 "$seven"
run "$scripts/merge-queue.sh" remove 7 "$seven" "Not merged: it does not fit main."
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue removed $seven -->Not merged: it does not fit main."
list
[ -z "$out" ] || fail "expected nothing to wait, got: $out"
run "$scripts/merge-queue.sh" removed 7 "$seven"
expect_status 0
[ "$out" = "Not merged: it does not fit main." ] || fail "expected the comment without its marker, got: $out"

scenario "a pull request added again after it was removed waits again, and nothing says it was removed"
github
open 7 "$seven"
add 7 "$seven"
run "$scripts/merge-queue.sh" remove 7 "$seven" "Not merged."
add 7 "$seven"
list
[ "$out" = "7 $seven" ] || fail "expected #7 to wait again, got: $out"
run "$scripts/merge-queue.sh" removed 7 "$seven"
[ -z "$out" ] || fail "expected no removal to be reported, got: $out"

scenario "a removal at an earlier commit says nothing of the commit that is there now"
github
open 7 "$seven"
run "$scripts/merge-queue.sh" remove 7 "$seven" "Not merged."
run "$scripts/merge-queue.sh" removed 7 "$eight"
expect_status 0
[ -z "$out" ] || fail "expected no removal to be reported for another commit, got: $out"

scenario "a pull request added twice at one commit is told once, and merge-group.yml is started both times"
github
open 7 "$seven"
add 7 "$seven"
run "$scripts/merge-queue.sh" add 7 "$seven"
expect_status 0
expect_no_call "gh pr comment"
expect_call "gh workflow run merge-group.yml"

scenario "asks six times, then fails and asks a person to start the workflow, when merge-group.yml could not be started: the pull request keeps its place"
github
open 7 "$seven"
echo "workflow run merge-group.yml" > "$T/fail"
run "$scripts/merge-queue.sh" add 7 "$seven"
expect_failure
expect_first_line "gh pr comment 7 --body Start the \`merge-group\` workflow from the Actions tab: this pull request waits to merge, and that run tests and merges" "it."
expect_calls 6 "gh workflow run merge-group.yml"
expect_no_call "Approve this pull request again"
list
expect_output "7 $seven"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "says so, and starts nothing, when the pull request could not be told that it waits"
github
open 7 "$seven"
echo "pr comment 7 --body <!-- factory:merge-queue added" > "$T/fail"
run "$scripts/merge-queue.sh" add 7 "$seven"
expect_failure
expect_output "GitHub did not take the comment that makes this pull request wait to merge"
expect_no_call "gh workflow run"

scenario "says so, and adds nothing, when the pull request's comments cannot be read"
github
open 7 "$seven"
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
run "$scripts/merge-queue.sh" add 7 "$seven"
expect_failure
expect_output "whether it already waits to merge is not known"
expect_no_call "gh workflow run"

scenario "listing fails, and names no pull request, when the open pull requests cannot be read"
github
open 7 "$seven"
add 7 "$seven"
echo "pr list" > "$T/fail"
list
expect_failure
expect_output "The open pull requests could not be read from GitHub, so which of them wait to merge is not known."
expect_no_output "7 $seven"

scenario "listing fails when the comments of one pull request cannot be read: it is not taken for one that does not wait"
github
open 7 "$seven"; open 8 "$eight"
add 7 "$seven"; add 8 "$eight"
echo "api repos/{owner}/{repo}/issues/8/comments" > "$T/fail"
list
expect_failure
expect_output "The comments of pull request #8 could not be read from GitHub"
expect_no_output "7 $seven"

scenario "a removal that cannot be posted fails, and says the pull request still waits"
github
open 7 "$seven"
add 7 "$seven"
echo "pr comment" > "$T/fail"
run "$scripts/merge-queue.sh" remove 7 "$seven" "Not merged."
expect_failure
expect_output "so it still waits"

scenario "refuses a commit that is not one, which would go into a comment"
github
run "$scripts/merge-queue.sh" add 7 "abc -->"
expect_status 2
expect_no_call "gh"
