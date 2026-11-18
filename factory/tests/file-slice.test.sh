#!/usr/bin/env bash
# Tests for factory/scripts/file-slice.sh, which files one slice of an idea as an unstarted ticket.
. "$(dirname "$0")/helpers.sh"

title="Choose your race with no account"
# slice: a tweak's body that follows its template, in slice.md; GitHub files it as issue 41.
slice() {
  printf '%s\n' "## Change" "A runner picks a race before signing in." "" "After #40" "" \
    "## Acceptance criteria" "- **AC1:** Given the home page, when I type a race, then I see its date." "" \
    "## Docs to update" "None." > slice.md
  stub gh 'case "$*" in
    "issue create "*) echo "https://github.com/owner/myapp/issues/41" ;;
    "issue comment "*) echo "https://github.com/owner/myapp/issues/7#issuecomment-1" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}

scenario "files a slice with its type as the only label, so it carries no ready, and prints its number"
slice
run "$scripts/file-slice.sh" 7 tweak "$title" slice.md
expect_status 0
[ "$out" = 41 ] || fail "expected it to print 41 and nothing else"
expect_call "gh issue create --title $title --label tweak --body-file slice.md"
expect_no_call "ready"
expect_call "gh issue comment 7 --body Filed #41: $title"
[ "$(wc -l < "$T/calls")" -eq 2 ] || fail "expected two calls to GitHub and no other"

scenario "refuses an idea that is not a number, and files nothing"
slice
run "$scripts/file-slice.sh" "7 --repo other/repo" tweak "$title" slice.md
expect_status 1
expect_output "is not an idea's number."
expect_no_call "gh"

scenario "refuses ready as the type, and files nothing"
slice
run "$scripts/file-slice.sh" 7 ready "$title" slice.md
expect_status 1
expect_output "No ticket type"
expect_no_call "gh issue create"

scenario "refuses a type that would add a second label, and files nothing"
slice
for type in "tweak,ready" "tweak ready" "tweak --label ready"; do
  run "$scripts/file-slice.sh" 7 "$type" "$title" slice.md
  expect_status 1
  expect_output "\"$type\" is not a ticket type."
done
expect_no_call "gh"

scenario "does not file a slice its template refuses, and says what is wrong"
slice
printf '## Change\nA runner picks a race.\n' > slice.md
run "$scripts/file-slice.sh" 7 tweak "$title" slice.md
expect_status 1
expect_output "Not filed, because the ticket does not follow its template"
expect_output "No numbered acceptance criteria"
expect_no_call "gh issue create"

scenario "stops when the body is not a file"
slice
run "$scripts/file-slice.sh" 7 tweak "$title" missing.md
expect_status 1
expect_output "missing.md is not a file, so no ticket was filed."
expect_no_call "gh"

scenario "stops when GitHub does not file the ticket, and prints no number"
slice
stub gh 'echo "gh: could not connect" >&2; exit 1'
run "$scripts/file-slice.sh" 7 tweak "$title" slice.md
expect_status 1
expect_output "Could not file \"$title\" on GitHub."
[[ "$out" != *41* ]] || fail "expected no number"

scenario "stops when the idea cannot be told of a filed ticket, and says not to file it again"
slice
stub gh 'case "$*" in
  "issue create "*) echo "https://github.com/owner/myapp/issues/41" ;;
  *) echo "gh: could not connect" >&2; exit 1 ;;
esac'
run "$scripts/file-slice.sh" 7 tweak "$title" slice.md
expect_status 1
expect_output "Filed #41, but could not say so on idea #7. Do not file \"$title\" again."
