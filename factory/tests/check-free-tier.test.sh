#!/usr/bin/env bash
# Tests for factory/scripts/check-free-tier.sh: the free-tier log's shape (decisions H105c, H130e, H132a, H132b).
. "$(dirname "$0")/helpers.sh"

# entry <n> [automated line]: one entry of the log, as the file writes them.
entry() {
  printf '### %s. Setting %s\n\n- **Set:** something.\n- **Numbers:** 9 became 10.\n  - A line under it.\n%s\n' \
    "$1" "$1" "${2-- **Automated:** yes.}"
}

# log <text>: a file like factory/free-tier.md whose Log section holds this text.
log() {
  printf '# Staying on the free tier\n\n**Add an entry whenever a setting changes.**\n\n## Log\n\n%s\n\n## When to start paying\n\n| Sign | Which limit |\n|---|---|\n' \
    "$1" > free-tier.md
}

check() { run "$scripts/check-free-tier.sh" free-tier.md; }

refuses() {
  expect_status 1
  expect_output "$1"
}

scenario "passes entries numbered in order, each ending with its Automated line"
log "$(entry 1)

$(entry 2 '- **Automated:** no. The API rejects the setting.')

$(entry 3)"
check
expect_status 0
expect_output "free-tier log ok: 3 entries"

scenario "passes a log with no entry yet, and a log that ends the file"
log ""
check
expect_status 0
expect_output "free-tier log ok: 0 entries"
printf '# Free tier\n\n## Log\n\n%s\n' "$(entry 1)" > free-tier.md
check
expect_status 0

scenario "reads a file written with Windows line endings"
log "$(entry 1)

$(entry 2)"
sed -i.bak 's/$/\r/' free-tier.md
check
expect_status 0

scenario "refuses an entry put in front of the previous entry's Automated line, naming both"
log "$(entry 1)

$(entry 2 '')
$(entry 3 '')
- **Automated:** yes."
check
refuses "free-tier.md:14: entry 2 does not end with its Automated line (a merge often puts the next entry, 3, in front of it)"
expect_no_output "entry 3 does not"
expect_no_output "entry 1 "

scenario "refuses the same slip when both entries' Automated lines survive the merge"
log "$(entry 1 '')

$(entry 2 '- **Automated:** no. It cannot be.')
- **Automated:** yes."
check
refuses "entry 1 does not end with its Automated line (a merge often puts the next entry, 2, in front of it)"
expect_output "free-tier.md:13: entry 2 has 2 Automated lines, and an entry has one"

scenario "refuses an entry with text after its Automated line"
log "$(entry 1)
- **Numbers:** added later."
check
refuses "free-tier.md:7: entry 1 does not end with its Automated line"
expect_no_output "a merge often"

scenario "refuses a last entry with no Automated line"
log "$(entry 1)

$(entry 2 '')"
check
refuses "entry 2 does not end with its Automated line"
expect_no_output "entry 1 "

scenario "does not take an indented Automated line for the entry's own"
log "$(entry 1 '  - **Automated:** yes.')"
check
refuses "entry 1 does not end with its Automated line"

scenario "refuses two entries with the same number"
log "$(entry 1)

$(entry 2)

$(entry 2)

$(entry 3)"
check
refuses "free-tier.md:21: entry 2 follows entry 2, and should be entry 3: entries count 1, 2, 3 with no gap or repeat"
expect_no_output "entry 3 follows"

scenario "refuses a gap in the numbers, and a log that does not start at 1"
log "$(entry 1)

$(entry 3)"
check
refuses "entry 3 follows entry 1, and should be entry 2"
log "$(entry 2)"
check
refuses "entry 2 follows the Log heading, and should be entry 1"

scenario "refuses a heading with no blank line above it"
log "$(entry 1)
$(entry 2)"
check
refuses "free-tier.md:13: the heading of entry 2 needs a blank line above it"

scenario "refuses a heading under Log that is not a numbered entry"
log "$(entry 1)

### Screenshots

- **Automated:** yes."
check
refuses 'free-tier.md:14: a heading under Log is "### <n>. <title>", and this is not: ### Screenshots'

scenario "leaves headings outside the Log alone"
log "$(entry 1)"
printf '\n### 7. A note under another section\n' >> free-tier.md
check
expect_status 0
expect_output "free-tier log ok: 1 entries"

scenario "reports every problem in one run"
log "$(entry 1 '')
$(entry 3)"
check
expect_status 1
expect_output "entry 1 does not end with its Automated line"
expect_output "entry 3 follows entry 1"
expect_output "the heading of entry 3 needs a blank line above it"
expect_no_output "free-tier log ok"

scenario "refuses a file with no Log section, and a file that is not there"
printf '# Free tier\n\n%s\n' "$(entry 1)" > free-tier.md
check
refuses 'free-tier.md: there is no "## Log" section'
run "$scripts/check-free-tier.sh" missing.md
refuses "missing.md: there is no such file"

# named <id> [automated line]: an entry named after its ticket, as a ticket's file holds it.
named() {
  printf '### #%s. Setting %s\n\n- **Set:** something.\n- **Numbers:** 9 became 10.\n%s\n' \
    "$1" "$1" "${2-- **Automated:** yes.}"
}
# ticket <n> <text>: that ticket's file in the log's folder.
ticket() {
  mkdir -p free-tier
  printf '%s\n' "$2" > "free-tier/$1.md"
}

scenario "passes each ticket's entry in a file of its own, beside the entries numbered in order"
log "$(entry 1)

$(entry 2)"
ticket 132 "$(named 132)"
ticket 140 "$(named 140a)

$(named 140b '- **Automated:** no. It cannot be.')"
check
expect_status 0
expect_output "free-tier log ok: 5 entries"

scenario "passes a ticket's file written with Windows line endings, or with no newline at its end"
log "$(entry 1)"
ticket 132 "$(named 132)"
sed -i.bak 's/$/\r/' free-tier/132.md
rm free-tier/132.md.bak
printf '%s' "$(named 140)" > free-tier/140.md
check
expect_status 0
expect_output "free-tier log ok: 3 entries"

scenario "refuses an entry named after its ticket that is in the log's own file"
log "$(entry 1)

$(named 132)"
check
refuses "free-tier.md:14: entry #132 is named after its ticket, so it goes in free-tier/132.md, and this file holds only the entries numbered in order"
expect_no_output "free-tier log ok"

scenario "refuses an entry in the file of another ticket, and a numbered entry in a ticket's file"
log "$(entry 1)"
ticket 132 "$(named 140)"
ticket 141 "$(entry 2)"
check
refuses "free-tier/132.md:1: entry #140 is named after ticket #140, and 132.md holds the entries of ticket #132 (#132, or #132a, #132b for several)"
expect_output 'free-tier/141.md:1: a heading in a ticket'"'"'s file is "### #<ticket>. <title>", and this is not: ### 2. Setting 2'

scenario "refuses two entries of one name in a ticket's file"
log "$(entry 1)"
ticket 132 "$(named 132a)

$(named 132a)"
check
refuses "free-tier/132.md:7: entry #132a is already at free-tier/132.md:1"

scenario "refuses a file in the folder that is not named for a ticket"
log "$(entry 1)"
ticket notes "$(named 132)"
ticket 0132 "$(named 132)"
check
refuses 'free-tier/notes.md:1: a file here holds one ticket'"'"'s entry and is named for it, like "62.md"'
expect_output 'free-tier/0132.md:1: a file here holds one ticket'"'"'s entry and is named for it, like "62.md"'

scenario "refuses an empty file in the folder, a file with no entry, and a folder inside it"
log "$(entry 1)"
ticket 132 "$(named 132)"
: > free-tier/140.md
ticket 141 "A note on what to do next."
mkdir free-tier/142.md
check
refuses "free-tier/140.md: a ticket's file holds at least one entry"
expect_output "free-tier/141.md:1: only entries belong in a ticket's file, and this line is in none: A note on what to do next."
expect_output "free-tier/141.md: a ticket's file holds at least one entry"
expect_output "free-tier/142.md: only the files of tickets belong beside the log, and this is no file"
expect_no_output "free-tier log ok"

scenario "refuses any other heading in a ticket's file, which would end the Log section where it is printed"
log "$(entry 1)"
ticket 132 "$(named 132)

## When to stop"
check
refuses 'free-tier/132.md:7: a heading in a ticket'"'"'s file is "### #<ticket>. <title>", and this is not: ## When to stop'

scenario "refuses a ticket's entry that does not end with its one Automated line, naming its file"
log "$(entry 1)"
ticket 132 "$(named 132 '')"
ticket 140 "$(named 140a '')
$(named 140b)
- **Automated:** yes."
check
refuses "free-tier/132.md:1: entry #132 does not end with its Automated line"
expect_output "free-tier/140.md:1: entry #140a does not end with its Automated line (a merge often puts the next entry, #140b, in front of it)"
expect_output "free-tier/140.md:5: the heading of entry #140b needs a blank line above it"
expect_output "free-tier/140.md:5: entry #140b has 2 Automated lines, and an entry has one"
expect_no_output "entry 1 "

# on_main <text>: a repository whose origin/main holds a log with this text under Log (decisions H132b, H105b).
on_main() {
  git init --quiet --initial-branch=main .
  log "$1"
  git add --all
  git commit --quiet --message main
  git update-ref refs/remotes/origin/main HEAD
}
# checkout_without_main <text>: a shallow checkout with no origin/main, as a pull request's checks run on.
checkout_without_main() {
  mkdir "$T/origin"
  (cd "$T/origin" && on_main "$1")
  git clone --quiet --depth=1 "file://$T/origin" .
  git update-ref -d refs/remotes/origin/HEAD
  git update-ref -d refs/remotes/origin/main
}
two="$(entry 1)

$(entry 2)"
is_new="is new, and a new entry is named after the ticket that adds it: it goes in free-tier/<ticket>.md, headed \"### #<ticket>. <title>\"; decisions H132a"

scenario "refuses a numbered entry that main does not hold"
on_main "$two"
log "$two

$(entry 3)"
check
refuses "free-tier.md:21: entry 3 $is_new"
expect_no_output "entry 2 is new"
expect_no_output "free-tier log ok"

scenario "passes the numbered entries main holds, rewritten or not, and a ticket's entry main does not hold"
on_main "$two"
log "$(entry 1)

$(entry 2 '- **Automated:** no. It turned out it cannot be.')"
ticket 132 "$(named 132)"
check
expect_status 0
expect_output "free-tier log ok: 3 entries"
expect_no_output "could not be read"

scenario "compares the numbers as numbers: entry 10 is new beside nine that main holds"
nine=$(for number in 1 2 3 4 5 6 7 8 9; do entry "$number"; echo; done)
on_main "$nine"
check
expect_status 0
log "$nine
$(entry 10)"
check
refuses "entry 10 $is_new"
expect_no_output "entry 9 is new"

scenario "takes every numbered entry of a log main does not hold as new"
on_main "$two"
mkdir other
mv free-tier.md other/free-tier.md
run "$scripts/check-free-tier.sh" other/free-tier.md
refuses "other/free-tier.md:7: entry 1 is new"
expect_output "other/free-tier.md:14: entry 2 is new"

scenario "fetches main for the rule in a checkout that holds none, as a pull request's checks do"
checkout_without_main "$two"
log "$two

$(entry 3)"
check
refuses "entry 3 $is_new"
expect_no_output "could not be read"
log "$two"
check
expect_status 0

scenario "reads the branch the pull request is for, not always main"
on_main "$two"
git update-ref refs/remotes/origin/trunk HEAD
git update-ref -d refs/remotes/origin/main
log "$two

$(entry 3)"
GITHUB_BASE_REF=trunk run "$scripts/check-free-tier.sh" free-tier.md
refuses "entry 3 $is_new"

scenario "skips the rule, and says so, when main cannot be fetched or there is no repository, and still checks the rest"
checkout_without_main "$two"
rm -rf "$T/origin"
log "$two

$(entry 3)"
check
expect_status 0
expect_output "origin/main could not be read, so the numbered entries were not checked for a new one"
expect_output "free-tier log ok: 3 entries"
log "$two

$(entry 4)"
check
refuses "entry 4 follows entry 2"
rm -rf .git
log "$two"
check
expect_status 0
expect_output "origin/main could not be read, so the numbered entries were not checked for a new one"

scenario "the factory's own file keeps the shape, and is the one checked when none is named"
cd "$root" || exit 1
run "$scripts/check-free-tier.sh"
expect_status 0
expect_output "free-tier log ok:"
