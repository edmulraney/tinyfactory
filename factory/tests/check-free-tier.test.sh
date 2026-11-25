#!/usr/bin/env bash
# Tests for factory/scripts/check-free-tier.sh: the free-tier log's shape (decisions H105c, H130e, H132a, H132b, H483).
. "$(dirname "$0")/helpers.sh"

# entry <n> [automated line]: an entry numbered in order, as free-tier/entry-<n>.md holds it.
entry() {
  printf '### %s. Setting %s\n\n- **Set:** something.\n- **Numbers:** 9 became 10.\n  - A line under it.\n%s\n' \
    "$1" "$1" "${2-- **Automated:** yes.}"
}
# named <id> [automated line]: an entry named after its ticket, as a ticket's file holds it.
named() {
  printf '### #%s. Setting %s\n\n- **Set:** something.\n- **Numbers:** 9 became 10.\n%s\n' \
    "$1" "$1" "${2-- **Automated:** yes.}"
}
part() {
  mkdir -p free-tier
  printf '%s\n' "$2" > "free-tier/$1.md"
}
# log [number...]: the log's own file, as factory/free-tier.md is, and beside it a file for each of these numbered entries.
log() {
  local number
  rm -rf free-tier
  printf '# Staying on the free tier\n\n**Add an entry whenever a setting changes.**\n\n## The limits\n\n## Log\n\n## When to start paying\n' > free-tier.md
  for number in "$@"; do part "entry-$number" "$(entry "$number")"; done
}

check() { run "$scripts/check-free-tier.sh" free-tier.md; }

refuses() {
  expect_status 1
  expect_output "$1"
}

scenario "passes entries numbered in order, each in a file named for it and ending with its Automated line"
log 1 3
part entry-2 "$(entry 2 '- **Automated:** no. The API rejects the setting.')"
check
expect_status 0
expect_output "free-tier log ok: 3 entries"

scenario "passes a log with no entry yet, and one whose Log section ends the file"
log
check
expect_status 0
expect_output "free-tier log ok: 0 entries"
printf '# Free tier\n\n## Log\n' > free-tier.md
part entry-1 "$(entry 1)"
check
expect_status 0

scenario "reads files written with Windows line endings"
log 1 2
part limits "## The limits

A table."
sed -i.bak 's/$/\r/' free-tier.md free-tier/entry-2.md free-tier/limits.md
rm free-tier.md.bak free-tier/*.bak
check
expect_status 0
expect_output "free-tier log ok: 2 entries"

scenario "refuses a numbered entry with text after its Automated line, with none, with two, or with only an indented one"
log 1
part entry-2 "$(entry 2)
- **Numbers:** added later."
part entry-3 "$(entry 3 '')"
part entry-4 "$(entry 4)
- **Automated:** no."
part entry-5 "$(entry 5 '  - **Automated:** yes.')"
check
refuses "free-tier/entry-2.md:1: entry 2 does not end with its Automated line"
expect_output "free-tier/entry-3.md:1: entry 3 does not end with its Automated line"
expect_output "free-tier/entry-4.md:1: entry 4 has 2 Automated lines, and an entry has one"
expect_output "free-tier/entry-5.md:1: entry 5 does not end with its Automated line"
expect_no_output "a merge often puts"
expect_no_output "entry 1 "
expect_no_output "free-tier log ok"

scenario "refuses a numbered entry in the file of another number, a second entry in its file, and a heading that is no numbered entry"
log 1
part entry-2 "$(entry 3)"
part entry-3 "$(entry 3)

$(entry 3)"
part entry-4 "### Screenshots

- **Automated:** yes."
part entry-5 "$(named 5)"
check
refuses "free-tier/entry-2.md:1: entry 3 does not belong in entry-2.md, which is named for entry 2"
expect_output "free-tier/entry-3.md:8: entry 3 is already at free-tier/entry-3.md:1"
expect_output 'free-tier/entry-4.md:1: the heading in entry-4.md is "### 4. <title>", and this is not: ### Screenshots'
expect_output 'free-tier/entry-5.md:1: the heading in entry-5.md is "### 5. <title>", and this is not: ### #5. Setting 5'
expect_output "free-tier/entry-4.md: this file holds no entry"
expect_no_output "entry-1.md"

scenario "refuses an entry or a table left in the log's own file, once for each section"
log 1
printf '# Free tier\n\nHow an entry is written.\nAnd why.\n\n## The limits\n\n| Service | Limit |\n|---|---|\n\n## Log\n\n%s\n\n%s\n' "$(entry 2)" "$(named 132)" > free-tier.md
check
refuses "free-tier.md:8: this file holds only how an entry is written and the headings of the log, and this line goes in a file of free-tier/: | Service | Limit |"
expect_output "free-tier.md:13: this file holds only how an entry is written and the headings of the log, and this line goes in a file of free-tier/: ### 2. Setting 2"
[ "$(grep -c 'this file holds only' <<<"$out")" = 2 ] || fail "a section's lines were not reported once"
expect_no_output "free-tier log ok"

scenario "refuses a log's own file with no Log section, and one that is not there"
printf '# Free tier\n\n## The limits\n' > free-tier.md
check
refuses 'free-tier.md: there is no "## Log" section'
run "$scripts/check-free-tier.sh" missing.md
refuses "missing.md: there is no such file"

scenario "passes a section's file that starts with its heading"
log 1
part limits "## The limits

Figures are the providers' own.

| Service | Limit |
|---|---|"
part when-to-pay "## When to start paying

| Sign | Which limit |
|---|---|"
check
expect_status 0
expect_output "free-tier log ok: 1 entries"

of_a_section='a file named for no ticket ("62.md") and no numbered entry ("entry-8.md") holds a section of the log other than Log, and starts with its heading, as it is in free-tier.md'

scenario "refuses a file that starts with no heading of the log, with the heading of Log, or named almost for a ticket or a numbered entry"
log 1
part costs "## What it costs

A table."
part log "## Log

$(named 132)"
part notes "$(named 132)"
part 0132 "$(named 132)"
part entry-02 "$(entry 2)"
check
refuses "free-tier/costs.md:1: $of_a_section"
expect_output "free-tier/log.md:1: $of_a_section"
expect_output "free-tier/notes.md:1: $of_a_section"
expect_output "free-tier/0132.md:1: $of_a_section"
expect_output "free-tier/entry-02.md:1: $of_a_section"
expect_no_output "free-tier log ok"

scenario "refuses a second file of one section, and a second heading in a section's file"
log 1
part limits "## The limits

A table."
part more-limits "## The limits

Another table."
part when-to-pay "## When to start paying

### #132. Setting 132

- **Automated:** yes."
check
refuses 'free-tier/more-limits.md:1: the section "## The limits" is already in free-tier/limits.md'
expect_output "free-tier/when-to-pay.md:3: a section's file holds its one heading, on its first line, and this is another: ### #132. Setting 132"

scenario "passes each ticket's entry in a file of its own, beside the entries numbered in order"
log 1 2
part 132 "$(named 132)"
part 140 "$(named 140a)

$(named 140b '- **Automated:** no. It cannot be.')"
check
expect_status 0
expect_output "free-tier log ok: 5 entries"

scenario "passes a ticket's file written with Windows line endings, or with no newline at its end"
log 1
part 132 "$(named 132)"
sed -i.bak 's/$/\r/' free-tier/132.md
rm free-tier/132.md.bak
printf '%s' "$(named 140)" > free-tier/140.md
check
expect_status 0
expect_output "free-tier log ok: 3 entries"

scenario "refuses an entry in the file of another ticket, and a numbered entry in a ticket's file"
log 1
part 132 "$(named 140)"
part 141 "$(entry 2)"
check
refuses "free-tier/132.md:1: entry #140 is named after ticket #140, and 132.md holds the entries of ticket #132 (#132, or #132a, #132b for several)"
expect_output 'free-tier/141.md:1: a heading in a ticket'"'"'s file is "### #<ticket>. <title>", and this is not: ### 2. Setting 2'

scenario "refuses two entries of one name in a ticket's file"
log 1
part 132 "$(named 132a)

$(named 132a)"
check
refuses "free-tier/132.md:7: entry #132a is already at free-tier/132.md:1"

scenario "refuses an empty file in the folder, a file with no entry, and a folder inside it"
log 1
part 132 "$(named 132)"
: > free-tier/140.md
part 141 "A note on what to do next."
mkdir free-tier/142.md
check
refuses "free-tier/140.md: this file is empty, and a file here holds entries or a section of the log"
expect_output "free-tier/141.md:1: only entries belong in this file, and this line is in none: A note on what to do next."
expect_output "free-tier/141.md: this file holds no entry"
expect_output "free-tier/142.md: only files belong beside the log, and this is no file"
expect_no_output "free-tier log ok"

scenario "refuses a file whose name does not end in .md, which free-tier.sh would not print"
log 1
part limits "## The limits

A table."
mv free-tier/limits.md free-tier/limits.txt
check
refuses 'free-tier/limits.txt: a file here is named "<name>.md", and free-tier.sh prints no other, so this one would be left out of the log'
expect_no_output "free-tier log ok"

scenario "refuses any other heading in a ticket's file, which would be printed as a section inside Log"
log 1
part 132 "$(named 132)

## When to stop"
check
refuses 'free-tier/132.md:7: a heading in a ticket'"'"'s file is "### #<ticket>. <title>", and this is not: ## When to stop'

scenario "refuses a ticket's entry that does not end with its one Automated line, naming its file"
log 1
part 132 "$(named 132 '')"
part 140 "$(named 140a '')
$(named 140b)
- **Automated:** yes."
check
refuses "free-tier/132.md:1: entry #132 does not end with its Automated line"
expect_output "free-tier/140.md:1: entry #140a does not end with its Automated line (a merge often puts the next entry, #140b, in front of it)"
expect_output "free-tier/140.md:5: entry #140b has 2 Automated lines, and an entry has one"
expect_no_output "entry 1 "

# on_main [number...]: a repository whose origin/main holds a log with these numbered entries (decisions H132b, H105b).
on_main() {
  git init --quiet --initial-branch=main .
  log "$@"
  git add --all
  git commit --quiet --message main
  git update-ref refs/remotes/origin/main HEAD
}
# checkout_without_main [number...]: a shallow checkout with no origin/main, as a pull request's checks run on.
checkout_without_main() {
  mkdir "$T/origin"
  (cd "$T/origin" && on_main "$@")
  git clone --quiet --depth=1 "file://$T/origin" .
  git update-ref -d refs/remotes/origin/HEAD
  git update-ref -d refs/remotes/origin/main
}
is_new="is new, and a new entry is named after the ticket that adds it: it goes in free-tier/<ticket>.md, headed \"### #<ticket>. <title>\"; decisions H132a"

scenario "refuses a numbered entry that main does not hold"
on_main 1 2
log 1 2 3
check
refuses "free-tier/entry-3.md:1: entry 3 $is_new"
expect_no_output "entry 2 is new"
expect_no_output "free-tier log ok"

scenario "passes the numbered entries main holds, rewritten or not, and a ticket's entry main does not hold"
on_main 1 2
part entry-2 "$(entry 2 '- **Automated:** no. It turned out it cannot be.')"
part 132 "$(named 132)"
check
expect_status 0
expect_output "free-tier log ok: 3 entries"
expect_no_output "could not be read"

scenario "passes the numbered entries main holds under Log in the log's own file, each moved to a file of its own"
git init --quiet --initial-branch=main .
printf '# Free tier\n\n## Log\n\n%s\n\n%s\n' "$(entry 1)" "$(entry 2)" > free-tier.md
git add --all
git commit --quiet --message main
git update-ref refs/remotes/origin/main HEAD
log 1 2
check
expect_status 0
expect_output "free-tier log ok: 2 entries"
log 1 2 3
check
refuses "entry 3 $is_new"
expect_no_output "entry 2 is new"

scenario "compares the numbers as numbers: entry 10 is new beside nine that main holds"
on_main 1 2 3 4 5 6 7 8 9
check
expect_status 0
log 1 2 3 4 5 6 7 8 9 10
check
refuses "entry 10 $is_new"
expect_no_output "entry 9 is new"

scenario "passes the numbered entries main holds with a gap between them, and refuses a new one in the gap"
on_main 1 2 4
check
expect_status 0
expect_output "free-tier log ok: 3 entries"
part entry-3 "$(entry 3)"
check
refuses "free-tier/entry-3.md:1: entry 3 $is_new"
expect_no_output "entry 4 is new"

scenario "takes every numbered entry of a log main does not hold as new"
on_main 1 2
mkdir other
mv free-tier.md free-tier other/
run "$scripts/check-free-tier.sh" other/free-tier.md
refuses "other/free-tier/entry-1.md:1: entry 1 is new"
expect_output "other/free-tier/entry-2.md:1: entry 2 is new"

scenario "fetches main for the rule in a checkout that holds none, as a pull request's checks do"
checkout_without_main 1 2
log 1 2 3
check
refuses "entry 3 $is_new"
expect_no_output "could not be read"
log 1 2
check
expect_status 0

scenario "reads the branch the pull request is for, not always main"
on_main 1 2
git update-ref refs/remotes/origin/trunk HEAD
git update-ref -d refs/remotes/origin/main
log 1 2 3
GITHUB_BASE_REF=trunk run "$scripts/check-free-tier.sh" free-tier.md
refuses "entry 3 $is_new"

scenario "skips the rule, and says so, when main cannot be fetched or there is no repository, and still checks the rest"
checkout_without_main 1 2
rm -rf "$T/origin"
log 1 2 3
check
expect_status 0
expect_output "origin/main could not be read, so the numbered entries were not checked for a new one"
expect_output "free-tier log ok: 3 entries"
part entry-3 "$(entry 3 "")"
check
refuses "entry 3 does not end with its Automated line"
rm -rf .git
log 1 2
check
expect_status 0
expect_output "origin/main could not be read, so the numbered entries were not checked for a new one"

scenario "the factory's own log keeps the shape, and is the one checked when none is named"
cd "$root" || exit 1
run "$scripts/check-free-tier.sh"
expect_status 0
expect_output "free-tier log ok:"
