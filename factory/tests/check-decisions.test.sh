#!/usr/bin/env bash
# Tests for factory/scripts/check-decisions.sh: the format of decision records (decisions H10 to H12, H130a to H130c).
. "$(dirname "$0")/helpers.sh"

# Taken from the factory's own record, so the tests and the script cannot both be wrong about it in the same way.
header=$(sed -n '3,9p' "$root/factory/decisions.md")
columns='| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|'
revisit='| ID | Idea | Parked because | Revisit when | Source |
|---|---|---|---|---|'

words() {
  local text="" i
  for ((i = 1; i <= $1; i++)); do text+="word "; done
  printf '%s' "${text% }"
}

record() {
  printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n\n## R: To revisit\n\n%s\n' "$header" "$columns" "$revisit" > decisions.md
}
# rows <ticket> <rows>: that ticket's file in the record's folder, whose first row is on line 3.
rows() {
  mkdir -p decisions
  printf '%s\n%s\n' "$columns" "$2" > "decisions/$1.md"
}

check() { run "$scripts/check-decisions.sh" decisions.md; }

refuses() {
  expect_status 1
  expect_output "$1"
}

good='| T1 | Tickets are GitHub Issues. | One place and one login. | Linear: another service. | #20 |'

scenario "passes a record whose rows are in the files of their tickets"
record
rows 20 "$good"
rows setup "| T2 | The label starts a build. | A label is an event. | Starting on creation: no go-ahead. | setup |"
check
expect_status 0
expect_output "decision records ok: 2 rows in 1 records"

scenario "passes cells that are exactly at their limits"
record
rows 39 "| T1 | $(words 25) | $(words 30) | $(words 30) | #39, #47 |"
check
expect_status 0

scenario "passes a record with no rows yet, with or without its folder"
record
check
expect_status 0
expect_output "decision records ok: 0 rows in 1 records"
mkdir decisions
check
expect_status 0

scenario "passes a file that holds a table for each kind of section"
record
rows 20 "$good

$revisit
| R1 | A faster model. | Nothing to compare it with. | There are enough runs. | #20 |"
check
expect_status 0
expect_output "decision records ok: 2 rows in 1 records"

scenario "does not split a cell at an escaped bar"
record
rows 56 '| T1 | A read is piped with `\|\| true`. | It was. | Leaving it: wrong. | #56 |'
check
expect_status 0

scenario "reads a record written with Windows line endings"
record
rows 20 "$good"
sed -i.bak 's/$/\r/' decisions.md decisions/20.md
rm decisions/20.md.bak
check
expect_status 0

scenario "refuses a 26-word decision, naming the file, the row and the rule"
record
rows 20 "| T4 | $(words 26) | Why. | Other: no. | #20 |"
check
refuses "decisions/20.md:3: T4: Decision is 26 words, and the limit is 25"

scenario "refuses a 31-word reason"
record
rows 20 "| T4 | Decision. | $(words 31) | Other: no. | #20 |"
check
refuses "T4: Why is 31 words, and the limit is 30"

scenario "refuses a 31-word Rejected cell"
record
rows 20 "| T4 | Decision. | Why. | $(words 31) | #20 |"
check
refuses "T4: Rejected is 31 words, and the limit is 30"

scenario "names a To revisit row's cells by their own columns"
record
mkdir decisions
printf '%s\n| R1 | %s | Parked. | | #20 |\n' "$revisit" "$(words 26)" > decisions/20.md
check
refuses "R1: Idea is 26 words, and the limit is 25"
expect_output "R1: Revisit when is empty"

scenario "refuses an empty Rejected cell"
record
rows 20 "| T4 | Decision. | Why. | | #20 |"
check
refuses "T4: Rejected is empty"

scenario "refuses an empty Decision, Why or Source cell"
record
rows 20 "| T4 |  | | Other: no. | |"
check
refuses "T4: Decision is empty"
expect_output "T4: Why is empty"
expect_output "T4: Source is empty"

scenario "refuses a duplicate ID in one file, naming where it is first"
record
rows 20 "$good
| T1 | Another decision. | Why. | Other: no. | #20 |"
check
refuses "decisions/20.md:4: T1: ID is already used at decisions/20.md:3"

scenario "refuses a duplicate ID across two files"
record
rows 20 "$good"
rows 69 "| T1 | Another decision. | Why. | Other: no. | #20, #69 |"
check
refuses "decisions/69.md:3: T1: ID is already used at decisions/20.md:3"

scenario "passes an ID in either form: numbered in order, or named after its ticket"
record
rows 20 "| T4 | Decision. | Why. | Other: no. | #20 |"
rows 62 "| T62 | Decision. | Why. | Other: no. | #62 |"
rows 69 "| T69a | Decision. | Why. | Other: no. | #69 |
| T69b | Decision. | Why. | Other: no. | #69 |"
check
expect_status 0
expect_output "decision records ok: 4 rows in 1 records"

scenario "refuses a malformed ID"
for id in t1 T 4 T04 TT4 T-4 T62A T62ab Ta62 T62-a; do
  record
  rows setup "| $id | Decision. | Why. | Other: no. | setup |"
  check
  refuses "$id: ID is a capital letter and a number, with at most one small letter after it, like T4 or A69a"
done

scenario "refuses an empty ID"
record
rows setup "|  | Decision. | Why. | Other: no. | setup |"
check
refuses "this row: ID is empty"

scenario "refuses a Source of free text"
for source in "the owner, in a session" "ticket 47" "#47 and #53" "47" "setup, #20"; do
  record
  rows 20 "| T4 | Decision. | Why. | Other: no. | $source |"
  check
  refuses 'T4: Source is ticket numbers ("#47" or "#39, #47") or "setup"'
done

scenario "refuses a row in the record's own file, saying where it goes"
record
printf '%s\n' "$good" >> decisions.md
check
refuses "decisions.md:20: a row goes in the file of the ticket that adds it, decisions/<ticket>.md, and this file holds only the sections"

scenario "refuses a paragraph between two sections of the record"
printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n\nIdeas raised and not acted on yet.\n\n## R: To revisit\n\n%s\n' "$header" "$columns" "$revisit" > decisions.md
check
refuses "decisions.md:16: only the header, headings and their tables belong in a record, and this is none of them: Ideas raised and not acted on yet."

scenario "refuses a paragraph, a list item or a heading in a ticket's file"
record
rows 20 "$good
- see also the row above"
check
refuses "decisions/20.md:4: only tables of rows belong in a ticket's file, and this is none of them: - see also the row above"
mkdir -p decisions
printf '## Tickets\n\n%s\n%s\n' "$columns" "$good" > decisions/20.md
check
refuses "decisions/20.md:1: only tables of rows belong in a ticket's file, and this is none of them: ## Tickets"

scenario "refuses a header that says something else"
record
sed -i.bak 's/25 words or fewer/40 words or fewer/' decisions.md
check
refuses "decisions.md:6: line 4 of the header must read: - **Decision:**"

scenario "refuses a header with a line added"
printf '# Decisions\n\n%s\n- One more rule of my own.\n\n## T: Tickets\n\n%s\n' "$header" "$columns" > decisions.md
check
refuses "this is none of them: - One more rule of my own."

scenario "refuses a record whose header stops short"
printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n' "$(sed -n '1,4p' <<<"$header")" "$columns" > decisions.md
check
refuses "decisions.md:8: the header is missing its line 5: - **Rejected:**"

scenario "refuses a record with no header and no table"
printf '# Decisions\n' > decisions.md
check
refuses "the header is missing its line 1"

scenario "refuses an empty record and a record with no title"
: > decisions.md
check
refuses "decisions.md: the record is empty"
record
sed -i.bak '1s/.*/Decisions/' decisions.md
check
refuses 'decisions.md:1: the first line is the title, "# ..."'

scenario "refuses a section heading without its letter, or with a letter already taken"
printf '# Decisions\n\n%s\n\n## Tickets\n\n%s\n' "$header" "$columns" > decisions.md
check
refuses 'decisions.md:11: a section heading is its letter and its name, like "## T: Tickets and state"'
printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n\n## T: Tests\n\n%s\n' "$header" "$columns" "$columns" > decisions.md
check
refuses 'decisions.md:16: the letter T already belongs to "## T: Tickets"'

scenario "refuses a table with other columns, or with no line under them, in the record and in a ticket's file"
printf '# Decisions\n\n%s\n\n## T: Tickets\n\n| Decision | Why | Instead of |\n|---|---|---|\n' "$header" > decisions.md
check
refuses 'decisions.md:13: a table starts with "| ID | Decision | Why | Rejected | Source |"'
record
mkdir decisions
printf '| Decision | Why | Instead of |\n|---|---|---|\n' > decisions/20.md
check
refuses 'decisions/20.md:1: a table starts with "| ID | Decision | Why | Rejected | Source |"'
printf '| ID | Decision | Why | Rejected | Source |\n%s\n' "$good" > decisions/20.md
check
refuses "decisions/20.md:2: the line under a table's column names is"

scenario "refuses a table with no heading above it in the record"
printf '# Decisions\n\n%s\n\n%s\n' "$header" "$columns" > decisions.md
check
refuses 'a table needs a "## " heading above it'

scenario "refuses a row with a cell too many or too few"
record
rows 20 "| T4 | Decision. | Why. | #20 |"
check
refuses "decisions/20.md:3: a row has 5 cells, and this one has 4"
rows 20 "| T4 | Decision with a | bar. | Why. | Other: no. | #20 |"
check
refuses "a row has 5 cells, and this one has 6"

scenario "refuses a row whose letter no section of the record has"
record
rows 20 "$good
| A2 | Decision. | Why. | Other: no. | #20 |"
check
refuses "decisions/20.md:4: A2: ID starts with the letter of its section, and decisions.md has no section with the letter A"

scenario "refuses a row under the columns of the other kind of section"
record
rows 20 "$good
| R2 | An idea. | Parked. | Some day. | #20 |"
check
refuses 'R2: rows of "## R: To revisit" go in a table that starts with "| ID | Idea | Parked because | Revisit when | Source |"'

scenario "refuses a file that is not named for a ticket, and anything that is no file"
record
rows 20 "$good"
mv decisions/20.md decisions/notes.md
check
refuses 'decisions/notes.md:1: a file here holds one ticket'"'"'s rows and is named for it, like "62.md", or "setup.md"'
for name in 020.md 20.txt twenty.md 20a.md; do
  record
  rm -rf decisions
  rows 20 "$good"
  mv decisions/20.md "decisions/$name"
  check
  refuses "decisions/$name:1: a file here holds one ticket's rows"
done
record
rm -rf decisions
mkdir -p decisions/old
check
refuses "decisions/old: only the files of tickets belong beside a record, and this is no file"

scenario "refuses a ticket's file with no row in it"
record
rows 20 "$good"
printf '%s\n' "$columns" > decisions/21.md
check
refuses "decisions/21.md: a ticket's file holds at least one row"
: > decisions/21.md
check
refuses "decisions/21.md: a ticket's file holds at least one row"

# A row lives in the file of a ticket its Source names (decisions H130c).
scenario "refuses a row in the file of a ticket its Source does not name"
record
rows 21 "$good"
check
refuses "decisions/21.md:3: T1: 21.md holds the rows of ticket #21, and the Source of this one (#20) does not name it"

scenario "refuses a file whose number only starts or ends like the ticket in the Source"
record
rows 2 "$good"
check
refuses "T1: 2.md holds the rows of ticket #2"
rows 2 "| T1 | Decision. | Why. | Other: no. | #20, #120 |"
mv decisions/2.md decisions/12.md
check
refuses "T1: 12.md holds the rows of ticket #12"

scenario "passes a row in the file of any ticket its Source names, as one that rewrote it may move it"
record
rows 89 "| T7 | Decision. | Why. | Other: no. | #71, #89 |"
check
expect_status 0
mv decisions/89.md decisions/71.md
check
expect_status 0

scenario "refuses a setup row in a ticket's file, and a ticket's row in setup.md"
record
rows 20 "| T2 | Decision. | Why. | Other: no. | setup |"
check
refuses 'decisions/20.md:3: T2: a row whose Source is "setup" goes in setup.md'
rm decisions/20.md
rows setup "$good"
check
refuses 'decisions/setup.md:3: T1: setup.md holds the rows whose Source is "setup", and this one goes in the file of a ticket in its Source (#20)'

scenario "reports every problem, in every file and every record, in one run"
record
rows 20 "| T4 | $(words 26) | Why. | | free text |"
rows 21 "| T5 | Decision. | $(words 31) | Other: no. | #21 |"
mkdir other
cp decisions.md other.md
printf '%s\n| T6 | Decision. | Why. | | #22 |\n' "$columns" > other/22.md
run "$scripts/check-decisions.sh" decisions.md other.md
expect_status 1
expect_output "decisions/20.md:3: T4: Decision is 26 words"
expect_output "decisions/20.md:3: T4: Rejected is empty"
expect_output "decisions/20.md:3: T4: Source is ticket numbers"
expect_output "decisions/21.md:3: T5: Why is 31 words"
expect_output "other/22.md:3: T6: Rejected is empty"
expect_no_output "decision records ok"

scenario "refuses a record that is not there"
run "$scripts/check-decisions.sh" missing.md
refuses "missing.md: there is no such decision record"

scenario "checks every record, each with its own folder, when none is named"
mkdir -p factory product architecture
record
cp decisions.md factory/decisions.md
mkdir factory/decisions
printf '%s\n%s\n' "$columns" "$good" > factory/decisions/20.md
run "$scripts/check-decisions.sh"
refuses "product/decisions.md: there is no such decision record"
expect_output "architecture/decisions.md: there is no such decision record"
cp decisions.md architecture/decisions.md
mkdir architecture/decisions
printf '%s\n| T4 | Decision. | | Other: no. | #20 |\n' "$columns" > architecture/decisions/20.md
cp decisions.md product/decisions.md
mkdir product/decisions
printf '%s\n| T4 | Decision. | Why. | | #20 |\n' "$columns" > product/decisions/20.md
run "$scripts/check-decisions.sh"
refuses "product/decisions/20.md:3: T4: Rejected is empty"
expect_output "architecture/decisions/20.md:3: T4: Why is empty"
rm -r product/decisions architecture/decisions
run "$scripts/check-decisions.sh"
expect_status 0
expect_output "decision records ok: 1 rows in 3 records"
# The same ID in two records is no duplicate: each record has its own sections.
mkdir product/decisions
cp factory/decisions/20.md product/decisions/20.md
run "$scripts/check-decisions.sh"
expect_status 0
expect_output "decision records ok: 2 rows in 3 records"

# on_main <ticket> <rows>: a repository whose origin/main holds these rows, for new rows (decisions H105a, H105b).
on_main() {
  git init --quiet --initial-branch=main .
  record
  rows "$1" "$2"
  git add --all
  git commit --quiet --message main
  git update-ref refs/remotes/origin/main HEAD
}
# checkout_without_main <ticket> <rows>: a shallow checkout with no origin/main, as a pull request's checks run on.
checkout_without_main() {
  mkdir "$T/origin"
  (cd "$T/origin" && on_main "$1" "$2")
  git clone --quiet --depth=1 "file://$T/origin" .
  git update-ref -d refs/remotes/origin/HEAD
  git update-ref -d refs/remotes/origin/main
}
new_row_message='a new row is named after the ticket that adds it'

scenario "refuses a new row numbered in order, naming the ID its file gives it"
on_main 20 "$good"
rows 69 "| T30 | Decision. | Why. | Other: no. | #69 |"
check
refuses "decisions/69.md:3: T30: a new row is named after the ticket that adds it (it is in 69.md, so T69, or T69a, T69b for several); decisions H95a"

scenario "passes new rows named after their ticket, lettered or not, written and not yet committed"
on_main 20 "$good"
rows 69 "| T69a | Decision. | Why. | Other: no. | #69 |
| T69b | Decision. | Why. | Other: no. | #69 |"
rows 70 "| T70 | Decision. | Why. | Other: no. | #70 |"
check
expect_status 0
expect_output "decision records ok: 4 rows in 1 records"
expect_no_output "could not be read"

scenario "passes a row numbered in order that main already holds, even when it is rewritten"
on_main 20 "$good
| T4 | Decision. | Why. | Other: no. | #20 |"
rows 20 "$good
| T4 | Another decision. | Why. | Decision: the old choice. | #20, #69 |"
check
expect_status 0

scenario "passes a row main holds that the ticket rewriting it moved into its own file"
on_main 20 "$good
| T4 | Decision. | Why. | Other: no. | #20 |"
rows 20 "$good"
rows 69 "| T4 | Another decision. | Why. | Decision: the old choice. | #20, #69 |"
check
expect_status 0

scenario "passes a row that main still holds in the record's own file, moved to its ticket's file"
git init --quiet --initial-branch=main .
record
printf '%s\n' "$good" >> decisions.md
git add --all
git commit --quiet --message main
git update-ref refs/remotes/origin/main HEAD
record
rows 20 "$good"
check
expect_status 0
expect_output "decision records ok: 1 rows in 1 records"

scenario "refuses a new row named after another ticket in its Source than its file's"
on_main 20 "$good"
rows 71 "| T89 | Decision. | Why. | Other: no. | #71, #89 |"
check
refuses "T89: $new_row_message (it is in 71.md, so T71, or T71a, T71b for several); decisions H95a"
mv decisions/71.md decisions/89.md
check
expect_status 0

scenario "refuses a new row whose number only starts with its ticket's"
on_main 20 "$good"
rows 69 "| T690 | Decision. | Why. | Other: no. | #69 |"
check
refuses "T690: $new_row_message"

scenario "refuses a new row in setup.md"
on_main 20 "$good"
rows setup "| T2 | Decision. | Why. | Other: no. | setup |"
check
refuses "decisions/setup.md:3: T2: a new row goes in the file of the ticket that adds it and is named after it, and setup.md takes no new row; decisions H95a"

scenario "takes every row of a record main does not hold as new"
on_main 20 "$good"
mkdir other
cp decisions.md other.md
printf '%s\n%s\n' "$columns" "$good" > other/21.md
printf '%s\n| T69 | Decision. | Why. | Other: no. | #69 |\n' "$columns" > other/69.md
run "$scripts/check-decisions.sh" other.md
refuses "other/21.md:3: T1: 21.md holds the rows of ticket #21"
expect_output "other/21.md:3: T1: $new_row_message"
expect_no_output "T69:"

scenario "fetches main for the rule in a checkout that holds none, as a pull request's checks do"
checkout_without_main 20 "$good"
rows 69 "| T30 | Decision. | Why. | Other: no. | #69 |
| T69 | Decision. | Why. | Other: no. | #69 |"
check
refuses "T30: $new_row_message"
expect_no_output "T69:"
expect_no_output "T1:"
[ "$(git rev-parse --is-shallow-repository)" = true ] || fail "the fetch made the shallow checkout a full one"

scenario "reads the branch the pull request is for, not always main"
on_main 20 "$good"
git update-ref refs/remotes/origin/trunk HEAD
git update-ref -d refs/remotes/origin/main
rows 69 "| T30 | Decision. | Why. | Other: no. | #69 |"
GITHUB_BASE_REF=trunk run "$scripts/check-decisions.sh" decisions.md
refuses "T30: $new_row_message"

scenario "skips the rule, and says so, when main cannot be fetched, and still checks the rest"
checkout_without_main 20 "$good"
rm -rf "$T/origin"
rows 69 "| T30 | Decision. | Why. | Other: no. | #69 |"
check
expect_status 0
expect_output "origin/main could not be read, so new rows were not checked for their ticket's number"
expect_output "decision records ok: 2 rows in 1 records"
rows 69 "| T30 | Decision. | Why. | | #69 |"
check
refuses "T30: Rejected is empty"
expect_no_output "$new_row_message"
rows 70 "| T31 | Decision. | Why. | Other: no. | #69 |"
check
refuses "T31: 70.md holds the rows of ticket #70"

scenario "skips the rule, and says so, outside a git repository"
record
rows 69 "| T30 | Decision. | Why. | Other: no. | #69 |"
check
expect_status 0
expect_output "origin/main could not be read, so new rows were not checked for their ticket's number"

scenario "the repo's own records, and the seed for a new project, keep the format"
cd "$root" || exit 1
run "$scripts/check-decisions.sh" factory/decisions.md product/decisions.md architecture/decisions.md \
  .claude/skills/bootstrap/templates/product/decisions.md .claude/skills/bootstrap/templates/architecture/decisions.md
expect_status 0
