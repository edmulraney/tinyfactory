#!/usr/bin/env bash
# Tests for settle-conflict.sh, on a repo whose main marks one list and two branches that each change it.
. "$(dirname "$0")/helpers.sh"

# repo: main holds list.md, which .gitattributes marks, and plain.md, which it does not.
repo() {
  git init --quiet --initial-branch main .
  printf 'list.md merge=list\n' > .gitattributes
  printf '| Step | Why |\n|---|---|\n| One | first |\n\nThe end.\n' > list.md
  printf 'one\n\nThe end.\n' > plain.md
  git add . && git commit --quiet -m "chore: start"
}
# branch <name> [--change] <file> <line> <text>: a branch from main whose one commit adds the text after that line
# of the file, or with `--change` writes the text in place of the line.
branch() {
  local name="$1" how='{ print } $0 == line { print text }'
  shift
  if [ "$1" = --change ]; then how='$0 == line { print text; next } { print }'; shift; fi
  git checkout --quiet -b "$name" main
  awk -v line="$2" -v text="$3" "$how" "$1" > "$1.new" && mv "$1.new" "$1"
  git commit --quiet -am "feat: $name" && git checkout --quiet main
}
settle() { run "$scripts/settle-conflict.sh" "$@"; }

scenario "two that change different files merge as GitHub merges them: it prints nothing"
repo
branch seven list.md "| One | first |" "| Seven | by seven |"
branch eight plain.md one "eight"
settle seven eight
expect_status 0
[ -z "$out" ] || fail "expected no output"

scenario "two that each add a row at one place of a marked list: it prints the tree of the merge that keeps both rows"
repo
branch seven list.md "| One | first |" "| Seven | by seven |"
branch eight list.md "| One | first |" "| Eight | by eight |"
settle seven eight
expect_status 0
[[ "$out" =~ ^[0-9a-f]{40}$ ]] || fail "expected the tree of the merge alone"
[ "$(git show "$out:list.md" 2>/dev/null | sed -n '3,5p')" = $'| One | first |\n| Seven | by seven |\n| Eight | by eight |' ] \
  || fail "expected the tree to hold both rows, got: $(git show "$out:list.md" 2>&1)"
[ -z "$(git status --porcelain)" ] || fail "expected the checkout to be as it was"
[ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing to be left in the temporary folder"

scenario "git's own merge of two that each add a row to a marked list: it stops at the conflict, as only this script keeps both"
repo
branch seven list.md "| One | first |" "| Seven | by seven |"
branch eight list.md "| One | first |" "| Eight | by eight |"
git checkout --quiet seven
run git merge eight
expect_status 1
expect_output "CONFLICT (content): Merge conflict in list.md"

scenario "two that change the same line of a marked list: it names the file, as git would keep both versions of the line"
repo
branch seven --change list.md "The end." "The end, as seven has it."
branch eight --change list.md "The end." "The end, as eight has it."
settle seven eight
expect_status 1
[ "$out" = list.md ] || fail "expected the file in conflict alone"

scenario "one adds a row where the other changed the row before it: it names the file"
repo
branch seven --change list.md "| One | first |" "| One | the first |"
branch eight list.md "| One | first |" "| Eight | by eight |"
settle seven eight
expect_status 1
[ "$out" = list.md ] || fail "expected the file in conflict alone"

scenario "two that each add a line at one place of a file no mark names: it names the file"
repo
branch seven plain.md one "seven"
branch eight plain.md one "eight"
settle seven eight
expect_status 1
[ "$out" = plain.md ] || fail "expected the file in conflict alone"

scenario "rows added to a marked list and a line changed twice in another file: it names the other file alone"
repo
branch seven list.md "| One | first |" "| Seven | by seven |"
git checkout --quiet seven && echo "seven" > plain.md && git commit --quiet -am "feat: more" && git checkout --quiet main
branch eight list.md "| One | first |" "| Eight | by eight |"
git checkout --quiet eight && echo "eight" > plain.md && git commit --quiet -am "feat: more" && git checkout --quiet main
settle seven eight
expect_status 1
[ "$out" = plain.md ] || fail "expected the file whose conflict stands alone"

scenario "the marks are read from the commit merged into: a commit that marks a file itself settles no conflict in it"
repo
branch seven plain.md one "seven"
branch eight plain.md one "eight"
git checkout --quiet eight && echo "plain.md merge=list" >> .gitattributes && git commit --quiet -am "chore: mark" && git checkout --quiet main
settle seven eight
expect_status 1
[ "$out" = plain.md ] || fail "expected the file in conflict alone"
# The other way round the mark is in the commit merged into, and holds.
settle eight seven
expect_status 0
[[ "$out" =~ ^[0-9a-f]{40}$ ]] || fail "expected the tree of the merge"

scenario "a commit git does not hold: it says so and exits 2, which is neither answer"
repo
settle main 1234567812345678123456781234567812345678
expect_status 2
expect_output "git holds no commit 1234567812345678123456781234567812345678, so whether it conflicts is not known."

scenario "two commits with no history in common: it says git could not merge them and exits 2"
repo
git checkout --quiet --orphan other && git commit --quiet -m "chore: another start" && git checkout --quiet main
settle main other
expect_status 2
expect_output "git could not merge"
expect_output "so whether they conflict is not known"
