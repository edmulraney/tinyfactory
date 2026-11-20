#!/usr/bin/env bash
# Tests for factory/scripts/check-pr-conventions.sh: a pull request's title, branch and description.
. "$(dirname "$0")/helpers.sh"

title="feat: export forecast as CSV"
branch="feat/12-export-forecast-csv"
short='Closes #12

The forecast page has an export button; the file is built in the browser, so no new route.

Differs from the ticket: the file is named after the race, not the date.
Needs from the owner after merging: nothing to set up, but the old export link in the newsletter now redirects.'
# The seven sections that came before.
good='Closes #12

## What changed
The forecast exports as CSV.

## Why
Runners asked for it.

## Docs updated
- `ARCHITECTURE.md`: the export module.

## How it was verified
`pnpm test` passed.

## Not proven
Nothing

## After merging
Nothing

## Notes for the reviewer
Read the export module first.'

# branch_changing <file>...: GitHub has #40 open, #41 closed, #42 a pull request, #43 unreadable.
branch_changing() {
  local file
  git init -q -b main .
  echo "# myapp" > README.md
  git add . && git commit -qm "chore: start"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b "$branch"
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    echo "changed" > "$file"
  done
  git add . && git commit -qm "feat: the work" --allow-empty
  tickets
}
tickets() {
  stub gh 'case "$*" in
    "api repos/{owner}/{repo}/issues/40 "*) json "{\"state\":\"open\"}" "$@" ;;
    "api repos/{owner}/{repo}/issues/41 "*) json "{\"state\":\"closed\"}" "$@" ;;
    "api repos/{owner}/{repo}/issues/42 "*) json "{\"state\":\"open\",\"pull_request\":{\"url\":\"x\"}}" "$@" ;;
    "api repos/{owner}/{repo}/issues/43 "*) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
    "api repos/{owner}/{repo}/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    "api graphql "*" number=12 "*) json "{\"data\":{\"repository\":{\"issue\":{\"lastEditedAt\":$(cat "$T/edited" 2>/dev/null || echo null)}}}}" "$@" ;;
    "pr view 34 --json body,closingIssuesReferences "*) json "$(cat "$T/pr.json")" "$@" ;;
    "api repos/{owner}/{repo}/pulls/34/files "*) json "$(cat "$T/pr-files.json")" "$@" ;;
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
# refuses <message>: the check fails, saying this, and does not also say all is well.
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
expect_no_output "comma"
expect_no_output "colon"
expect_no_output "full stop"

scenario "refuses a summary with a comma"
run "$scripts/check-pr-conventions.sh" "feat: export forecast as CSV, with headers" "$branch"
expect_status 1
expect_output "has a comma."

scenario "refuses a summary with a second colon"
run "$scripts/check-pr-conventions.sh" "feat: export: forecast as CSV" "$branch"
expect_status 1
expect_output "has a second colon."

scenario "refuses a summary that ends in a full stop"
run "$scripts/check-pr-conventions.sh" "feat: export forecast as CSV." "$branch"
expect_status 1
expect_output "ends in a full stop."

scenario "accepts a summary with a full stop inside it"
run "$scripts/check-pr-conventions.sh" "fix: run ship.sh once per merge" "$branch"
expect_status 0

scenario "says only that the type is missing when a title has none"
run "$scripts/check-pr-conventions.sh" "Export forecast, as CSV." "$branch"
expect_status 1
expect_output "must look like"
expect_no_output "comma"
expect_no_output "full stop"

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
branch_changing ARCHITECTURE.md apps/web/src/lib/export.ts
printf '%s\n' "$good" > "$T/description.md"
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

scenario "refuses a list in the paragraph"
check 'Closes #12

- pnpm test passed
- pnpm lint passed'
refuses "The paragraph on what changed holds a list."

scenario "refuses a labelled line with nothing to say"
for empty in "" " Nothing" " None." " n/a"; do
  check "Closes #12

The forecast exports as CSV.

Differs from the ticket:$empty"
  refuses '"Differs from the ticket:" has nothing to say'
  expect_output "Leave the line out."
done

scenario "refuses a labelled line that appears twice"
check "$short
Needs from the owner after merging: a new secret."
refuses '"Needs from the owner after merging:" appears twice.'

scenario "refuses the labelled lines out of order"
check 'Closes #12

The forecast exports as CSV.

Needs from the owner after merging: a new secret.
Differs from the ticket: the file is named after the race.'
refuses '"Differs from the ticket:" comes before "Needs from the owner after merging:".'

scenario "refuses an eighth heading beside the seven sections"
check "$good

## Things the merger should know
Re-run board.sh."
refuses 'The description has headings, and its shape has none:'
expect_output '"## Things the merger should know"'
expect_output '"Closes #<n>", a blank line, one paragraph of 50 words at most'
expect_no_call "gh api repos"

scenario "refuses a heading in the short shape"
replace_first "$short" 'Differs from the ticket' '## Notes
Differs from the ticket'
check "$replaced"
refuses 'its shape has none: "## Notes"'

scenario "refuses the seven sections with one missing: that is neither shape"
replace_first "$good" '## Not proven
Nothing' ''
check "$replaced"
refuses 'The description has headings, and its shape has none: "## What changed"'

scenario "refuses the seven sections out of their order"
replace_first "$good" '## Not proven
Nothing

## After merging
Nothing' '## After merging
Nothing

## Not proven
Nothing'
check "$replaced"
refuses 'The description has headings, and its shape has none:'

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


scenario "passes a description in the seven sections, as a pull request open before the change holds"
branch_changing ARCHITECTURE.md apps/web/src/lib/export.ts
check "$good"
passes

scenario "passes the seven sections written with Windows line endings"
branch_changing ARCHITECTURE.md
check "${good//$line_end/$windows_line_end}"
passes

scenario "passes the seven sections with the old template's comments kept"
branch_changing ARCHITECTURE.md
replace_first "$good" 'The forecast exports as CSV.' '<!-- The change itself.
## Not a heading: it is inside a comment -->
The forecast exports as CSV.'
check "$replaced"
passes

scenario "does not read pasted output in a code fence as headings"
branch_changing ARCHITECTURE.md
replace_first "$good" '`pnpm test` passed.' '````
# a comment in a script
## To do
```
still inside the longer fence
---
````'
check "$replaced"
passes

scenario "reads a heading after a code fence has closed"
branch_changing ARCHITECTURE.md
replace_first "$good" '`pnpm test` passed.' '```
# a comment in a script
```
### Follow-ups'
check "$replaced"
refuses '"### Follow-ups"'


scenario "refuses an empty After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
<!-- Write "Nothing", or list the tickets. -->'
check "$replaced"
refuses '"## After merging" is empty'

scenario "refuses a to-do written under After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
Re-run board.sh with the owner'"'"'s login.'
check "$replaced"
refuses "This line is neither: \"Re-run board.sh with the owner's login.\""
expect_no_call "gh api repos"

scenario "refuses a sentence beside a ticket under After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #40 once the owner has run setup'
check "$replaced"
refuses "This line is neither"

scenario "passes an open ticket listed under After merging, having looked it up"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #40'
check "$replaced"
passes
expect_call "gh api repos/{owner}/{repo}/issues/40"

scenario "refuses a closed ticket under After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #40
- #41'
check "$replaced"
refuses '"## After merging" lists #41, which is closed'
expect_no_output "#40"

scenario "refuses a pull request listed as a ticket under After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
#42'
check "$replaced"
refuses '"## After merging" lists #42, which is a pull request'

scenario "refuses a ticket that does not exist under After merging"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #999'
check "$replaced"
refuses '"## After merging" lists #999, which does not exist'

scenario "stops when a ticket cannot be looked up: that is not a ticket that does not exist"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #43'
check "$replaced"
refuses 'Could not look up ticket #43, so "## After merging" was not checked'
expect_output "HTTP 502"
expect_no_output "does not exist"

scenario "refuses a listed ticket that the pull request itself closes"
branch_changing ARCHITECTURE.md
replace_first "$good" '## After merging
Nothing' '## After merging
- #12'
check "$replaced"
refuses '"## After merging" lists #12, a ticket this pull request closes when it merges'

scenario "counts every closing word in the description, not only the first"
branch_changing ARCHITECTURE.md
replace_first "$good" 'Runners asked for it.' 'Runners asked for it. This also Fixes: #40.'
also_fixes="$replaced"
replace_first "$also_fixes" '## After merging
Nothing' '## After merging
- #40'
check "$replaced"
refuses '"## After merging" lists #40, a ticket this pull request closes when it merges'


scenario "refuses an empty Docs updated"
branch_changing ARCHITECTURE.md
replace_first "$good" '- `ARCHITECTURE.md`: the export module.' ''
check "$replaced"
refuses '"## Docs updated" is empty'

scenario "refuses a named document the branch does not change"
branch_changing apps/web/src/lib/export.ts
check "$good"
refuses '"## Docs updated" names ARCHITECTURE.md, which this pull request does not change'

scenario "refuses a document named without its path from the repo root"
branch_changing factory/decisions.md
replace_first "$good" '`ARCHITECTURE.md`' '`decisions.md`'
check "$replaced"
refuses '"## Docs updated" names decisions.md, which this pull request does not change'

scenario "counts a changed document that is not committed yet"
branch_changing apps/web/src/lib/export.ts
echo "# myapp, with an export" > README.md
replace_first "$good" '`ARCHITECTURE.md`' 'README.md'
check "$replaced"
passes

scenario "counts a new document that git does not track yet"
branch_changing apps/web/src/lib/export.ts
echo "the export module" > ARCHITECTURE.md
check "$good"
passes

scenario "refuses None needed without a reason"
branch_changing apps/web/src/lib/export.ts
replace_first "$good" '- `ARCHITECTURE.md`: the export module.' 'None needed'
check "$replaced"
refuses '"## Docs updated" says "None needed" without a reason'

scenario "passes None needed with a reason"
branch_changing apps/web/src/lib/export.ts
replace_first "$good" '- `ARCHITECTURE.md`: the export module.' 'None needed: no document describes the button.'
check "$replaced"
passes

scenario "refuses a line under Docs updated that is neither a document nor a reason"
branch_changing ARCHITECTURE.md
replace_first "$good" '- `ARCHITECTURE.md`: the export module.' 'The docs are fine.'
check "$replaced"
refuses 'holds a line that is neither a document nor a reason: "The docs are fine."'

scenario "refuses a change to the factory that touches none of the documents that describe it"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh
check "$good"
refuses "This pull request changes the factory and none of the documents that describe it"

scenario "refuses a change to a skill that touches none of the documents that describe the factory"
branch_changing ARCHITECTURE.md .claude/skills/implement/SKILL.md
check "$good"
refuses "This pull request changes the factory and none of the documents that describe it"

scenario "passes a change to the factory that changes one of its documents"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh factory/decisions.md
check "$good"
passes

scenario "passes a change to the factory whose only document is the owner's guide"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh factory/owner-guide.md
check "$good"
passes

scenario "passes a change to the factory whose only document is its ticket's decision rows"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh factory/decisions/62.md
check "$good"
passes

scenario "passes a change to the factory whose only document is its ticket's free-tier entry"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh factory/free-tier/62.md
check "$good"
passes

scenario "passes a change to the factory whose only document is an entry of a list of the README"
branch_changing ARCHITECTURE.md factory/scripts/ship.sh factory/README/known-gaps/previews.md
check "$good"
passes

scenario "passes a change to the factory that gives a reason for changing no document"
branch_changing factory/scripts/ship.sh
replace_first "$good" '- `ARCHITECTURE.md`: the export module.' 'None needed: the script does what its documents already say.'
check "$replaced"
passes


scenario "stops when main cannot be compared with: that is not a branch that changes nothing"
branch_changing ARCHITECTURE.md
git update-ref -d refs/remotes/origin/main
check "$good"
refuses "Could not list what this branch changes since origin/main"
expect_output "git fetch origin main"

scenario "compares with the base branch a workflow names"
branch_changing ARCHITECTURE.md
git update-ref refs/remotes/origin/release HEAD
printf '%s\n' "$good" > "$T/description.md"
run env GITHUB_BASE_REF=release "$scripts/check-pr-conventions.sh" "$title" "$branch" "$T/description.md"
refuses "This branch changes nothing since origin/release"

scenario "stops on a branch that changes nothing"
branch_changing
check "$good"
refuses "This branch changes nothing since origin/main"

scenario "stops when the third argument is neither a pull request number nor a file"
branch_changing ARCHITECTURE.md
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

scenario "fails the seven sections too when the ticket was edited"
built 2026-11-17T20:31:48Z 2026-11-17T20:37:04Z 2026-11-17T20:34:00Z
echo changed > ARCHITECTURE.md
check "$good"
refuses "$reported"

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


# open_pr <description> <closing ticket numbers as JSON> <changed file>...
open_pr() {
  jq -n --arg body "$1" --argjson closes "$2" '{body: $body, closingIssuesReferences: ($closes | map({number: .}))}' > "$T/pr.json"
  shift 2
  printf '%s\n' "$@" | jq -R '{filename: .}' | jq -s . > "$T/pr-files.json"
  tickets
}

scenario "passes an open pull request in the short shape, reading only its description from GitHub"
open_pr "$short" '[12]' ARCHITECTURE.md
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
passes
expect_call "gh pr view 34 --json body,closingIssuesReferences"
expect_no_call "gh api"

scenario "refuses an open pull request whose description is too long"
open_pr "Closes #12

$(printf 'word %.0s' {1..51})" '[12]' ARCHITECTURE.md
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "The paragraph on what changed is 51 words long"

scenario "passes an open pull request in the seven sections, reading its description and files from GitHub"
open_pr "$good" '[12]' ARCHITECTURE.md apps/web/src/lib/export.ts
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
passes
expect_call "gh pr view 34 --json body,closingIssuesReferences"
expect_call "gh api repos/{owner}/{repo}/pulls/34/files --paginate"

scenario "judges an open pull request's Docs updated by the files GitHub lists"
open_pr "$good" '[12]' apps/web/src/lib/export.ts
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses '"## Docs updated" names ARCHITECTURE.md, which this pull request does not change'

scenario "refuses a listed ticket that GitHub says the merge will close, however it was linked"
replace_first "$good" '## After merging
Nothing' '## After merging
- #40'
open_pr "$replaced" '[12, 40]' ARCHITECTURE.md
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses '"## After merging" lists #40, a ticket this pull request closes when it merges'

scenario "passes an open pull request with no description's closing line"
replace_first "$good" 'Closes #12' ''
open_pr "$replaced" '[]' ARCHITECTURE.md
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
passes

scenario "refuses an open pull request with an empty description"
open_pr "" '[]' ARCHITECTURE.md
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "The description does not say what changed."

scenario "stops when the description cannot be read from GitHub"
stub gh 'echo "gh: could not connect" >&2; exit 1'
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "Could not read the description of pull request #34 from GitHub, so it was not checked."

scenario "stops when the changed files cannot be read from GitHub: that is not a pull request that changes nothing"
open_pr "$good" '[12]' ARCHITECTURE.md
stub gh 'case "$*" in
  "pr view 34 "*) json "$(cat "$T/pr.json")" "$@" ;;
  *) echo "gh: could not connect" >&2; exit 1 ;;
esac'
run "$scripts/check-pr-conventions.sh" "$title" "$branch" 34
refuses "Could not read the files pull request #34 changes from GitHub, so its description was not checked."
expect_no_output "which this pull request does not change"
