#!/usr/bin/env bash
# Tests for only-merged-main.sh: a change is the same only after merges of main that left its diff as it read.
. "$(dirname "$0")/helpers.sh"

# A branch that leaves main with one changed line; $earlier is the commit a reader read.
a_branch() {
  git init -q -b main .
  seq 1 20 > app.txt
  echo one > other.txt
  git add . && git commit -q -m "start"
  git checkout -q -b feature
  sed 's/^10$/ten/' app.txt > app.new && mv app.new app.txt
  git commit -q -am "feat: spell ten"
  earlier=$(git rev-parse HEAD)
}
# on_main <bash>: a commit on main that the given bash makes; back on the branch after.
on_main() {
  git checkout -q main
  eval "$1"
  git add . && git commit -q -m "main moves"
  git checkout -q feature
}
# same [earlier] [head] [main]
same() { run "$scripts/only-merged-main.sh" "${1:-$earlier}" "${2:-$(git rev-parse HEAD)}" "${3:-main}"; }
short() { git rev-parse --short=7 "${1:-HEAD}"; }

scenario "the same commit, and one that only merges main, are the same change, and it says nothing"
a_branch
same
expect_status 0
on_main 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
same
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "commits named in short are the same as in full"
a_branch
on_main 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
same "$(short "$earlier")" "$(short)"
expect_status 0

scenario "a commit that is not a merge is not the same, even one that changes nothing"
a_branch
git commit -q --allow-empty -m "chore: nothing"
same
expect_status 1
expect_output "$(short), pushed since $(short "$earlier"), is not a merge of main"

scenario "a merge of a branch that is not main is not the same"
a_branch
git checkout -q -b side main
git commit -q --allow-empty -m "chore: on the side"
git checkout -q feature
git merge -q --no-edit side >/dev/null
same
expect_status 1
expect_output "$(short), pushed since $(short "$earlier"), merges a commit that is not on main"

scenario "a merge of main that needed a hand in the changed file is not the same"
a_branch
on_main 'sed "s/^10$/TEN/" app.txt > app.new && mv app.new app.txt'
git merge -q --no-edit main >/dev/null 2>&1 || true
sed -e '/^<<<<<<<\|^=======\|^>>>>>>>/d' -e '/^TEN$/d' app.txt > app.new && mv app.new app.txt
git commit -q -am "Merge main"
same
expect_status 1
expect_output "its change does not read the same at $(short) as at $(short "$earlier")"

scenario "an earlier commit the repo does not hold is not the same"
a_branch
same 1234567890123456789012345678901234567890
expect_status 1
expect_output "the earlier commit, 1234567, is no longer in the repo"

scenario "a head, or a main, the checkout does not hold stops it as not known"
a_branch
same "$earlier" 9999999999999999999999999999999999999999
expect_status 2
expect_output "The head commit 9999999999999999999999999999999999999999 is not in this checkout"
same "$earlier" "$earlier" origin/main
expect_status 2
expect_output "origin/main is not in this checkout"

scenario "git failing to read a commit's parents, or a change, stops it as not known"
a_branch
on_main 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
git=$(command -v git)
stub git 'case "$*" in "$(cat "$T/git-fails")"*) echo "git: failed: $*" >&2; exit 1 ;; esac; exec '"$git"' "$@"'
echo "rev-list --parents" > "$T/git-fails"
same
expect_status 2
expect_output "The parents of $(short) could not be read"
echo "merge-base main" > "$T/git-fails"
same
expect_status 2
expect_output "The change at $(short "$earlier") could not be read"

scenario "the installer runs exactly this script: its source names the git id of the file as it is"
pinned=$(sed -n 's/^  CARRY: \([0-9a-f]\{40\}\) .*/\1/p' "$root/factory/workflows/install-workflows.yml")
[ "$pinned" = "$(git -C "$root" hash-object factory/scripts/only-merged-main.sh)" ] \
  || fail "install-workflows.yml names ${pinned:-no id}, and only-merged-main.sh is $(git -C "$root" hash-object factory/scripts/only-merged-main.sh): set CARRY to that"
