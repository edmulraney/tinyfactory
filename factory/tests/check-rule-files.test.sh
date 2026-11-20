#!/usr/bin/env bash
# Tests for check-rule-files.sh: no fact that changes by itself, each rule file in budget (decisions H172a to H172d).
. "$(dirname "$0")/helpers.sh"

repo() {
  git init --quiet --initial-branch=main .
  mkdir -p factory/scripts factory/decisions factory/tests .claude/skills/build .claude/skills/bootstrap/scripts
  printf '# Rules\n\nA ticket is one change.\n' > CLAUDE.md
  printf '# Build\n\nRead the ticket: `gh issue view <n>`. Its description says "Closes #62".\n' > .claude/skills/build/SKILL.md
  printf '#!/usr/bin/env bash\n# Prints the ticket a pull request closes ("Closes #12").\necho done\n' > factory/scripts/one.sh
  printf '# The list.\n\n50 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
  git add --all
}
# append_line <file> <line>: appends the line to the file.
append_line() { printf '%s\n' "$2" >> "$1"; }
check() { run "$scripts/check-rule-files.sh" "$@"; }
refuses() {
  expect_status 1
  expect_output "$1"
  expect_no_output "rule files ok"
}

scenario "passes rule files and comments that hold only rules, and says how much it read"
repo
check
expect_status 0
expect_output "rule files ok: 2 files and the comments of 1 scripts"

scenario "fails on a ticket's number beside its state, with the file and the line"
repo
append_line .claude/skills/build/SKILL.md "Wait for the split of the record (#121, open)."
check
refuses '.claude/skills/build/SKILL.md:4: the state of a ticket beside its number: "#121, open"'
expect_output "A rule file holds what stays true until someone edits it"

scenario "fails on the state however it stands beside the number"
repo
append_line CLAUDE.md "Pull request #153 is merged."
append_line CLAUDE.md "Since #130 was deployed, rows are in files."
append_line CLAUDE.md "See the closed issue #47."
append_line CLAUDE.md "Ticket #64: in progress."
check
refuses 'CLAUDE.md:4: the state of a ticket beside its number: "#153 is merged"'
expect_output 'CLAUDE.md:5: the state of a ticket beside its number: "#130 was deployed"'
expect_output 'CLAUDE.md:6: the state of a ticket beside its number: "closed issue #47"'
expect_output 'CLAUDE.md:7: the state of a ticket beside its number: "#64: in progress"'

scenario "passes a ticket's number with no state beside it"
repo
append_line CLAUDE.md 'Tell the owner one action ("approve #148", "close #129 and rebuild").'
append_line CLAUDE.md "The table's last column names the tickets: #89, #124. Open the pull request."
append_line CLAUDE.md "A reference is written #12, owner/repo#12 or opened as a link."
check
expect_status 0

scenario "fails on a date, written out or in figures"
repo
append_line CLAUDE.md "On 16 November four pull requests conflicted."
append_line CLAUDE.md "Found by comparing the records (2026-11-14)."
append_line CLAUDE.md "Since November 2026 the record is split."
append_line CLAUDE.md "It began on March 3rd."
check
refuses 'CLAUDE.md:4: a date: "16 November"'
expect_output 'CLAUDE.md:5: a date: "2026-11-14"'
expect_output 'CLAUDE.md:6: a date: "November 2026"'
expect_output 'CLAUDE.md:7: a date: "March 3"'

scenario "passes figures and words that are no date"
repo
append_line CLAUDE.md "A reviewer may fail it. A file is named research/YYYY-MM-DD-name.md."
append_line CLAUDE.md "Wait 90 days. Version 10.32.1, run 2026111401, 3 may be in flight."
check
expect_status 0

scenario "fails on each phrase that is true only for now, in any case"
repo
append_line CLAUDE.md "Currently the board has four tabs."
append_line CLAUDE.md "The five retros so far cost little."
append_line CLAUDE.md "The sweep is not yet built."
check
refuses 'CLAUDE.md:4: a phrase that is true only for now: "currently"'
expect_output 'CLAUDE.md:5: a phrase that is true only for now: "so far"'
expect_output 'CLAUDE.md:6: a phrase that is true only for now: "not yet"'

scenario "passes words that only hold those phrases' letters"
repo
append_line CLAUDE.md "Do so farther down. It is not yetis we count. Concurrently is fine."
check
expect_status 0

scenario "fails on a comment in a script, and in a bootstrap script, and reads no code"
repo
append_line factory/scripts/one.sh '  # The limit was raised (#86, merged) on 14 November.'
append_line factory/scripts/one.sh 'echo "the build has not yet begun: #12 is open since 2026-11-14"'
printf '#!/usr/bin/env bash\n# Not yet automated.\n' > .claude/skills/bootstrap/scripts/board.sh
git add --all
check
refuses 'factory/scripts/one.sh:4: the state of a ticket beside its number: "#86, merged"'
expect_output 'factory/scripts/one.sh:4: a date: "14 November"'
expect_output '.claude/skills/bootstrap/scripts/board.sh:2: a phrase that is true only for now: "not yet"'
expect_no_output "one.sh:5"

scenario "fails on a new script and a new skill not yet added to git, and reads no ignored file"
repo
printf '#!/usr/bin/env bash\n# Not yet automated.\n' > factory/scripts/new.sh
mkdir .claude/skills/review
printf '# Review\n' > .claude/skills/review/SKILL.md
printf '#!/usr/bin/env bash\n# Not yet automated.\n' > factory/scripts/ignored.sh
echo 'factory/scripts/ignored.sh' > .gitignore
check
refuses 'factory/scripts/new.sh:2: a phrase that is true only for now: "not yet"'
expect_output ".claude/skills/review/SKILL.md: factory/rule-files.txt does not name it"
expect_no_output "ignored.sh"

scenario "passes a record, a free-tier entry and a test's comment that hold all of them"
repo
mkdir factory/free-tier
append_line factory/decisions/172.md "| H172 | Lint fails a date. | Pull request #153, merged on 16 November, is so far the only case. | None yet. | #172 |"
append_line factory/free-tier/172.md "- **What happened:** on 14 November 2026 ticket #57 was not yet closed."
append_line factory/tests/one.test.sh "# tickets: #40 open, #41 closed. Currently the stand-in knows no others."
git add --all
check
expect_status 0
expect_output "rule files ok: 2 files and the comments of 1 scripts"

scenario "passes a file one word over its budget, and prints the file, its words and its budget"
repo
printf '6 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
check
expect_status 0
expect_output "CLAUDE.md: it holds 7 words and its budget is 6. This fails nothing: once the pull request merges, the factory files a ticket that cuts the file to its budget"
expect_output "rule files ok: 2 files"
expect_no_output "SKILL.md: it holds"

scenario "says nothing of a file at its budget exactly"
repo
printf '7 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
check
expect_status 0
expect_no_output "it holds"

scenario "fails a file more than a fifth over its budget, and passes it a fifth over exactly"
repo
append_line CLAUDE.md "Five more words are here."
printf '9 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
check
refuses "CLAUDE.md: it holds 12 words and its budget is 9, and lint fails a file more than a fifth over its budget."
expect_no_output "This fails nothing"
printf '10 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
check
expect_status 0
expect_output "CLAUDE.md: it holds 12 words and its budget is 10. This fails nothing"

scenario "--over prints each file over its budget with its words and budget, and nothing else, outside a git repository"
repo
rm -rf .git
append_line CLAUDE.md "Currently five more words here."
printf '9 CLAUDE.md\n8 .claude/skills/build/SKILL.md\n50 factory/scripts/one.sh\n' > factory/rule-files.txt
check --over
expect_status 0
[ "$out" = "12 9 CLAUDE.md"$'\n'"14 8 .claude/skills/build/SKILL.md" ] || fail "expected only the two files over their budget"

scenario "--over fails on a line of the list it cannot read"
repo
append_line factory/rule-files.txt "40 TASTE.md"
check --over
expect_status 1
expect_output "factory/rule-files.txt:5: TASTE.md is not a file"

scenario "fails a skill the list does not name"
repo
mkdir .claude/skills/review
printf '# Review\n' > .claude/skills/review/SKILL.md
git add --all
check
refuses ".claude/skills/review/SKILL.md: factory/rule-files.txt does not name it"
expect_no_output "build/SKILL.md"

scenario "fails a line of the list that names no file, or gives no budget, with its line"
repo
append_line factory/rule-files.txt "40 TASTE.md"
append_line factory/rule-files.txt "DESIGN.md"
check
refuses "factory/rule-files.txt:5: TASTE.md is not a file"
expect_output 'factory/rule-files.txt:6: a line is "<words> <path>", and this is not: DESIGN.md'

scenario "passes a project with no DESIGN.md, and still holds one that exists to its budget"
repo
append_line factory/rule-files.txt "5 DESIGN.md"
check
expect_status 0
expect_output "rule files ok: 2 files"
printf '# Design\n\nThe page is grey and cards are white.\n' > DESIGN.md
git add --all
check
refuses "DESIGN.md: it holds 10 words and its budget is 5"

scenario "passes a project with no SECURITY.md, and still holds one that exists to its budget"
repo
append_line factory/rule-files.txt "5 SECURITY.md"
check
expect_status 0
expect_output "rule files ok: 2 files"
printf '# Security\n\nThe factory acts only for the team here.\n' > SECURITY.md
git add --all
check
refuses "SECURITY.md: it holds 10 words and its budget is 5"

scenario "reports every problem in one run"
repo
printf '5 CLAUDE.md\n50 .claude/skills/build/SKILL.md\n' > factory/rule-files.txt
append_line .claude/skills/build/SKILL.md "Currently three tickets are in flight."
append_line factory/scripts/one.sh "# Written on 16 November."
check
refuses "CLAUDE.md: it holds 7 words and its budget is 5, and lint fails"
expect_output 'SKILL.md:4: a phrase that is true only for now: "currently"'
expect_output 'one.sh:4: a date: "16 November"'

scenario "reads a file written with Windows line endings"
repo
append_line CLAUDE.md "The sweep is not yet"
sed -i.bak 's/$/\r/' CLAUDE.md factory/rule-files.txt
rm CLAUDE.md.bak factory/rule-files.txt.bak
check
refuses 'CLAUDE.md:4: a phrase that is true only for now: "not yet"'
expect_no_output "is not a file"

scenario "stops with a message when there is no list"
repo
rm factory/rule-files.txt
check
refuses "factory/rule-files.txt: there is no such file, so no rule file was checked"

scenario "stops with a message when a listing fails, having checked nothing"
repo
rm -rf .git
check
refuses "check-rule-files.sh must be run inside a git repository: it could not list the skills with git ls-files, so nothing was checked."

scenario "the factory's own rule files pass"
cd "$root" || exit 1
check
expect_status 0
expect_output "rule files ok:"
