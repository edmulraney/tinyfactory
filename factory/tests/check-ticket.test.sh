#!/usr/bin/env bash
# Tests for factory/scripts/check-ticket.sh, the gate before an agent may start.
. "$(dirname "$0")/helpers.sh"

# ticket <label> <body>: the issue gh answers with, under the title in $name, opened at the time in $opened.
name="Export forecast as CSV"
opened="2026-11-18T00:00:00Z"
ticket() {
  jq -n --arg title "$name" --arg label "$1" --arg body "$2" --arg opened "$opened" \
    '{title: $title, body: $body, labels: [{name: $label}, {name: "ready"}], createdAt: $opened}' > "$T/issue.json"
  stub gh 'case "$*" in
    "issue view 12 --json title,body,labels,createdAt") cat "$T/issue.json" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
factory_body="## Change
Add a check.

## How we will know it works
Lint fails on a stray file."

criteria='## Acceptance criteria
- **AC1:** Given a forecast, when I press Export, then a CSV downloads.

## Docs to update
None.'

scenario "passes a complete initiative"
ticket initiative "## Problem
Runners cannot share a forecast.

## Hypothesis
They will export it.

## Success metric
One export a week.

## Scope
The export button.

$criteria"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "passes a complete bug"
ticket bug "## What happens
The page is blank.

## What should happen
It shows the forecast.

## Steps to reproduce
Open it.

$criteria"
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "passes a complete tweak"
ticket tweak "## Change
Rename the button.

$criteria"
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "passes a chore, which needs no acceptance criteria"
ticket chore "## Change
Rename a module.

## Docs to update
None."
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "passes a factory ticket that says how it will be proven"
ticket factory "## Change
Add a check.

## How we will know it works
Lint fails on a stray file."
run "$scripts/check-ticket.sh" 12
expect_status 0

research_body='## Question
What goes wrong for a runner with a job who trains for a first marathon?

## What to read
Public running forums. Nothing behind a login.

## Output
Five profiles in `product/research/`, and signals in `product/signals.md`.

## Checks
- 5 files `product/research/*-profile.md`, each with `## Situation` and `## Sources`
- `product/signals.md`'

scenario "passes a research ticket written from its template"
ticket research "$research_body"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "the research template's own example checks are ones a script can run, and its empty sections are refused"
ticket research "$(awk 'dashes == 2; /^---$/ {dashes++}' "$root/.github/ISSUE_TEMPLATE/research.md")"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Question" is missing or empty.'
expect_no_output '"## Checks"'
expect_no_output "No check a script can run"

scenario "refuses a research ticket missing a section"
replace_first "$research_body" "## What to read
Public running forums. Nothing behind a login.
" ""
ticket research "$replaced"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## What to read" is missing or empty.'
expect_no_output '"## Question"'

scenario "refuses a research ticket whose checks name no file under product/ for a script to look at"
replace_first "$research_body" '- 5 files `product/research/*-profile.md`, each with `## Situation` and `## Sources`
- `product/signals.md`' '- Five profiles exist, each listing its sources.
- `apps/web/README.md`'
ticket research "$replaced"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output '- No script can run the check "- Five profiles exist, each listing its sources."'
expect_output '- No script can run the check "- `apps/web/README.md`"'

scenario "refuses a research ticket with one check a script can run beside one it cannot"
for unrunnable in '- Each profile cites its sources.' '- `product/../CLAUDE.md`' '- 0 files `product/research/x.md`'; do
  replace_first "$research_body" '- `product/signals.md`' "- \`product/signals.md\`
$unrunnable"
  ticket research "$replaced"
  run "$scripts/check-ticket.sh" 12
  expect_status 1
  expect_output "- No script can run the check \"$unrunnable\""
  expect_no_output "5 files"
done

scenario "refuses a research ticket whose checks hold no list line"
replace_first "$research_body" '- 5 files `product/research/*-profile.md`, each with `## Situation` and `## Sources`
- `product/signals.md`' 'The profiles in `product/research/` read well.'
ticket research "$replaced"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "No check a script can run"

scenario "reads a description written with Windows line endings"
ticket factory $'## Change\r\nAdd a check.\r\n\r\n## How we will know it works\r\nLint fails.\r\n'
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "refuses a ticket with no type label"
ticket question "## Change
Something."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "No ticket type"

scenario "names the six types to a ticket with none"
ticket question "$factory_body"
jq '.labels += [{name: "proposal"}, {name: "needs-human"}]' "$T/issue.json" > "$T/more.json" && mv "$T/more.json" "$T/issue.json"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "- No ticket type. Add one of the labels: initiative, bug, tweak, chore, research, factory."
expect_no_output "Section"

scenario "refuses a ticket with two type labels, says which, and checks it against neither template"
ticket chore "## Change
Rename a module."
jq '.labels += [{name: "bug"}]' "$T/issue.json" > "$T/both.json" && mv "$T/both.json" "$T/issue.json"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "- More than one ticket type: bug, chore. Keep one of the labels: initiative, bug, tweak, chore, research, factory."
expect_no_output "Section"
expect_no_output "No ticket type"

scenario "passes a proposal, whose second label is not a type"
ticket factory "$factory_body"
jq '.labels += [{name: "proposal"}]' "$T/issue.json" > "$T/both.json" && mv "$T/both.json" "$T/issue.json"
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "refuses a proof ticket as nothing to build, and does not ask for a type"
name="Confirm the next retro proposal passes the ticket check"
ticket proof "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "has nothing to build"
expect_no_output "No ticket type"
expect_no_output "Section"

scenario "refuses a proof ticket that also carries a type"
ticket proof "$factory_body"
jq '.labels += [{name: "factory"}]' "$T/issue.json" > "$T/both.json" && mv "$T/both.json" "$T/issue.json"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "has nothing to build"
name="Export forecast as CSV"

scenario "names a section that is missing"
ticket tweak "## Change
Rename the button.

## Acceptance criteria
- **AC1:** Given a button, then it is renamed."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Docs to update" is missing or empty.'
expect_no_output '"## Change"'

scenario "treats a section that holds only the template's comment as empty"
ticket factory "## Change
<!-- What should change, and why. -->

## How we will know it works
Lint fails."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Change" is missing or empty.'

scenario "does not take the next section's text for an empty one"
ticket factory "## Change

## How we will know it works
Lint fails."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Change" is missing or empty.'

scenario "refuses acceptance criteria that are not numbered"
ticket tweak "## Change
Rename the button.

## Acceptance criteria
- The button is renamed.

## Docs to update
None."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "No numbered acceptance criteria"

scenario "refuses a factory ticket with no way to know it works"
ticket factory "## Change
Add a check."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## How we will know it works" is missing or empty.'


scenario "passes the title \"Add a ticket queue\""
name="Add a ticket queue"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "passes a title of exactly 60 characters"
name="Move the factory tests from pnpm lint to pnpm test for a run"
[ "${#name}" -eq 60 ] || fail "the test's own title is ${#name} characters, not 60"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "refuses a title of 61 characters, and says how long it is"
name="Move the factory tests from pnpm lint to pnpm test for 2 runs"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "is 61 characters long, and the limit is 60"
expect_no_output "colon"
expect_no_output "comma"
expect_no_output "full stop"
expect_no_output "capital"

scenario "refuses a title with a colon"
name="A queue: line up tickets"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'The title "A queue: line up tickets" has a colon.'
expect_no_output "comma"

scenario "refuses a title with a comma"
name="Factory tests run in pnpm test, where a person looks"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "has a comma."
expect_no_output "colon"

scenario "refuses a title that ends in a full stop"
name="Add a ticket queue."
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "ends in a full stop."

scenario "passes a title with a full stop inside it"
name="Run ship.sh once per merge"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "refuses a title that does not start with a capital letter"
name="add a ticket queue"
ticket factory "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "does not start with a capital letter."

scenario "names every rule a title breaks, and the sections that are missing too"
name="a queue: line up tickets, one at a time."
ticket factory "## Change
Add a check."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "has a colon."
expect_output "has a comma."
expect_output "ends in a full stop."
expect_output "does not start with a capital letter."
expect_output 'Section "## How we will know it works" is missing or empty.'

scenario "names the title's problem on a ticket with no type label"
name="add a ticket queue"
ticket question "$factory_body"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "does not start with a capital letter."
expect_output "No ticket type"


# change_of <n>: a factory ticket whose "Change" section holds n words, for its limit (decisions T173a, T173b).
change_of() {
  printf '## Change\n%s\n\n## How we will know it works\nLint fails on a stray file.\n' \
    "$(yes word | head -n "$1" | tr '\n' ' ')"
}
name="Add a ticket queue"

scenario "passes a \"Change\" section of exactly 120 words"
ticket factory "$(change_of 120)"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "refuses a \"Change\" section of 121 words, and says how long it is"
ticket factory "$(change_of 121)"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Change" is 121 words long, and the limit is 120.'

scenario "counts the words of a tweak and of a chore as well"
replace_first "$(change_of 121)" "## How we will know it works
Lint fails on a stray file." "$criteria"
ticket tweak "$replaced"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "is 121 words long"
replace_first "$(change_of 130)" "## How we will know it works
Lint fails on a stray file." "## Docs to update
None."
ticket chore "$replaced"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "is 130 words long"

scenario "does not count the template's comment, or the words of another section"
replace_first "$(change_of 120)" "## Change" "## Change
<!-- What should be different in how the factory works, and why, in 120 words at most. -->"
ticket factory "$replaced and here is how it will be proven, at some length, with more words than one."
run "$scripts/check-ticket.sh" 12
expect_status 0

scenario "does not check a ticket opened before the limit began"
opened="2026-11-17T23:59:59Z"
ticket factory "$(change_of 500)"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "still refuses an empty \"Change\" section on a ticket opened before the limit began"
ticket factory "## Change

## How we will know it works
Lint fails."
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## Change" is missing or empty.'
opened="2026-11-18T00:00:00Z"

scenario "checks a ticket whose opening time GitHub did not give"
ticket factory "$(change_of 121)"
jq 'del(.createdAt)' "$T/issue.json" > "$T/undated.json" && mv "$T/undated.json" "$T/issue.json"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output "is 121 words long"

scenario "stops when GitHub cannot be read, and does not call the ticket good or bad"
stub gh 'echo "gh: could not connect" >&2; exit 1'
run "$scripts/check-ticket.sh" 12
expect_failure
expect_output "gh: could not connect"
expect_no_output "Section"
expect_no_output "No ticket type"
expect_no_output "The title"
