#!/usr/bin/env bash
# Tests for factory/scripts/check-pr-conventions.sh: a pull request's title, branch and description.
. "$(dirname "$0")/helpers.sh"

title="feat: export forecast as CSV"
branch="feat/12-export-forecast-csv"
short='Closes #12

The forecast page has an export button; the file is built in the browser, so no new route.

Differs from the ticket: the file is named after the race, not the date.
Needs from the owner after merging: nothing to set up, but the old export link in the newsletter now redirects.'
tickets() {
  stub gh 'case "$*" in
    "api graphql "*" number=12 "*) json "{\"data\":{\"repository\":{\"issue\":{\"lastEditedAt\":$(cat "$T/edited" 2>/dev/null || echo null)}}}}" "$@" ;;
    "pr view 34 --json body "*) json "$(cat "$T/pr.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
# check <description>: the engineer's check before the pull request exists, on a file.
check() {
  printf '%s\n' "$1" > "$T/description.md"
  run "$scripts/check-pr-conventions.sh" "$title" "$branch" "$T/description.md"
}
passes() {
  expect_status 0
  expect_output "pull request conventions ok"
}
refuses() {
  expect_status 1
  expect_output "$1"
  expect_no_output "pull request conventions ok"
}


scenario "checks only the title and the branch when given no description, and says so"
run "$scripts/check-pr-conventions.sh" "$title" "$branch"
expect_status 0
expect_output "The description was not checked"
expect_no_call "gh"

for bad in "Export forecast as CSV" "feature: export forecast" "feat:export forecast" "feat: " "Feat: export forecast"; do
  scenario "refuses the title \"$bad\""
  run "$scripts/check-pr-conventions.sh" "$bad" "$branch"
  expect_status 1
  expect_output "PR title \"$bad\" must look like"
done

for ok in "fix: show the forecast" "chore: rename a module" "docs: say why" "refactor: split the table" "test: cover the export" "ci: cache pnpm"; do
  scenario "accepts the title \"$ok\""
  run "$scripts/check-pr-conventions.sh" "$ok" "$branch"
  expect_status 0
done

scenario "accepts a title of exactly 72 characters"
long="feat: export the forecast as CSV from the forecast page for every runner"
[ "${#long}" -eq 72 ] || fail "the test's own title is ${#long} characters, not 72"
run "$scripts/check-pr-conventions.sh" "$long" "$branch"
expect_status 0

scenario "refuses a title of 73 characters, and says how long it is"
run "$scripts/check-pr-conventions.sh" "feat: export the forecast as CSV from the forecast page for every runner2" "$branch"
expect_status 1
expect_output "is 73 characters long, and the limit is 72"

scenario "accepts a summary with a comma, a second colon and a full stop at the end, as a ticket's title may hold"
run "$scripts/check-pr-conventions.sh" "feat: export: forecast as CSV, with headers." "$branch"
expect_status 0

scenario "says only that the type is missing when a title has none"
run "$scripts/check-pr-conventions.sh" "Export forecast, as CSV." "$branch"
expect_status 1
expect_output "must look like"

for bad in "export-forecast-csv" "feat/12-Export-CSV" "feat/12_export_csv" "feature/12-export-csv" "feat/12-" "feat/"; do
  scenario "refuses the branch \"$bad\""
  run "$scripts/check-pr-conventions.sh" "$title" "$bad"
  expect_status 1
  expect_output "Branch \"$bad\" must look like"
done

scenario "accepts a branch for work with no issue"
run "$scripts/check-pr-conventions.sh" "$title" "docs/readme-front-door"
expect_status 0

scenario "still fails on a bad title when the description is good"
tickets
printf '%s\n' "$short" > "$T/description.md"
run "$scripts/check-pr-conventions.sh" "Export forecast" "$branch" "$T/description.md"
expect_status 1
expect_output "PR title"


scenario "passes the whole shape, on a file, asking GitHub only when its ticket was edited"
tickets
check "$short"
passes
expect_call "gh api graphql"
expect_no_output "Ticket #12"
[ "$(wc -l < "$T/calls")" -eq 1 ] || fail "expected one call to GitHub"

scenario "passes a paragraph alone: a line with nothing to say is left out"
check 'Closes #12

The forecast exports as CSV from a button on the forecast page.'
passes

scenario "passes a description with no closing line"
check 'The forecast exports as CSV from a button on the forecast page.'
passes

scenario "passes a description written with Windows line endings"
line_end=$'\n' windows_line_end=$'\r\n'
check "${short//$line_end/$windows_line_end}"
passes

scenario "passes a description that kept the template's own comments, and does not count their words"
replace_first "$short" 'The forecast page has' "<!-- $(printf 'word %.0s' {1..120})
## Not a heading: it is inside a comment -->
The forecast page has"
check "$replaced"
passes

scenario "passes a paragraph of exactly 50 words"
check "Closes #12

$(printf 'word %.0s' {1..50})"
passes

scenario "refuses a paragraph of 51 words, and says how long it is"
check "Closes #12

$(printf 'word %.0s' {1..51})"
refuses "The paragraph on what changed is 51 words long, and the limit is 50. Keep a first sentence that says what changed and stands alone"

scenario "counts a paragraph written over several lines as one"
check "Closes #12

$(printf 'word %.0s' {1..30})
$(printf 'word %.0s' {1..30})"
refuses "The paragraph on what changed is 60 words long"

scenario "refuses a second paragraph, quoting its first line once"
check 'Closes #12

The forecast exports as CSV.

It was verified with pnpm test.
And by hand.'
refuses 'This line is outside the description'"'"'s shape: "It was verified with pnpm test."'
expect_no_output "And by hand."

scenario "refuses text after the labelled lines"
check "$short
Read the export module first."
refuses 'This line is outside the description'"'"'s shape: "Read the export module first."'

scenario "refuses a description that does not say what changed"
check 'Closes #12'
refuses "The description does not say what changed. Say it in one paragraph of 50 words at most, after the closing line. Its first sentence says what changed and stands alone."

# However the closing line is written, it is not the paragraph (decisions P170d).
for closing in 'Closes #12.' 'Fixes: #12' 'Closes https://github.com/acme/myapp/issues/12' 'Resolves acme/myapp#12' 'Closes #<n>'; do
  scenario "refuses a description that is only \"$closing\""
  check "$closing"
  refuses "The description does not say what changed."
done

scenario "passes a paragraph after a closing line written as a URL"
check 'Closes https://github.com/acme/myapp/issues/12.

The forecast exports as CSV from a button on the forecast page.'
passes

scenario "counts a first line that says more than which ticket closes as the paragraph"
check 'Closes #12 by exporting the forecast as CSV from a button.'
passes

scenario "refuses a description of 100 words in all, though its paragraph is short enough"
check "Closes #12

$(printf 'word %.0s' {1..50})

Differs from the ticket: $(printf 'word %.0s' {1..44})"
refuses "The description is 100 words long, and the whole of it must be under 100."
expect_no_output "the limit is 50"

scenario "passes a description of 99 words in all"
check "Closes #12

$(printf 'word %.0s' {1..50})

Differs from the ticket: $(printf 'word %.0s' {1..43})"
passes

scenario "refuses a list of tickets"
check 'Closes #12

The forecast exports as CSV.

- #40
- #41'
refuses 'The description lists tickets ("- #40"). A pull request finishes its ticket or is not ready'
expect_output '"- #41"'
expect_no_call "gh api repos"

scenario "refuses tickets as what the owner is needed for"
check 'Closes #12

The forecast exports as CSV.

Needs from the owner after merging: #40, #41'
refuses '"Needs from the owner after merging: #40, #41" lists tickets.'

scenario "lets the paragraph mention a ticket in a sentence"
check 'Closes #12

The forecast exports as CSV, with the columns #40 settled.'
passes

scenario "refuses a heading in the short shape"
replace_first "$short" 'Differs from the ticket' '## Notes
Differs from the ticket'
check "$replaced"
refuses 'its shape has none: "## Notes"'

scenario "refuses a sub-heading"
check "$short

### Follow-ups"
refuses '"### Follow-ups"'

scenario "refuses a heading made by underlining a line"
check "$short

Follow-ups
---
Re-run board.sh."
refuses "Follow-ups (underlined with ---"

scenario "refuses a heading written as an HTML tag"
check "$short

<h3>Follow-ups</h3>"
refuses "<h3>Follow-ups</h3>"

scenario "refuses a heading inside a quote"
check "$short

> ## To do
> Re-run board.sh."
refuses '"## To do"'

scenario "refuses a heading inside a list item"
check "$short

- ## To do"
refuses '"## To do"'

scenario "lets a description quote a comment mark or a heading tag in backticks"
check 'Closes #12

A `<!--` that never closes fails, and so does an `<h2>` tag.'
passes

scenario "refuses a comment that never closes, which would hide the rest"
check 'Closes #12

<!-- The forecast exports as CSV.'
refuses 'A "<!--" in the description is never closed'


scenario "does not read pasted output in a code fence as headings"
tickets
check 'Closes #12

The forecast exports as CSV.
````
# a comment in a script
## To do
```
still inside the longer fence
---
````'
passes

scenario "reads a heading after a code fence has closed"
tickets
check 'Closes #12

The forecast exports as CSV.
```
# a comment in a script
```
### Follow-ups'
refuses '"### Follow-ups"'


scenario "stops when the third argument is neither a pull request number nor a file"
run "$scripts/check-pr-conventions.sh" "$title" "$branch" "$T/no-such-file.md"
refuses "is neither a pull request number nor a description file"


# built <first commit> <work commit> <ticket edited>: a branch whose two commits and whose ticket's edit have these times.
built() {
  git init -q -b main .
  git commit -qm "chore: start" --allow-empty
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$branch"
  GIT_COMMITTER_DATE="$1" git commit -qm "chore: start work on #12" --allow-empty
  GIT_COMMITTER_DATE="$2" git commit -qm "feat: the work" --allow-empty
  echo "\"$3\"" > "$T/edited"
  tickets
}
reported="Ticket #12 was edited at 2026-11-17T20:34:00Z, after this build began: read it again (gh issue view 12)"

scenario "fails when the ticket was edited after the build began, though the work was committed after the edit"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
check "$short"
refuses "$reported"

scenario "fails for an edit once: the next check passes"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
check "$short"
check "$short"
passes
expect_no_output "Ticket #12"

scenario "fails again for a later edit"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
check "$short"
echo '"2026-11-17T20:40:00Z"' > "$T/edited"
check "$short"
refuses "Ticket #12 was edited at 2026-11-17T20:40:00Z"

scenario "compares the times in UTC, whatever the time zone it runs in"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
printf '%s\n' "$short" > "$T/description.md"
run env TZ=Asia/Tokyo "$scripts/check-pr-conventions.sh" "$title" "$branch" "$T/description.md"
refuses "$reported"

scenario "passes a ticket last edited before the build began"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:30:00Z
check "$short"
passes
expect_no_output "Ticket #12"

scenario "says so and passes when GitHub cannot say when the ticket was edited"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
stub gh 'echo "gh: Server Error (HTTP 502)" >&2; exit 1'
check "$short"
passes
expect_output "gh: Server Error (HTTP 502)"
expect_output "Could not read from GitHub when ticket #12 was last edited, so that was not checked."

not_found="Ticket #12 was edited at 2026-11-17T20:34:00Z, and the first commit of this branch could not be found"

scenario "says so and passes when main cannot be compared with"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
git update-ref -d refs/remotes/origin/main
check "$short"
passes
expect_output "$not_found"

scenario "says so and passes on a branch with no commit of its own"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
git update-ref refs/remotes/origin/main HEAD
check "$short"
passes
expect_output "$not_found"

scenario "tells the engineer and passes when it cannot record that it did, so that it never fails twice"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
printf '%s\n' "$short" > "$T/description.md"
run env TMPDIR="$T/no-such-directory" "$scripts/check-pr-conventions.sh" "$title" "$branch" "$T/description.md"
passes
expect_output "$reported"

scenario "does not ask about a ticket when the branch names none"
tickets
printf '%s\n' "$short" > "$T/description.md"
run "$scripts/check-pr-conventions.sh" "$title" "chore/tidy-readme" "$T/description.md"
passes
expect_no_call "gh"


open_pr() {
  jq -n --arg body "$1" '{body: $body}' > "$T/pr.json"
  tickets
}

scenario "passes an open pull request in the short shape, reading only its description from GitHub"
open_pr "$short"
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
passes
expect_call "gh pr view 34 --json body"
expect_no_call "gh api"

scenario "refuses an open pull request whose description is too long"
open_pr "Closes #12

$(printf 'word %.0s' {1..51})"
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "The paragraph on what changed is 51 words long"

scenario "passes an open pull request with no description's closing line"
open_pr "The forecast exports as CSV."
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
passes

scenario "refuses an open pull request with an empty description"
open_pr ""
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "The description does not say what changed."

scenario "stops when the description cannot be read from GitHub"
stub gh 'echo "gh: could not connect" >&2; exit 1'
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "Could not read the description of pull request #34 from GitHub, so it was not checked."
