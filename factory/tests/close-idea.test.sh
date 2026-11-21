#!/usr/bin/env bash
# Tests for factory/scripts/close-idea.sh, which closes an idea once the last open slice of it has closed.
. "$(dirname "$0")/helpers.sh"

# github: ticket 41 is a slice of issue 7, an open idea whose slices are 40, 41 and 42; $T/fail holds a word of the call to fail.
github() {
  echo '{"number":41,"state":"closed","parent_issue_url":"https://api.github.com/repos/owner/myapp/issues/7"}' > "$T/slice"
  echo '{"number":7,"state":"open","labels":[{"name":"idea"}]}' > "$T/idea"
  echo '[{"number":40,"state":"closed"},{"number":41,"state":"closed"},{"number":42,"state":"closed"}]' > "$T/slices"
  : > "$T/fail"
  stub gh '
    if [ -s "$T/fail" ] && [[ "$*" == *"$(cat "$T/fail")"* ]]; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api repos/{owner}/{repo}/issues/41 "*) json "$(cat "$T/slice")" "$@" ;;
      "api repos/{owner}/{repo}/issues/7 "*) json "$(cat "$T/idea")" "$@" ;;
      "api repos/{owner}/{repo}/issues/7/sub_issues?per_page=100 --paginate "*) json "$(cat "$T/slices")" "$@" ;;
      "issue close 7") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "closes the idea when its last open slice closes"
github
run "$scripts/close-idea.sh" 41
expect_status 0
expect_call "gh issue close 7"
expect_output "closed idea #7: #41 was its last open slice"

scenario "the idea stays open while another slice of it is open"
github
echo '[{"number":40,"state":"closed"},{"number":41,"state":"closed"},{"number":42,"state":"open"}]' > "$T/slices"
run "$scripts/close-idea.sh" 41
expect_status 0
expect_output "idea #7 stays open: #42 is still open"
expect_no_call "gh issue close"

scenario "the closed slice does not hold the idea open while GitHub still lists it as open"
github
echo '[{"number":40,"state":"closed"},{"number":41,"state":"open"}]' > "$T/slices"
run "$scripts/close-idea.sh" 41
expect_status 0
expect_call "gh issue close 7"

scenario "does nothing for a ticket that is a slice of no idea"
github
echo '{"number":41,"state":"closed","parent_issue_url":null}' > "$T/slice"
run "$scripts/close-idea.sh" 41
expect_status 0
expect_output "issue #41 is a slice of no idea: nothing was closed"
[ "$(wc -l < "$T/calls")" -eq 1 ] || fail "expected one call to GitHub and no other"

scenario "does not close a parent that is not labelled idea, or an idea already closed"
github
echo '{"number":7,"state":"open","labels":[{"name":"initiative"}]}' > "$T/idea"
run "$scripts/close-idea.sh" 41
expect_status 0
expect_output "issue #7, the parent of #41, is not an open idea: nothing was closed"
echo '{"number":7,"state":"closed","labels":[{"name":"idea"}]}' > "$T/idea"
run "$scripts/close-idea.sh" 41
expect_status 0
expect_output "issue #7, the parent of #41, is not an open idea: nothing was closed"
expect_no_call "gh issue close"
expect_no_call "sub_issues"

scenario "refuses what is not an issue number, and calls nothing"
github
run "$scripts/close-idea.sh" "41 --repo other/repo"
expect_status 1
expect_output "is not an issue number."
expect_no_call "gh"

scenario "stops when the closed ticket cannot be read, and closes nothing"
github
echo "issues/41 " > "$T/fail"
run "$scripts/close-idea.sh" 41
expect_status 1
expect_output "Could not read issue #41 from GitHub, so whether it is the last slice of an idea is not known."
expect_no_call "gh issue close"

scenario "stops when the idea cannot be read, and closes nothing"
github
echo "issues/7 " > "$T/fail"
run "$scripts/close-idea.sh" 41
expect_status 1
expect_output "Could not read issue #7, the parent of #41, from GitHub, so it was not closed."
expect_no_call "gh issue close"

scenario "stops when the idea's slices cannot be read, and closes nothing"
github
echo "sub_issues" > "$T/fail"
run "$scripts/close-idea.sh" 41
expect_status 1
expect_output "Could not read the slices of idea #7 from GitHub, so it was not closed."
expect_no_call "gh issue close"

scenario "stops when GitHub does not close the idea, and says so"
github
echo "issue close" > "$T/fail"
run "$scripts/close-idea.sh" 41
expect_status 1
expect_output "Every slice of idea #7 has closed, but GitHub did not close the idea."
