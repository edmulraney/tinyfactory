#!/usr/bin/env bash
# Tests for factory/scripts/decisions.sh: a decision record, or the rows asked for (decisions H130a, H130b, H579).
. "$(dirname "$0")/helpers.sh"

header=$(sed -n '3,9p' "$root/factory/decisions.md")
columns='| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|'
revisit='| ID | Idea | Parked because | Revisit when | Source |
|---|---|---|---|---|'

record() {
  printf '# Decisions\n\n%s\n\n## T: Tickets\n\n%s\n\n## A: Agents\n\n%s\n\n## R: To revisit\n\n%s\n' \
    "$header" "$columns" "$columns" "$revisit" > decisions.md
}
rows() {
  mkdir -p decisions
  printf '%s\n%s\n' "$columns" "$2" > "decisions/$1.md"
}
row() { printf '| %s | Decision %s. | Why. | Other: no. | %s |' "$1" "$1" "$2"; }
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

pick() { run "$scripts/decisions.sh" decisions.md "$@"; }
# chosen: a record whose rows cite each other and differ in what they say.
chosen() {
  record
  rows 20 "$(row T4 '#20')
| T40 | Fix rounds are counted. | Each costs Actions minutes. | Polling: [T4](20.md). | #20 |
$(row A5 '#20')"
  rows 31 "| A31a | A reviewer reads the diff. | A FIX ROUND is billed. | No review: slop. | #31 |
$(row A31b '#31')"
  printf '\n%s\n| R3 | An idea. | Parked. | Some day. | #31 |\n' "$revisit" >> decisions/31.md
}

scenario "prints the rows with the IDs it is given, in the record's order, and nothing else"
chosen
pick A31b R3 T4
expect_status 0
[ "$out" = "$(row T4 '#20')
$(row A31b '#31')
| R3 | An idea. | Parked. | Some day. | #31 |" ] || fail "printed: $out"

scenario "matches an ID whole, and only as an ID: no longer ID that starts with it, no row that cites it"
chosen
pick T4 A31
expect_status 1
expect_output "decisions.md: no row has the ID A31"
expect_no_output "| "
pick T4
expect_status 0
[ "$out" = "$(row T4 '#20')" ] || fail "printed: $out"

scenario "prints the rows that hold a word, in any column and in either case, and nothing else"
chosen
pick 'fix round'
expect_status 0
[ "$(ids)" = "T40 A31a " ] || fail "the rows came out as: $(ids)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = 2 ] || fail "more than the two rows was printed: $out"
pick '#31'
[ "$(ids)" = "A31a A31b R3 " ] || fail "the rows came out as: $(ids)"

scenario "prints a row once when an ID and a word both find it"
chosen
pick T40 minutes A5 rounds
expect_status 0
[ "$(ids)" = "T40 A5 " ] || fail "the rows came out as: $(ids)"

scenario "says which word no row holds, and still prints the rows the others found"
chosen
pick webhook A5
expect_status 0
[ "$out" = 'decisions.md: no row holds "webhook"'"
$(row A5 '#20')" ] || fail "printed: $out"

scenario "stops, and prints no row, when no row has an ID it is given"
chosen
pick A5 T999
expect_status 1
expect_output "decisions.md: no row has the ID T999"
expect_no_output "| A5 |"

scenario "stops when an ID or word is empty, which would find every row or none"
chosen
pick A5 ""
expect_status 1
expect_output "decisions.md: an ID or word to look for is empty or holds a line break"
expect_no_output "| A5 |"

scenario "stops, and prints no row, when a row's letter has no section, also when rows are asked for"
chosen
rows 40 "$(row W5 '#40')"
pick T4
expect_status 1
expect_output "decisions.md: no section has the letter W, which W5 in decisions/40.md starts with"
expect_no_output "| T4 |"

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
