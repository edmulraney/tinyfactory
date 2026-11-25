#!/usr/bin/env bash
# Runs the factory scripts' own tests, in factory/tests/*.test.sh, as the first part of `pnpm test` (decisions H3).
# Usage: test-factory.sh [<commit-of-main>]   (from the repo root)
#        Only the test files that the change since that commit can affect run (decisions H429a). With no commit,
#        the commit is where the branch left origin/main (H596a). Every file runs when that cannot be worked out (H429d).
set -euo pipefail

given="${1:-}"
main=$given
[ -n "$given" ] || main=$(git merge-base origin/main HEAD 2>/dev/null) || main=""

# Every file is run even after one fails, so one push shows everything that is broken (decisions H21).
failed=0
passed=0
files=0
# Listed on a line of its own, so a failed listing is not taken for a folder with no test in it (decisions H106).
# Paths as they are: git would put one with a letter outside ASCII in quotes, and no such file could be run.
if ! tests=$(git -c core.quotePath=false ls-files 'factory/tests/*.test.sh'); then
  echo "test-factory.sh must be run inside a git repository: it could not list the test files with git ls-files, so no test was run."
  exit 1
fi

# affected: prints the test files that the change since $main can affect (decisions H429a, H429b, H429e).
affected() {
  local names found boundary='A-Za-z0-9_-'
  # What every test file is run by, or reads by its folder (decisions H429c).
  if grep -qE '^(factory/workflows/|\.github/|factory/scripts/test-factory\.sh$|package\.json$|pnpm-workspace\.yaml$)' <<<"$changed"; then
    echo "$tests"
    return 0
  fi
  # A changed file by its name, and a changed script's own test file, which H3 names after it.
  names=$(sed -E 's|.*/||' <<<"$changed"; sed -n -E 's|^factory/scripts/(.*)\.sh$|\1.test.sh|p' <<<"$changed")
  while :; do
    names=$(sort -u <<<"$names" | sed '/^$/d')
    [ -n "$names" ] || return 0
    # Only what a pattern reads as more than itself is escaped: a letter outside ASCII stays whole (decisions H632a).
    names_pattern="($(sed -E 's/[][(){}.*+?^$|\]/\\&/g' <<<"$names" | paste -sd '|' -))"
    # The shell files that hold one of the names as a whole word, on a line that is not a comment.
    found=$(git -c core.quotePath=false grep -l -E -e "^[[:space:]]*([^#[:space:]].*[^$boundary]|[^#[:space:]$boundary])?$names_pattern(\$|[^$boundary])" -- '*.sh') \
      || [ $? -eq 1 ] || return 1
    found=$(sed -E 's|.*/||' <<<"$found"$'\n'"$names" | sort -u | sed '/^$/d')
    [ "$found" != "$names" ] || break
    names=$found
  done
  grep -E "^factory/tests/$names_pattern\$" <<<"$tests" || true
}
if [ -z "$main" ]; then
  echo "test-factory.sh found no commit that this branch shares with origin/main, so every test file runs."
# Read as checks-needed.sh reads them (decisions H268d), with what the working tree holds uncommitted (H596a).
elif ! changed=$(git -c core.quotePath=false diff --name-only --no-renames "$main" \
  && git -c core.quotePath=false ls-files --others --exclude-standard); then
  echo "test-factory.sh could not work out which test files the change since $main can affect, so every test file runs."
elif [ -z "$given" ] && [ -z "$changed" ]; then
  # A run on main itself is a test of main (decisions H596b).
  echo "Nothing has changed since origin/main, so every test file runs."
elif chosen=$(affected); then
  echo "The change since $main can affect $(grep -c . <<<"$chosen" || true) of the $(grep -c . <<<"$tests" || true) test files, and only those run."
  tests=$chosen
else
  echo "test-factory.sh could not work out which test files the change since $main can affect, so every test file runs."
fi

# As many files at once as the machine has processors, each writing to a file of its own (decisions H249a, H249b).
if ! processors=$(getconf _NPROCESSORS_ONLN); then
  echo "test-factory.sh could not read how many processors the machine has with getconf, so no test was run."
  exit 1
fi
if ! results=$(mktemp -d); then
  echo "test-factory.sh could not make a folder for the test files' output with mktemp, so no test was run."
  exit 1
fi
trap 'rm -rf "$results"' EXIT
number=0
numbered=""
for file in $tests; do
  number=$((number + 1))
  numbered+="$number $file"$'\n'
done
# Each file's result goes to standard error as it finishes, so a run that is cut off names what failed (decisions H699).
# shellcheck disable=SC2016
if [ -n "$numbered" ] && ! printf '%s' "$numbered" | xargs -P "$processors" -n 2 \
  bash -c 'status=0; bash "$2" > "$0/$1.report" 2>&1 || status=$?; echo "$status" > "$0/$1.status"
    if [ "$status" -eq 0 ] && grep -q "^ok - " "$0/$1.report" && ! grep -q "^not ok - " "$0/$1.report"; then
      echo "ok $2" >&2; else echo "FAILED $2" >&2; fi' "$results"; then
  echo "test-factory.sh could not run the test files with xargs, so their tests are not counted as passed."
  exit 1
fi
# Read back in the order listed, so a failure reads as it did when the files ran in turn (decisions H249c).
number=0
for file in $tests; do
  number=$((number + 1))
  files=$((files + 1))
  if ! status=$(cat "$results/$number.status") || ! report=$(cat "$results/$number.report"); then
    echo "FAILED $file: test-factory.sh could not read what it printed, so its tests are not counted as passed."
    failed=1
    continue
  fi
  ran=$(grep -c '^ok - ' <<<"$report" || true)
  passed=$((passed + ran))
  if grep -q '^not ok - ' <<<"$report"; then
    grep -v '^ok - ' <<<"$report" | sed "s|^not ok - |FAILED $file: |"
    failed=1
  elif [ "$status" -ne 0 ]; then
    # The file itself broke: tests that never ran would read as tests that passed (decisions H5).
    printf 'FAILED %s: it stopped with exit %s before finishing:\n%s\n' "$file" "$status" "$report"
    failed=1
  elif [ "$ran" -eq 0 ]; then
    echo "FAILED $file: it ran no test"
    failed=1
  fi
done
[ "$failed" -eq 0 ] && echo "factory tests ok: $passed passed in $files files"
exit "$failed"
