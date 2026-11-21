#!/usr/bin/env bash
# Tests for factory/scripts/check-research.sh: a ticket's checks hold and its pull request changes only product/.
. "$(dirname "$0")/helpers.sh"

# ticket <label> <checks>: issue #12 with this label and these Checks lines; #7 changes the files in $T/changed.
ticket() {
  jq -n --arg label "$1" --arg body "## Question
What goes wrong?

## Checks
<!-- What a script can verify. -->
$2

## Notes
- \`product/not-a-check.md\`" '{body: $body, labels: [{name: $label}, {name: "in-progress"}]}' > "$T/issue.json"
  printf 'product/research/a-profile.md\nproduct/signals.md\n' > "$T/changed"
  stub gh 'case "$*" in
    "issue view 12 --json body,labels") cat "$T/issue.json" ;;
    "api repos/owner/myapp/pulls/7/files --paginate --jq"*) json "$(jq -R "{filename: .}" "$T/changed" | jq -s .)" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
profile() {
  local file="product/research/$1"
  shift
  mkdir -p product/research
  printf '%s\n' "# A runner" "$@" > "$file"
}
two_profiles='- 2 files `product/research/*-profile.md`, each with `## Situation` and `## Sources`
- `product/signals.md`'
check() { run env GITHUB_REPOSITORY=owner/myapp "$scripts/check-research.sh" "$@"; }

scenario "passes when every file the ticket names exists and holds the lines it asks for"
ticket research "$two_profiles"
profile a-profile.md "## Situation" "A job and two children." "## Sources" "- https://example.com/thread"
profile b-profile.md "## Sources" "## Situation"
echo "# Signals" > product/signals.md
check 12
expect_status 0
expect_output "The research output of #12 is as its ticket's checks say."
expect_no_call "gh api"

scenario "fails when fewer files match than the ticket asks for, and says how many"
ticket research "$two_profiles"
profile a-profile.md "## Situation" "## Sources"
profile notes.md "## Situation" "## Sources"
echo "# Signals" > product/signals.md
check 12
expect_status 1
expect_output '`product/research/*-profile.md` matches 1 files, and the ticket asks for 2.'

scenario "fails when a named file is missing"
ticket research "$two_profiles"
profile a-profile.md "## Situation" "## Sources"
profile b-profile.md "## Situation" "## Sources"
check 12
expect_status 1
expect_output '`product/signals.md` matches 0 files, and the ticket asks for 1.'
expect_no_output "profile.md"

scenario "names each file that lacks a line, and takes no part of a longer line for it"
ticket research "$two_profiles"
profile a-profile.md "## Situation" "## Sources"
profile b-profile.md "## Situation" "### Sources and more" "See ## Sources"
echo "# Signals" > product/signals.md
check 12
expect_status 1
expect_output 'product/research/b-profile.md has no line "## Sources".'
expect_no_output "a-profile.md"

scenario "reads a file written with Windows line endings"
ticket research '- `product/research/a-profile.md`: `## Sources`'
mkdir -p product/research
printf '## Sources\r\n- a thread\r\n' > product/research/a-profile.md
check 12
expect_status 0

scenario "finds a line at the top of a file too large to be read in one piece"
ticket research '- `product/signals.md`: `# Signals`'
mkdir -p product
{ echo "# Signals"; yes -- "- a runner said the plan left no room for a bad week" | head -n 20000; } > product/signals.md
check 12
expect_status 0

scenario "does not count a folder as a file"
ticket research '- `product/research/*`'
mkdir -p product/research/empty
check 12
expect_status 1
expect_output 'matches 0 files'

scenario "fails a check line that names no path under product/, and one that climbs out of it"
ticket research '- Five profiles exist.
- `apps/web/package.json`
- `product/../CLAUDE.md`
- `product/$(id).md`'
check 12
expect_status 1
expect_output 'No script can run the check "- Five profiles exist."'
expect_output 'No script can run the check "- `apps/web/package.json`"'
expect_output 'No script can run the check "- `product/../CLAUDE.md`"'
expect_output 'No script can run the check "- `product/$(id).md`"'

scenario "fails a count of no files, and one too long to compare, with no file missing"
ticket research '- 0 files `product/signals.md`
- 99999999999999999999 files `product/signals.md`'
mkdir -p product && echo "# Signals" > product/signals.md
check 12
expect_status 1
expect_output 'No script can run the check "- 0 files `product/signals.md`"'
expect_output 'No script can run the check "- 99999999999999999999 files `product/signals.md`"'

scenario "with --runnable, judges check lines alone: no ticket read and no file looked for"
stub gh 'echo "unexpected call: gh $*" >&2; exit 1'
run "$scripts/check-research.sh" --runnable <<<"$two_profiles"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
run "$scripts/check-research.sh" --runnable <<<"$two_profiles
- Five profiles exist."
expect_status 1
expect_output 'No script can run the check "- Five profiles exist."'
expect_no_output "matches 0 files"
expect_no_call "gh"

scenario "fails a research ticket with no check at all"
ticket research "Read them and see."
check 12
expect_status 1
expect_output 'Issue #12 has no line under "## Checks"'

scenario "passes a ticket that is not research, and looks at nothing"
ticket tweak "$two_profiles"
check 12 7
expect_status 0
expect_output "Issue #12 is not a research ticket"
expect_no_call "gh api"

scenario "passes a pull request that changes only product/"
ticket research '- `product/signals.md`'
mkdir -p product && echo "# Signals" > product/signals.md
check 12 7
expect_status 0
expect_call "gh api repos/owner/myapp/pulls/7/files --paginate"

scenario "fails a pull request that changes a file outside product/, and names each"
ticket research '- `product/signals.md`'
mkdir -p product && echo "# Signals" > product/signals.md
printf 'product/signals.md\napps/web/src/app/page.tsx\nfactory/scripts/ship.sh\nproduct-notes.md\n' > "$T/changed"
check 12 7
expect_status 1
expect_output "Pull request #7 changes apps/web/src/app/page.tsx. A research ticket's pull request changes only files under product/."
expect_output "Pull request #7 changes factory/scripts/ship.sh."
expect_output "Pull request #7 changes product-notes.md."
expect_no_output "changes product/signals.md"
expect_no_output "is as its ticket's checks say"

scenario "counts the old name of a file moved into product/"
ticket research '- `product/signals.md`'
mkdir -p product && echo "# Signals" > product/signals.md
stub gh 'case "$*" in
  "issue view 12 --json body,labels") cat "$T/issue.json" ;;
  "api repos/owner/myapp/pulls/7/files --paginate --jq"*) json "[{\"filename\":\"product/purpose.md\",\"previous_filename\":\"PURPOSE.md\"}]" "$@" ;;
  *) echo "unexpected call: gh $*" >&2; exit 1 ;;
esac'
check 12 7
expect_status 1
expect_output "Pull request #7 changes PURPOSE.md."

scenario "stops when the ticket cannot be read, and does not call the research good"
stub gh 'echo "gh: could not connect" >&2; exit 1'
check 12 7
expect_failure
expect_output "Could not read issue #12 from GitHub"
expect_no_output "is as its ticket's checks say"
expect_no_output "not a research ticket"

scenario "stops when the pull request's files cannot be read, and does not call the research good"
ticket research '- `product/signals.md`'
mkdir -p product && echo "# Signals" > product/signals.md
stub gh 'case "$*" in
  "issue view 12 --json body,labels") cat "$T/issue.json" ;;
  *) echo "gh: could not connect" >&2; exit 1 ;;
esac'
check 12 7
expect_failure
expect_output "Could not read the files pull request #7 changes from GitHub"
expect_no_output "is as its ticket's checks say"
