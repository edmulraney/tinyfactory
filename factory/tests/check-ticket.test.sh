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
Users cannot share a forecast.

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

scenario "refuses a criterion that gives a width in pixels, and says every test already runs at both widths"
printf '%s\n' "## Change
Fit the dashboard to a phone.

## Acceptance criteria
- **AC1:** Given I have a race, when I open my dashboard on a screen 375px wide, then I read all of it.
- **AC2:** Given I have a race, when I open my dashboard, then I see the race.
- **AC3:** Given I have a race, when my screen is 1280 pixels wide, then I see the chart beside it.
- **AC4:** Given I have a race, when I open my dashboard on a 375-pixel-wide screen, then I see the race first.

## States
No screen

## Docs to update
None." > draft.md
run "$scripts/check-ticket.sh" --draft tweak "$name" draft.md
expect_status 1
expect_output 'The criterion "- **AC1:** Given I have a race, when I open my dashboard on a screen 375px wide, then I read all of it." gives a size in pixels.'
expect_output "Every end-to-end test already runs at both supported widths, mobile and desktop"
expect_output '- **AC3:**'
expect_output '- **AC4:**'
[ "$(wc -l <<<"$out")" -eq 3 ] || fail "expected the three criteria that give a size to be its only problems, found: $out"

scenario "passes a criterion that holds a number or the letters px with no size in pixels"
printf '%s\n' "## Change
Fit the dashboard to a phone.

## Acceptance criteria
- **AC1:** Given I ran 375 km, when I open my dashboard on a phone, then I see 12 weeks of runs as a .gpx file.

## States
No screen

## Docs to update
None." > draft.md
run "$scripts/check-ticket.sh" --draft tweak "$name" draft.md
expect_status 0

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

scenario "passes a complete draft without calling GitHub"
printf '%s\n' "$factory_body" > draft.md
run "$scripts/check-ticket.sh" --draft factory "$name" draft.md
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
[ ! -s "$T/calls" ] || fail "expected no outside call"

scenario "refuses a draft with a section missing, a title too long or a type that is none of the six"
printf '## Change\nAdd a check.\n' > draft.md
run "$scripts/check-ticket.sh" --draft factory "$name, and a second clause" draft.md
expect_status 1
expect_output 'Section "## How we will know it works" is missing or empty.'
expect_output "has a comma"
run "$scripts/check-ticket.sh" --draft ready "$name" draft.md
expect_status 1
expect_output "No ticket type"

scenario "counts a draft's \"Change\" section against the limit"
change_of 121 > draft.md
run "$scripts/check-ticket.sh" --draft factory "$name" draft.md
expect_status 1
expect_output "is 121 words long"

scenario "stops when a draft's body is not a file"
run "$scripts/check-ticket.sh" --draft factory "$name" missing.md
expect_status 2
expect_output "missing.md is not a file"

# The first text of #574, which asked for a second label for what `bug` already means.
escaped_defect='## Change

A defect the owner meets in the running product starts nothing: the retro runs only on a build'"'"'s friction. The owner found that a signed-in runner was asked to sign in and could keep one race. Tickets #348 and #349 had put both out of scope, and no step asked what a runner in a left-out state sees.

When a ticket gets the label `bug` or `escaped-defect`, the retro runs on it, once. It finds the tickets and pull requests that let the defect through, names the step that should have caught it, records the lesson and proposes a change. The `ticket` skill adds `escaped-defect` to a ticket that comes from a gap met in use.

## How we will know it works

- Adding `escaped-defect` to #574 starts one retro. Its lesson names #348 and #349 and the step that should have caught the gap, and it proposes a change to the factory.
- Adding the label a second time starts nothing.
- `factory/tests/` proves both, and that a ticket with neither label starts no retro.
- The pull request states the cost and the minutes of that retro. It adds a way to start an agent, which is spend, so it waits for the owner.'
name="Run a retro on each defect the owner meets in use"

draft() {
  printf '## Change\n%s\n\n## How we will know it works\nLint fails on a stray file.\n' "$1" > draft.md
  run "$scripts/check-ticket.sh" --draft factory "$name" draft.md
}

scenario "refuses a ticket that names a label the factory lacks, and lists the labels that exist"
printf '%s\n' "$escaped_defect" > draft.md
run "$scripts/check-ticket.sh" --draft factory "$name" draft.md
expect_status 1
expect_output 'names the label `escaped-defect`, which the factory does not have'
expect_output "Its labels are: ready, needs-human, factory,"
expect_output ", proof, idea. Use one of them"
expect_output 'add the line "New label: escaped-defect. <existing label> cannot serve because <reason>"'
expect_no_output 'the label `bug`'
expect_no_output 'the label `ticket`'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected one line for a label named three times"

scenario "passes that ticket once a line says why an existing label cannot serve"
printf '%s\n\nNew label: escaped-defect. bug cannot serve because …\n' "$escaped_defect" > draft.md
run "$scripts/check-ticket.sh" --draft factory "$name" draft.md
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "refuses a new label whose line names no existing label, or gives no reason"
draft 'The retro runs on a ticket labelled `escaped-defect`.

New label: escaped-defect. defect cannot serve because it does not exist.'
expect_status 1
expect_output 'names the label `escaped-defect`'
draft 'The retro runs on a ticket labelled `escaped-defect`.

New label: escaped-defect. bug cannot serve because'
expect_status 1
expect_output 'names the label `escaped-defect`'
draft 'The retro runs on a ticket labelled `escaped-defect`.

New label: other. bug cannot serve because it is taken.'
expect_status 1
expect_output 'names the label `escaped-defect`'

scenario "passes a ticket that names only labels that exist"
draft 'A ticket labelled `bug` gets the `ready` label, with `gh issue edit 7 --add-label needs-human`. The labels `revert`, `reverted` and `deployed` stay.'
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "finds a label named before the word, in a list, and after --label or --add-label"
draft 'The `met-in-use` label starts a retro.'
expect_status 1
expect_output 'names the label `met-in-use`'
draft 'The labels `bug`, `first-new` and `second-new` start a retro.'
expect_status 1
expect_output 'names the label `first-new`'
expect_output 'names the label `second-new`'
expect_no_output 'the label `bug`'
draft 'The `bug` or `third-new` labels start a retro.'
expect_status 1
expect_output 'names the label `third-new`'
draft 'File it with `gh issue create --label factory,from-a-run --title x`.'
expect_status 1
expect_output 'names the label `from-a-run`'
expect_no_output 'the label `factory`'
draft 'Then run `gh issue edit 7 --add-label seen-twice`.'
expect_status 1
expect_output 'names the label `seen-twice`'
draft 'File it with `gh issue create --label "in-quotes"`, then `gh issue edit 7 --add-label '"'in-single-quotes'"'`.'
expect_status 1
expect_output 'names the label `in-quotes`'
expect_output 'names the label `in-single-quotes`'

scenario "does not take for a label a word away from \"label\", the subject of the verb, a placeholder or a template comment"
draft 'The `ticket` skill adds `escaped-defect` to a ticket, and `implement` labels it with `gh issue edit --add-label <type>`. Taking one off is `--remove-label gone`. <!-- the `example` label -->'
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "reads the labels of the repo it is run in when its scripts were set aside outside one"
cp -R "$scripts" "$T/aside"
mkdir -p .claude/skills/bootstrap/scripts
printf 'gh label create bug -R "$repo" --force\ngh label create met-in-use -R "$repo" --force\n' > .claude/skills/bootstrap/scripts/labels.sh
printf '## Change\nThe `met-in-use` label starts a retro, and the `ready` label does not.\n\n## How we will know it works\nLint fails.\n' > draft.md
run "$T/aside/check-ticket.sh" --draft factory "$name" draft.md
expect_status 1
expect_output 'names the label `ready`'
expect_output "Its labels are: bug, met-in-use. Use one of them"
expect_no_output 'the label `met-in-use`'

scenario "stops when the factory's labels cannot be read, and does not call the ticket good or bad"
cp -R "$scripts" "$T/aside"
printf '## Change\nThe `bug` label starts a retro.\n\n## How we will know it works\nLint fails.\n' > draft.md
run "$T/aside/check-ticket.sh" --draft factory "$name" draft.md
expect_status 2
expect_output "Could not read the factory's labels from .claude/skills/bootstrap/scripts/labels.sh"
expect_no_output "names the label"
mkdir -p .claude/skills/bootstrap/scripts
echo 'echo "no label is created here"' > .claude/skills/bootstrap/scripts/labels.sh
run "$T/aside/check-ticket.sh" --draft factory "$name" draft.md
expect_status 2
expect_output "Could not read the factory's labels"

# The body of #349 as it was filed, but for its metric, which is written as a draft is now asked to write it. It put a runner who signs in with a race already saved out of scope, and that gap shipped (#574).
name="Keep a runner's race when they sign in"
keep_race='## Problem

A race a runner chooses before signing in lives only in their browser. Myapp has no table of its own yet, so nothing about a runner is kept.

## Hypothesis

We believe that signing in straight after choosing a race, with Google or an emailed link, keeps the race with no extra step for the runner.

## Success metric

- Event: race added
- Number: at least 1 user in a week
- Date: 2026-11-30

## Scope

In: after sign-in, the race chosen in the browser is saved to the runner'"'"'s account. This is Myapp'"'"'s first table, so it brings migrations as `ARCHITECTURE.md` describes them. The signed-in home page becomes the dashboard: the race, its date, the weeks left, and a message that the prediction will appear once Myapp has the runner'"'"'s running data. A signed-in runner with no race is sent to choose one.

Out: importing data, the prediction, changing the race.

## Acceptance criteria

- **AC1:** Given I chose a race while signed out, when I sign in, then my dashboard shows that race, its date and the weeks remaining.
- **AC2:** Given I am signed in with a saved race, when I sign in from another browser, then my dashboard shows the same race.
- **AC3:** Given I am signed in and have no race, when I open the dashboard, then I am asked to choose my race.
- **AC4:** Given Myapp has none of my running data, when I open the dashboard, then it tells me my prediction will appear once Myapp has my data.

## Docs to update

`ARCHITECTURE.md`: the first table, and how a migration reaches a preview and production.

## Visual proof

The dashboard with a race and the message about the prediction.

After #348'

states() {
  printf '%s\n\n## States\n%s\n' "$keep_race" "$2" > draft.md
  run "$scripts/check-ticket.sh" --draft "$1" "$name" draft.md
}

scenario "refuses the ticket that let a gap ship, which lists no states, and says the section is missing"
printf '%s\n' "$keep_race" > draft.md
run "$scripts/check-ticket.sh" --draft initiative "$name" draft.md
expect_status 1
expect_output 'Section "## States" is missing or empty.'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected the missing section to be its only problem"

scenario "refuses a bug and a tweak with no states, and asks none of a chore or of a ticket opened before the rule"
for type in bug tweak; do
  printf '## Change\nRename the button.\n\n## What happens\nNothing.\n\n## What should happen\nA download.\n\n## Steps to reproduce\nPress it.\n\n%s\n' "$criteria" > draft.md
  run "$scripts/check-ticket.sh" --draft "$type" "$name" draft.md
  expect_status 1
  expect_output 'Section "## States" is missing or empty.'
done
printf '## Change\nRename a module.\n\n## Docs to update\nNone.\n' > draft.md
run "$scripts/check-ticket.sh" --draft chore "$name" draft.md
expect_status 0
opened="2026-11-21T23:59:59Z"
ticket initiative "$keep_race"
run "$scripts/check-ticket.sh" 12
expect_status 0
opened="2026-11-22T00:00:00Z"
ticket initiative "$keep_race"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'Section "## States" is missing or empty.'

scenario "refuses a template's own states section, whose examples are comments"
for type in initiative bug tweak; do
  states "$type" "$(awk '/^## States$/ {on = 1; next} /^## / {on = 0} on' "$root/.github/ISSUE_TEMPLATE/$type.md")"
  expect_status 1
  expect_output 'Section "## States" is missing or empty.'
  grep -q '^<!-- Example: - .*(AC1) -->$' "$root/.github/ISSUE_TEMPLATE/$type.md" || fail "expected the $type template to show a row that names a criterion"
  grep -q '^<!-- Example: - .*: unchanged -->$' "$root/.github/ISSUE_TEMPLATE/$type.md" || fail "expected the $type template to show a row that says unchanged"
done

scenario "passes a ticket whose every row names one of its criteria or says unchanged"
states initiative '<!-- One row for each state. -->
- Dashboard, signed in with a race chosen while signed out: I see that race, its date and the weeks left (AC1, AC4)
- Dashboard, signed in with a saved race: I see the saved race (AC2)
- Dashboard, signed in with no race: I am asked to choose my race (AC3)
- Sign-in page, signed out: Unchanged.'
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "passes a ticket that changes no screen with the one line \"No screen\""
for line in "No screen" "No screen." "  No screen  "; do
  states initiative "$line"
  expect_status 0
  [ -z "$out" ] || fail "expected it to print nothing"
done

scenario "refuses a row that neither names a criterion nor says unchanged"
states initiative '- Dashboard, signed in with a race: I see the race (AC1)
- Dashboard, signed in with a saved race and a new one chosen: I keep the saved race'
expect_status 1
expect_output 'The row "- Dashboard, signed in with a saved race and a new one chosen: I keep the saved race" under "## States" names no criterion and does not say "unchanged".'
expect_output 'Write each as "- <screen>, <state>: <what the person sees> (AC1)"'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected no problem with the row that names AC1"

scenario "refuses a row that names a criterion the ticket does not have"
states initiative '- Dashboard, signed in with a race: I see the race (AC1)
- Dashboard, signed in with no race: I am asked to choose one (AC5)
- Sign-in page, signed out: unchanged, as AC14 shows'
expect_status 1
expect_output 'names AC5, and the ticket has no criterion AC5.'
expect_output 'names AC14, and the ticket has no criterion AC14.'
[ "$(wc -l <<<"$out")" -eq 2 ] || fail "expected one line for each criterion the ticket lacks, and none for AC1"

scenario "refuses a line that is no row, and \"No screen\" beside rows"
states initiative 'The dashboard changes for everyone.
- Dashboard, signed in with a race: I see the race (AC1)'
expect_status 1
expect_output 'The line "The dashboard changes for everyone." under "## States" is not a row.'
states initiative 'No screen
- Dashboard, signed in with a race: I keep the saved race'
expect_status 1
expect_output 'The line "No screen" under "## States" is not a row.'
expect_output 'names no criterion and does not say "unchanged"'

# metric <lines>: a draft of the initiative with those lines under "Success metric", and its states.
metric() {
  replace_first "$keep_race" "$complete" "$1"
  printf '%s\n\n## States\nNo screen\n' "$replaced" > draft.md
  run "$scripts/check-ticket.sh" --draft initiative "$name" draft.md
}
complete="- Event: race added
- Number: at least 1 user in a week
- Date: 2026-11-30"
free_text="The owner chooses a race, signs in, and sees the same race on his dashboard from a second browser. We look when this merges."

scenario "passes an initiative whose metric names the event, the number and the date"
for number in "at least 5 users in a week" "at least 1 user in a week" "at least 20 times in a week."; do
  metric "- Event: race added
- Number: $number
- Date: 2026-12-20"
  expect_status 0
  [ -z "$out" ] || fail "expected it to print nothing for the number \"$number\""
done

scenario "refuses a metric that lacks the event, the number or the date, and names only what is missing"
metric "- Number: at least 5 users in a week
- Date: 2026-12-20"
expect_status 1
expect_output '"## Success metric" names no event. Write the line "- Event: <an event the product records>".'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected the event to be its only problem"
metric "- Event: race added
- Date: 2026-12-20"
expect_status 1
expect_output '"## Success metric" names no number a script can read. Write the line "- Number: at least <n> users in a week" or "- Number: at least <n> times in a week".'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected the number to be its only problem"
metric "- Event: race added
- Number: at least 5 users in a week"
expect_status 1
expect_output '"## Success metric" names no date to look. Write the line "- Date: <YYYY-MM-DD>".'
[ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected the date to be its only problem"

scenario "refuses a metric in free text, and a number or a date no script can read"
metric "$free_text"
expect_status 1
expect_output 'names no event.'
expect_output 'names no number a script can read.'
expect_output 'names no date to look.'
metric "- Event: race added
- Number: most users add a race
- Date: when this merges"
expect_status 1
expect_no_output 'names no event.'
expect_output 'names no number a script can read.'
expect_output 'names no date to look.'
metric "- Event: race added
- Number: at least 5 runners in a week
- Date: 2026-12-20"
expect_status 1
expect_output 'names no number a script can read.'

scenario "refuses the template's own metric section as empty, and shows each line in an example"
metric "$(awk '/^## Success metric$/ {on = 1; next} /^## / {on = 0} on' "$root/.github/ISSUE_TEMPLATE/initiative.md")"
expect_status 1
expect_output 'Section "## Success metric" is missing or empty.'
expect_no_output 'names no'
for line in "Event: race added" "Number: at least 5 users in a week" "Date: 2026-12-20"; do
  grep -qxF "<!-- Example: - $line -->" "$root/.github/ISSUE_TEMPLATE/initiative.md" || fail "expected the template to show the line \"- $line\""
done

scenario "asks no such metric of an initiative opened before the rule, and asks it of one opened after"
replace_first "$keep_race" "$complete" "$free_text"
with_free_text=$replaced
opened="2026-11-22T23:59:59Z"
ticket initiative "$with_free_text

## States
No screen"
run "$scripts/check-ticket.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
opened="2026-11-23T00:00:00Z"
ticket initiative "$with_free_text

## States
No screen"
run "$scripts/check-ticket.sh" 12
expect_status 1
expect_output 'names no event.'
expect_output 'names no number a script can read.'
expect_output 'names no date to look.'
