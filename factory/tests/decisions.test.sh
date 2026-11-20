#!/usr/bin/env bash
# Tests for factory/scripts/decisions.sh, which prints a whole decision record (decisions H130a, H130b).
. "$(dirname "$0")/helpers.sh"

header=$(sed -n '3,9p' "$root/factory/decisions.md")
columns='| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|'
revisit='| ID | Idea | Parked because | Revisit when | Source |
|---|---|---|---|---|'

# record: a record, decisions.md, with the sections "T: Tickets", "A: Agents" and "R: To revisit".
record() {
  printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n\n## A: Agents\n\n%s\n\n## R: To revisit\n\n%s\n' \
    "$header" "$columns" "$columns" "$revisit" > decisions.md
}
# rows <ticket> <rows>: that ticket's file in the record's folder, one table of these rows.
rows() {
  mkdir -p decisions
  printf '%s\n%s\n' "$columns" "$2" > "decisions/$1.md"
}
# row <id> <source>: one row.
row() { printf '| %s | Decision %s. | Why. | Other: no. | %s |' "$1" "$1" "$2"; }
# ids: the IDs of the rows the script printed, in the order it printed them, on one line.
ids() { awk -F'|' '/^\| [A-Z][0-9]/ { gsub(/ /, "", $2); printf "%s ", $2 }' <<<"$out"; }

show() { run "$scripts/decisions.sh" decisions.md; }

scenario "prints the record's own file with each row under its section, in a table with its columns"
record
rows 20 "$(row T4 '#20')
$(row A5 '#20')"
printf '\n%s\n| R3 | An idea. | Parked. | Some day. | #20 |\n' "$revisit" >> decisions/20.md
show
expect_status 0
expect_output "# Decisions

$header

## T: Tickets

$columns
$(row T4 '#20')

## A: Agents

$columns
$(row A5 '#20')

## R: To revisit

$revisit
| R3 | An idea. | Parked. | Some day. | #20 |"
[ "$(grep -c '^| ID ' <<<"$out")" = 3 ] || fail "a ticket's own column names were printed among the rows"

scenario "sorts a section's rows by the number in the ID, then its letter, whatever file holds them"
record
rows 98 "$(row T98 '#98')"
rows 69 "$(row T69b '#69')
$(row T69a '#69')
$(row A69 '#69')"
rows 50 "$(row T50a '#50')"
rows setup "$(row T10 setup)
$(row T9 setup)
$(row T2 setup)
$(row A1 setup)"
rows 105 "$(row T105 '#105')"
show
expect_status 0
[ "$(ids)" = "T2 T9 T10 T50a T69a T69b T98 T105 A1 A69 " ] || fail "the rows came out as: $(ids)"

scenario "prints a record with no rows, and one with no folder, as its sections alone"
record
show
expect_status 0
[ "$out" = "$(cat decisions.md)" ] || fail "the record's own file was not printed as it is"
mkdir decisions
show
expect_status 0
[ "$out" = "$(cat decisions.md)" ] || fail "the record's own file was not printed as it is"

scenario "prints a row once, and loses none, when a file ends without a newline or has Windows line endings"
record
rows 20 "$(row T4 '#20')"
printf '%s\n%s' "$columns" "$(row T21 '#21')" > decisions/21.md
rows 22 "$(row T22 '#22')"
sed -i.bak 's/$/\r/' decisions/22.md
rm decisions/22.md.bak
show
expect_status 0
[ "$(ids)" = "T4 T21 T22 " ] || fail "the rows came out as: $(ids)"
expect_no_output $'\r'

scenario "reads the factory's record when none is named"
mkdir factory
record
mv decisions.md factory/decisions.md
mkdir factory/decisions
printf '%s\n%s\n' "$columns" "$(row T4 '#20')" > factory/decisions/20.md
run "$scripts/decisions.sh"
expect_status 0
expect_output "$(row T4 '#20')"

scenario "stops, and prints no record, when a row's letter has no section"
record
rows 20 "$(row T4 '#20')
$(row W5 '#20')"
show
expect_status 1
expect_output "decisions.md: no section has the letter W, which W5 in decisions/20.md starts with"
expect_no_output "| T4 |"

scenario "stops when a section has no table to put its rows in"
record
rows 20 "$(row T4 '#20')"
printf '\n## W: Workflows\n' >> decisions.md
rows 40 "$(row W40 '#40')"
show
expect_status 1
expect_output "decisions.md: the section with the letter W has no table for its rows"

scenario "stops when the record is missing or empty"
show
expect_status 1
expect_output "decisions.md: there is no such decision record"
: > decisions.md
show
expect_status 1
expect_output "decisions.md: there is no such decision record"

# No merge attribute is set, so git merges here as GitHub and the test of a group do (decisions M95).
branches() {
  git init --quiet --initial-branch=main .
  record
  rows 20 "$(row T4 '#20')"
  git add --all
  git commit --quiet --message base
}

scenario "two branches that each added rows to one section merge with no conflict, and both sets are printed"
branches
git checkout --quiet -b theirs
rows 70 "$(row T70a '#70')
$(row T70b '#70')"
git add --all
git commit --quiet --message theirs
git checkout --quiet -b ours main
rows 69 "$(row T69a '#69')
$(row T69b '#69')"
git add --all
git commit --quiet --message ours
run git merge --no-edit theirs
expect_status 0
expect_no_output "CONFLICT"
[ -z "$(git status --porcelain)" ] || fail "the merge left something to resolve: $(git status --porcelain)"
show
expect_status 0
[ "$(ids)" = "T4 T69a T69b T70a T70b " ] || fail "the rows came out as: $(ids)"
run "$scripts/check-decisions.sh" decisions.md
expect_status 0
expect_output "decision records ok: 5 rows in 1 records"

scenario "the same two branches conflict when each adds its rows to one shared file, as before"
branches
git checkout --quiet -b theirs
row T70a '#70' >> decisions/20.md
git commit --quiet --all --message theirs
git checkout --quiet -b ours main
row T69a '#69' >> decisions/20.md
git commit --quiet --all --message ours
run git merge --no-edit theirs
expect_status 1
expect_output "CONFLICT (content): Merge conflict in decisions/20.md"

scenario "two branches that rewrote the same row conflict in the file it lives in"
branches
git checkout --quiet -b theirs
sed -i.bak 's/Decision T4\./Theirs./' decisions/20.md
git commit --quiet --all --message theirs
git checkout --quiet -b ours main
sed -i.bak 's/Decision T4\./Ours./' decisions/20.md
git commit --quiet --all --message ours
run git merge --no-edit theirs
expect_status 1
expect_output "CONFLICT (content): Merge conflict in decisions/20.md"

scenario "the repo's own record is printed whole: every row check-decisions.sh counts, none twice"
cd "$root" || exit 1
run "$scripts/check-decisions.sh" factory/decisions.md
expect_status 0
counted=$(sed -n 's/^decision records ok: \([0-9]*\) rows.*/\1/p' <<<"$out")
run "$scripts/decisions.sh"
expect_status 0
[ "$(ids | wc -w | tr -d ' ')" = "$counted" ] || fail "check-decisions.sh counts $counted rows, and decisions.sh printed $(ids | wc -w)"
[ -z "$(ids | tr ' ' '\n' | sort | uniq -d)" ] || fail "printed twice: $(ids | tr ' ' '\n' | sort | uniq -d)"
