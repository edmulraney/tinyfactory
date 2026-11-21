#!/usr/bin/env bash
# Tests for readme.sh, which prints the factory guide from its own file and each list's entries (decisions H484a).
. "$(dirname "$0")/helpers.sh"

# guide: the guide's own file, README.md, with a list that is a table and a list that is not.
guide() {
  printf '# The factory\n\n## Mission\n\nProve it.\n\n## Where things are\n\nA lookup.\n\n| What | Where |\n|---|---|\n\n## Known gaps\n' > README.md
}
entry() {
  mkdir -p "README/$1"
  printf '%s\n' "$3" > "README/$1/$2.md"
}

show() { run "$scripts/readme.sh" README.md; }

scenario "prints the guide's own file with each list's entries under its heading, a table's as its rows"
guide
entry where-things-are scripts '| Scripts | `factory/scripts/` |'
entry known-gaps previews '- **The header is sent on every request.**'
show
expect_status 0
[ "$out" = '# The factory

## Mission

Prove it.

## Where things are

A lookup.

| What | Where |
|---|---|
| Scripts | `factory/scripts/` |

## Known gaps

- **The header is sent on every request.**' ] || fail "the guide was not printed with each entry at the end of its list"

scenario "prints a list's entries in the order of their file names, the same in any language"
guide
entry known-gaps previews '- Previews.'
entry known-gaps Labels '- Labels.'
entry known-gaps events '- Events.'
LC_ALL=en_US.UTF-8 show
expect_status 0
expect_output '## Known gaps

- Labels.
- Events.
- Previews.'

scenario "prints a guide with no entry, and one with no folder, as its own file"
guide
show
expect_status 0
[ "$out" = "$(cat README.md)" ] || fail "the guide's own file was not printed as it is"
mkdir -p README/known-gaps
show
expect_status 0
[ "$out" = "$(cat README.md)" ] || fail "the guide's own file was not printed as it is"

scenario "prints an entry without the blank lines around it, and every line of one that holds several"
guide
mkdir -p README/known-gaps
printf '\n\n- Events.\n  More on events.\n\n' > README/known-gaps/events.md
printf '%s' '- Previews.' > README/known-gaps/previews.md
show
expect_status 0
expect_output '## Known gaps

- Events.
  More on events.
- Previews.'
"$scripts/readme.sh" README.md > "$T/printed"
[ "$(tail -n 1 "$T/printed")" = "- Previews." ] || fail "the guide's last line is not its last entry"

scenario "prints an entry once, and loses none, when a file has Windows line endings"
guide
entry where-things-are scripts '| Scripts | `factory/scripts/` |'
entry known-gaps previews '- Previews.'
sed -i.bak 's/$/\r/' README.md README/known-gaps/previews.md
rm README.md.bak README/known-gaps/previews.md.bak
show
expect_status 0
expect_output '|---|---|
| Scripts | `factory/scripts/` |

## Known gaps

- Previews.'
expect_no_output $'\r'

scenario "reads the factory's guide when none is named"
mkdir factory
guide
mv README.md factory/README.md
mkdir -p factory/README/known-gaps
echo '- Previews.' > factory/README/known-gaps/previews.md
run "$scripts/readme.sh"
expect_status 0
expect_output '## Known gaps

- Previews.'

scenario "stops, and prints no guide, when a folder is named after no heading"
guide
entry known-gasp previews '- Previews.'
show
expect_status 1
expect_output "README.md: no heading has the folder known-gasp, which holds README/known-gasp/previews.md"
expect_no_output "Prove it."

scenario "stops, and prints no guide, when an entry of a table is not a row"
guide
entry where-things-are scripts 'Scripts are in `factory/scripts/`.'
show
expect_status 1
expect_output "README.md: the list with the folder where-things-are is a table"
expect_no_output "Prove it."

scenario "stops when the guide's own file holds an entry of a list whose entries are in files"
guide
entry where-things-are scripts '| Scripts | `factory/scripts/` |'
entry known-gaps previews '- Previews.'
echo '- Events.' >> README.md
show
expect_status 1
expect_output "README.md: the list with the folder known-gaps ends with an entry in README.md itself. Move it to a file of its own in that folder: - Events."
guide
replace_first "$(cat README.md)" '|---|---|' '|---|---|
| Tests | `factory/tests/` |'
printf '%s\n' "$replaced" > README.md
show
expect_status 1
expect_output "README.md: the list with the folder where-things-are ends with an entry in README.md itself"
expect_no_output "Prove it."

scenario "stops when a file is in no list's folder, or is not named as an entry"
guide
mkdir README
echo '- Previews.' > README/previews.md
show
expect_status 1
expect_output "README/previews.md: an entry is a file in the folder of its list"
rm README/previews.md
mkdir README/known-gaps
echo '- Previews.' > README/known-gaps/previews.txt
show
expect_status 1
expect_output "README/known-gaps/previews.txt: an entry is a file named <entry>.md"

scenario "stops when the guide is missing or empty"
show
expect_status 1
expect_output "README.md: there is no such file"
: > README.md
show
expect_status 1
expect_output "README.md: there is no such file"

# No merge attribute is set, so git merges here as GitHub and the test of a group do (decisions M95).
branches() {
  git init --quiet --initial-branch=main .
  guide
  entry known-gaps events '- Events.'
  git add --all
  git commit --quiet --message base
}

scenario "two branches, one adding an entry and one changing another, merge with no conflict, and both are printed"
branches
git checkout --quiet -b theirs
entry known-gaps previews '- Previews.'
git add --all
git commit --quiet --message theirs
git checkout --quiet -b ours main
entry known-gaps events '- Events, changed.'
entry known-gaps labels '- Labels.'
git add --all
git commit --quiet --message ours
run git merge --no-edit theirs
expect_status 0
expect_no_output "CONFLICT"
[ -z "$(git status --porcelain)" ] || fail "the merge left something to resolve: $(git status --porcelain)"
show
expect_status 0
expect_output '## Known gaps

- Events, changed.
- Labels.
- Previews.'

scenario "the same two branches conflict when each adds its entry to the guide's own file, as before"
branches
git checkout --quiet -b theirs
echo '- Previews.' >> README.md
git commit --quiet --all --message theirs
git checkout --quiet -b ours main
echo '- Labels.' >> README.md
git commit --quiet --all --message ours
run git merge --no-edit theirs
expect_status 1
expect_output "CONFLICT (content): Merge conflict in README.md"

scenario "the repo's own guide is printed whole: the mission, the principles and every entry, none twice"
cd "$root" || exit 1
run "$scripts/readme.sh"
expect_status 0
expect_output "## Mission"
expect_output "## Principles"
while IFS= read -r line; do
  grep -qxF -- "$line" <<<"$out" || fail "a line of factory/README.md is not printed: ${line:0:60}"
done < factory/README.md
entries=0
for entry in factory/README/*/*.md; do
  entries=$((entries + 1))
  while IFS= read -r line; do
    [ "$(grep -cxF -- "$line" <<<"$out")" = 1 ] || fail "a line of $entry is not printed once: ${line:0:60}"
  done < "$entry"
done
[ "$entries" -gt 0 ] || fail "expected the lists' entries in factory/README/, and found none"
for list in "Where things are" "What the factory measures" "Known gaps"; do
  grep -qxF "## $list" factory/README.md || fail "factory/README.md has no heading for the list: $list"
done
