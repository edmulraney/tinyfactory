#!/usr/bin/env bash
# Tests for free-tier.sh, which prints the log from its own file and the tickets' files (decisions H130e, H132a).
. "$(dirname "$0")/helpers.sh"

# numbered <n>: an entry numbered in order, as the log's own file holds them.
numbered() { printf '### %s. Setting %s\n\n- **Set:** something.\n- **Automated:** yes.\n' "$1" "$1"; }
# named <id>: an entry named after its ticket, as a ticket's file holds it.
named() { printf '### #%s. Setting %s\n\n- **Set:** something.\n- **Automated:** yes.\n' "$1" "$1"; }
# log <text>: the log's own file, free-tier.md, whose Log section holds this text.
log() {
  printf '# Staying on the free tier\n\nHow an entry is written.\n\n## Log\n\n%s\n\n## When to start paying\n\n| Sign | Which limit |\n|---|---|\n' \
    "$1" > free-tier.md
}
# ticket <n> <text>: that ticket's file in the log's folder.
ticket() {
  mkdir -p free-tier
  printf '%s\n' "$2" > "free-tier/$1.md"
}
names() { sed -n 's/^### \(#\{0,1\}[0-9]*[a-z]\{0,1\}\)\. .*/\1/p' <<<"$out" | tr '\n' ' '; }

show() { run "$scripts/free-tier.sh" free-tier.md; }

scenario "prints the log's own file with each ticket's entry at the end of the Log section"
log "$(numbered 1)

$(numbered 2)"
ticket 132 "$(named 132)"
show
expect_status 0
[ "$out" = "# Staying on the free tier

How an entry is written.

## Log

$(numbered 1)

$(numbered 2)

$(named 132)

## When to start paying

| Sign | Which limit |
|---|---|" ] || fail "the log was not printed with the ticket's entry after entry 2 and before the next section"

scenario "prints the tickets' entries in the order of their numbers, not of their file names"
log "$(numbered 1)"
ticket 140 "$(named 140)"
ticket 98 "$(named 98)"
ticket 1000 "$(named 1000)"
ticket 132 "$(named 132a)

$(named 132b)"
show
expect_status 0
[ "$(names)" = "1 #98 #132a #132b #140 #1000 " ] || fail "the entries came out as: $(names)"

scenario "prints a log with no ticket's entry, and one with no folder, as its own file"
log "$(numbered 1)"
show
expect_status 0
[ "$out" = "$(cat free-tier.md)" ] || fail "the log's own file was not printed as it is"
mkdir free-tier
show
expect_status 0
[ "$out" = "$(cat free-tier.md)" ] || fail "the log's own file was not printed as it is"

scenario "prints the entries under a Log section that holds none, and under one that ends the file"
log ""
ticket 132 "$(named 132)"
show
expect_status 0
expect_output "## Log

$(named 132)

## When to start paying"
printf '# Free tier\n\n## Log\n\n%s\n' "$(numbered 1)" > free-tier.md
show
expect_status 0
[ "$out" = "# Free tier

## Log

$(numbered 1)

$(named 132)" ] || fail "the ticket's entry was not printed at the end of the file"

scenario "puts one blank line between entries, whatever blank lines a ticket's file starts or ends with"
log "$(numbered 1)"
mkdir free-tier
printf '\n\n%s\n\n\n' "$(named 98)" > free-tier/98.md
printf '%s' "$(named 132)" > free-tier/132.md
show
expect_status 0
expect_output "$(numbered 1)

$(named 98)

$(named 132)

## When to start paying"

scenario "prints an entry once, and loses none, when a file has Windows line endings"
log "$(numbered 1)"
ticket 98 "$(named 98)"
ticket 132 "$(named 132)"
sed -i.bak 's/$/\r/' free-tier/98.md free-tier.md
rm free-tier/98.md.bak free-tier.md.bak
show
expect_status 0
[ "$(names)" = "1 #98 #132 " ] || fail "the entries came out as: $(names)"
expect_no_output $'\r'

scenario "reads the factory's log when none is named"
mkdir factory
log "$(numbered 1)"
mv free-tier.md factory/free-tier.md
mkdir factory/free-tier
named 132 > factory/free-tier/132.md
run "$scripts/free-tier.sh"
expect_status 0
[ "$(names)" = "1 #132 " ] || fail "the entries came out as: $(names)"

scenario "stops, and prints no log, when there is no Log section to put the entries under"
printf '# Free tier\n\n## The limits\n\nA table.\n' > free-tier.md
ticket 132 "$(named 132)"
show
expect_status 1
expect_output 'free-tier.md: there is no "## Log" section to print the entries under'
expect_no_output "The limits"

scenario "stops when the log is missing or empty"
show
expect_status 1
expect_output "free-tier.md: there is no such file"
: > free-tier.md
show
expect_status 1
expect_output "free-tier.md: there is no such file"

# No merge attribute is set, so git merges here as GitHub and the fits-main job do (decisions M95).
branches() {
  git init --quiet --initial-branch=main .
  log "$(numbered 1)"
  ticket 98 "$(named 98)"
  git add --all
  git commit --quiet --message base
  git update-ref refs/remotes/origin/main HEAD
}

scenario "two branches that each added an entry merge with no conflict, and both entries are printed"
branches
git checkout --quiet -b theirs
ticket 141 "$(named 141)"
git add --all
git commit --quiet --message theirs
git checkout --quiet -b ours main
ticket 140 "$(named 140)"
git add --all
git commit --quiet --message ours
run git merge --no-edit theirs
expect_status 0
expect_no_output "CONFLICT"
[ -z "$(git status --porcelain)" ] || fail "the merge left something to resolve: $(git status --porcelain)"
show
expect_status 0
[ "$(names)" = "1 #98 #140 #141 " ] || fail "the entries came out as: $(names)"
run "$scripts/check-free-tier.sh" free-tier.md
expect_status 0
expect_output "free-tier log ok: 4 entries"

scenario "the same two branches conflict when each adds the next numbered entry to the log's own file, as before"
branches
git checkout --quiet -b theirs
printf '\n%s\n' "$(numbered 2)" >> free-tier.md
git commit --quiet --all --message theirs
git checkout --quiet -b ours main
printf '\n%s\n' "$(numbered 2)" | sed 's/Setting 2/Another setting/' >> free-tier.md
git commit --quiet --all --message ours
run git merge --no-edit theirs
expect_status 1
expect_output "CONFLICT (content): Merge conflict in free-tier.md"

scenario "the repo's own log is printed whole: every entry check-free-tier.sh counts, none twice"
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
while IFS= read -r line; do
  grep -qxF -- "$line" <<<"$out" || fail "a line of factory/free-tier.md is not printed: ${line:0:60}"
done < factory/free-tier.md
