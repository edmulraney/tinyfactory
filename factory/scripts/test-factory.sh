#!/usr/bin/env bash
# Runs the factory scripts' own tests, every factory/tests/*.test.sh, as the first part of `pnpm test` (decisions H3).
# Usage: test-factory.sh   (from the repo root)
set -euo pipefail

# Every file is run even after one fails, so one push shows everything that is broken (decisions H21).
failed=0
passed=0
files=0
# Listed on a line of its own, so a failed listing is not taken for a folder with no test in it (decisions H106).
if ! tests=$(git ls-files 'factory/tests/*.test.sh'); then
  echo "test-factory.sh must be run inside a git repository: it could not list the test files with git ls-files, so no test was run."
  exit 1
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
# shellcheck disable=SC2016
if [ -n "$numbered" ] && ! printf '%s' "$numbered" | xargs -P "$processors" -n 2 \
  bash -c 'status=0; bash "$2" > "$0/$1.report" 2>&1 || status=$?; echo "$status" > "$0/$1.status"' "$results"; then
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
