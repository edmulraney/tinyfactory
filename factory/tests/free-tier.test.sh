#!/usr/bin/env bash
# Tests for free-tier.sh, which prints the log from its own file and the folder beside it (decisions H130e, H483).
. "$(dirname "$0")/helpers.sh"

# numbered <n>: an entry numbered in order, as free-tier/entry-<n>.md holds it.
numbered() { printf '### %s. Setting %s\n\n- **Set:** something.\n- **Automated:** yes.\n' "$1" "$1"; }
# named <id>: an entry named after its ticket, as a ticket's file holds it.
named() { printf '### #%s. Setting %s\n\n- **Set:** something.\n- **Automated:** yes.\n' "$1" "$1"; }
# log: the log's own file, free-tier.md: how an entry is written, and the headings of its sections.
log() {
  printf '# Staying on the free tier\n\nHow an entry is written.\n\n## The limits\n\n## Log\n\n## When to start paying\n' > free-tier.md
}
# part <name> <text>: that file in the log's folder.
part() {
  mkdir -p free-tier
  printf '%s\n' "$2" > "free-tier/$1.md"
}
names() { sed -n 's/^### \(#\{0,1\}[0-9]*[a-z]\{0,1\}\)\. .*/\1/p' <<<"$out" | tr '\n' ' '; }

show() { run "$scripts/free-tier.sh" free-tier.md; }

scenario "prints each section's file under its heading, and every entry under Log"
log
part limits "## The limits

| Service | Limit |
|---|---|"
part when-to-pay "## When to start paying

| Sign | Which limit |
|---|---|"
part entry-1 "$(numbered 1)"
part entry-2 "$(numbered 2)"
part 132 "$(named 132)"
show
expect_status 0
[ "$out" = "# Staying on the free tier

How an entry is written.

## The limits

| Service | Limit |
|---|---|

## Log

$(numbered 1)

$(numbered 2)

$(named 132)

## When to start paying

| Sign | Which limit |
|---|---|" ] || fail "the log was not printed with each table under its heading and the entries under Log"

scenario "prints the numbered entries first, then the tickets', each in the order of their numbers, not of their file names"
log
part 140 "$(named 140)"
part 98 "$(named 98)"
part entry-10 "$(numbered 10)"
part entry-2 "$(numbered 2)"
part 1000 "$(named 1000)"
part entry-1 "$(numbered 1)"
part 5 "$(named 5)"
part 132 "$(named 132a)

$(named 132b)"
show
expect_status 0
[ "$(names)" = "1 2 10 #5 #98 #132a #132b #140 #1000 " ] || fail "the entries came out as: $(names)"

scenario "prints a log with no file beside it, and one with no folder, as its own file"
log
show
expect_status 0
[ "$out" = "$(cat free-tier.md)" ] || fail "the log's own file was not printed as it is"
mkdir free-tier
show
expect_status 0
[ "$out" = "$(cat free-tier.md)" ] || fail "the log's own file was not printed as it is"

scenario "prints a section's files after what the log's own file holds of it, and under a section that ends the file"
printf '# Free tier\n\n## Log\n\nThe entries, oldest first.\n' > free-tier.md
part 132 "$(named 132)"
show
expect_status 0
[ "$out" = "# Free tier

## Log

The entries, oldest first.

$(named 132)" ] || fail "the ticket's entry was not printed at the end of the file"

scenario "puts one blank line between entries, whatever blank lines a file starts or ends with"
log
mkdir free-tier
printf '\n\n%s\n\n\n' "$(numbered 1)" > free-tier/entry-1.md
printf '\n\n%s\n\n\n' "$(named 98)" > free-tier/98.md
printf '%s' "$(named 132)" > free-tier/132.md
printf '\n## The limits\n\n\nA table.\n\n' > free-tier/limits.md
show
expect_status 0
expect_output "## The limits

A table.

## Log

$(numbered 1)

$(named 98)

$(named 132)

## When to start paying"

scenario "prints an entry once, and loses none, when a file has Windows line endings"
log
part limits "## The limits

A table."
part 98 "$(named 98)"
part 132 "$(named 132)"
sed -i.bak 's/$/\r/' free-tier/98.md free-tier/limits.md free-tier.md
rm free-tier/98.md.bak free-tier/limits.md.bak free-tier.md.bak
show
expect_status 0
[ "$(names)" = "#98 #132 " ] || fail "the entries came out as: $(names)"
[ "$(grep -c '^## The limits' <<<"$out")" = 1 ] || fail "the heading of the limits was not printed once"
expect_output "A table."
expect_no_output $'\r'

scenario "reads the factory's log when none is named"
mkdir factory
log
mv free-tier.md factory/free-tier.md
mkdir factory/free-tier
named 132 > factory/free-tier/132.md
run "$scripts/free-tier.sh"
expect_status 0
[ "$(names)" = "#132 " ] || fail "the entries came out as: $(names)"

scenario "stops, and prints no log, when the log's own file has no section for a file beside it"
printf '# Free tier\n\n## The limits\n' > free-tier.md
part 132 "$(named 132)"
show
expect_status 1
expect_output 'free-tier.md: there is no "## Log" section to print free-tier/132.md under'
expect_no_output "The limits"
log
part costs "## What it costs

A table."
show
expect_status 1
expect_output 'free-tier.md: there is no "## What it costs" section to print free-tier/costs.md under'
expect_no_output "How an entry is written"

scenario "stops when the log is missing or empty"
show
expect_status 1
expect_output "free-tier.md: there is no such file"
: > free-tier.md
show
expect_status 1
expect_output "free-tier.md: there is no such file"

# No merge attribute is set, so git merges here as GitHub and the test of a group do (decisions M95).
branches() {
  git init --quiet --initial-branch=main .
  log
  part limits "## The limits

A table."
  part entry-1 "$(numbered 1)"
  part entry-2 "$(numbered 2)"
  part 98 "$(named 98)"
  git add --all
  git commit --quiet --message base
  git update-ref refs/remotes/origin/main HEAD
}
# merged: merges the branch `theirs` into `ours`, and expects nothing left to resolve.
merged() {
  run git merge --no-edit theirs
  expect_status 0
  expect_no_output "CONFLICT"
  [ -z "$(git status --porcelain)" ] || fail "the merge left something to resolve: $(git status --porcelain)"
}

scenario "two branches that each added an entry merge with no conflict, and both entries are printed"
branches
git checkout --quiet -b theirs
part 141 "$(named 141)"
git add --all
git commit --quiet --message theirs
git checkout --quiet -b ours main
part 140 "$(named 140)"
git add --all
git commit --quiet --message ours
merged
show
expect_status 0
[ "$(names)" = "1 2 #98 #140 #141 " ] || fail "the entries came out as: $(names)"
run "$scripts/check-free-tier.sh" free-tier.md
expect_status 0
expect_output "free-tier log ok: 5 entries"

scenario "two branches that each changed another numbered entry, and one the limits, change different files and merge with no conflict"
branches
git checkout --quiet -b theirs
sed -i.bak 's/something/a day/' free-tier/entry-1.md
sed -i.bak 's/A table/Another table/' free-tier/limits.md
rm free-tier/*.bak
git commit --quiet --all --message theirs
git checkout --quiet -b ours main
sed -i.bak 's/something/a week/' free-tier/entry-2.md
rm free-tier/*.bak
git commit --quiet --all --message ours
[ -z "$(comm -12 <(git diff --name-only main theirs) <(git diff --name-only main ours))" ] || fail "both branches changed one file"
merged
show
expect_status 0
expect_output "- **Set:** a day."
expect_output "- **Set:** a week."
expect_output "Another table."

scenario "the repo's own log is printed whole: both tables, every entry check-free-tier.sh counts, none twice, and each line of each file"
cd "$root" || exit 1
run "$scripts/check-free-tier.sh"
expect_status 0
counted=$(sed -n 's/^free-tier log ok: \([0-9]*\) entries.*/\1/p' <<<"$out")
run "$scripts/free-tier.sh"
expect_status 0
[ "$(names | wc -w | tr -d ' ')" = "$counted" ] || fail "check-free-tier.sh counts $counted entries, and free-tier.sh printed $(names | wc -w)"
[ -z "$(names | tr ' ' '\n' | sort | uniq -d)" ] || fail "printed twice: $(names | tr ' ' '\n' | sort | uniq -d)"
for number in $(seq 1 16); do
  grep -q "^### $number\. " <<<"$out" || fail "entry $number, which the log held before entries were named after tickets, is not printed"
done
expect_output "| Service and plan | Limit | Used by | Per ticket | Ceiling |"
expect_output "| Sign | Which limit | What to buy |"
printed=$(sort -u <<<"$out")
lost=$(cat factory/free-tier.md factory/free-tier/*.md | sort -u | comm -23 - <(printf '%s\n' "$printed"))
[ -z "$lost" ] || fail "a line of the log's files is not printed: ${lost:0:200}"
[ -z "$(git ls-files factory | xargs grep -l '^### 16\. Three tickets in flight at most' | grep -v '^factory/free-tier/entry-16.md$')" ] \
  || fail "a committed file other than entry-16.md holds entry 16, so the whole log is committed somewhere"
