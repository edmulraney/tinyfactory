#!/usr/bin/env bash
# Says whether a pull request's change is the same at its head as at an earlier commit, with only merges of main since.
# Usage: only-merged-main.sh <earlier-commit> <head-commit> <main-ref>
#        Run in a checkout that holds the whole history of the head and of main.
#        The same: exits 0. Not the same: prints why and exits 1. Could not tell: says why on stderr and exits 2.
#        It calls nothing but git and reads no other file: the installer runs it by its git id (decisions W456).
set -euo pipefail

usage='Usage: only-merged-main.sh <earlier-commit> <head-commit> <main-ref>'
earlier="${1:?$usage}"; head="${2:?$usage}"; main="${3:?$usage}"
differs() { echo "$1"; exit 1; }
die() { echo "$1" >&2; exit 2; }

# Both as git names them in full, to compare one with the other.
full=$(git rev-parse --quiet --verify "$head^{commit}") || die "The head commit $head is not in this checkout"
head="$full"
git rev-parse --quiet --verify "$main^{commit}" >/dev/null || die "$main is not in this checkout"
full=$(git rev-parse --quiet --verify "$earlier^{commit}" 2>/dev/null) || differs "the earlier commit, ${earlier:0:7}, is no longer in the repo"
earlier="$full"

# Along the branch's own line (first parents): a branch that was rewritten never reaches the earlier commit.
commit="$head"
while [ "$commit" != "$earlier" ]; do
  line=$(git rev-list --parents -n 1 "$commit") || die "The parents of ${commit:0:7} could not be read"
  # shellcheck disable=SC2086
  set -- $line
  [ $# -eq 3 ] || differs "${commit:0:7}, pushed since ${earlier:0:7}, is not a merge of main"
  git merge-base --is-ancestor "$3" "$main" 2>/dev/null \
    || differs "${commit:0:7}, pushed since ${earlier:0:7}, merges a commit that is not on main"
  commit="$2"
done

# The diff a reader read, without the blob ids and line numbers a merge elsewhere moves (decisions A160b).
change() {
  local base
  base=$(git merge-base "$main" "$1") || return 1
  git diff --no-color --no-ext-diff --no-textconv --no-renames --binary --unified=3 "$base" "$1" \
    | sed -E -e '/^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]+)?$/d' -e 's/^@@ -[0-9,]+ \+[0-9,]+ @@.*$/@@/'
}
before=$(change "$earlier") || die "The change at ${earlier:0:7} could not be read"
after=$(change "$head") || die "The change at ${head:0:7} could not be read"
[ "$before" = "$after" ] || differs "its change does not read the same at ${head:0:7} as at ${earlier:0:7}"
