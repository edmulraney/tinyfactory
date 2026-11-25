#!/usr/bin/env bash
# Checks that every acceptance criterion in a ticket has a test in the ticket's acceptance files.
# Usage: check-acceptance.sh <issue-number>
set -euo pipefail

issue="$1"
dir="apps/web/e2e/acceptance"
# Read on a line of its own: piped into the filters below, a failed read would pass as "no acceptance criteria".
body=$(gh issue view "$issue" --json body --jq '.body // ""') \
  || { echo "Could not read issue #$issue from GitHub, so its acceptance criteria were not checked. Run this check again." >&2; exit 1; }
criteria=$(tr -d '\r' <<<"$body" \
  | awk '$0 == "## Acceptance criteria" {on = 1; next} /^## / {on = 0} on' \
  | grep -oE 'AC[0-9]+' | sort -u || true)

[ -n "$criteria" ] || { echo "Issue #$issue has no acceptance criteria to check."; exit 0; }

# A criterion with no test is not proven (decisions T9).
specs=$(find "$dir" -maxdepth 1 -name "$issue-*.spec.ts" | sort)
[ -n "$specs" ] || { echo "Missing $dir/$issue-<slug>.spec.ts: issue #$issue has acceptance criteria but no acceptance tests."; exit 1; }
files=()
while IFS= read -r spec; do files+=("$spec"); done <<<"$specs"
named=$(paste -sd, - <<<"$specs" | sed 's/,/, /g')

missing=0
# The scan e2e/test.ts adds is what proves a page accessible (decisions D6).
for spec in "${files[@]}"; do
  if ! grep -qE "from [\"']\.\./test[\"']" "$spec"; then
    echo "$spec must import test and expect from \"../test\", not from @playwright/test"
    missing=1
  fi
done
for ac in $criteria; do
  # Only a plain test(...) counts (decisions T12).
  if grep -qE "test\([[:space:]]*[\"'\`]$ac:" "${files[@]}"; then
    continue
  fi
  other=$(grep -ohE "test(\.[a-z]+)+\([[:space:]]*[\"'\`]$ac:" "${files[@]}" | sed -E 's/\(.*/(…)/' | sort -u | paste -sd, - | sed 's/,/, /g' || true)
  if [ -n "$other" ]; then
    echo "$ac has no test that counts in $named: \"$ac: …\" is declared with $other, which does not prove it. Declare it with a plain test(\"$ac: …\")."
  else
    echo "No test titled \"$ac: …\" in $named"
  fi
  missing=1
done
# Nothing in a file is skipped, whatever its title (decisions T13).
for spec in "${files[@]}"; do
  if skipped=$(grep -nE '\.(skip|fixme)\(' "$spec"); then
    echo "$spec must not skip anything: a skipped test never runs, so it proves no criterion. Remove:"
    sed 's/^/  /' <<<"$skipped"
    missing=1
  fi
done
[ "$missing" -eq 0 ] && echo "All acceptance criteria of #$issue have a test in $named."
exit "$missing"
