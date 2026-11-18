#!/usr/bin/env bash
# Checks that every acceptance criterion in a ticket has a test in the ticket's one acceptance file.
# Usage: check-acceptance.sh <issue-number> [branch]
set -euo pipefail

issue="$1"; branch="${2:-}"
dir="apps/web/e2e/acceptance"
# Read on a line of its own: piped into the filters below, a failed read would pass as "no acceptance criteria".
body=$(gh issue view "$issue" --json body --jq '.body // ""') \
  || { echo "Could not read issue #$issue from GitHub, so its acceptance criteria were not checked. Run this check again." >&2; exit 1; }
criteria=$(tr -d '\r' <<<"$body" \
  | awk '$0 == "## Acceptance criteria" {on = 1; next} /^## / {on = 0} on' \
  | grep -oE 'AC[0-9]+' | sort -u || true)

[ -n "$criteria" ] || { echo "Issue #$issue has no acceptance criteria to check."; exit 0; }

specs=$(find "$dir" -maxdepth 1 -name "$issue-*.spec.ts" | sort)
[ -n "$specs" ] || { echo "Missing $dir/$issue-<slug>.spec.ts: issue #$issue has acceptance criteria but no acceptance tests."; exit 1; }
[ "$(wc -l <<<"$specs")" -eq 1 ] || { printf 'Issue #%s must have exactly one acceptance file, found:\n%s\n' "$issue" "$specs"; exit 1; }
spec="$specs"

missing=0
if [ -n "$branch" ] && [ "$(basename "$spec")" != "${branch#*/}.spec.ts" ]; then
  echo "$spec should be named ${branch#*/}.spec.ts, after the branch $branch"
  missing=1
fi
if ! grep -qE "from [\"']\.\./test[\"']" "$spec"; then
  echo "$spec must import test and expect from \"../test\", not from @playwright/test"
  missing=1
fi
for ac in $criteria; do
  # Only a plain test(...) counts (decisions T12).
  if grep -qE "test\([[:space:]]*[\"'\`]$ac:" "$spec"; then
    continue
  fi
  other=$(grep -oE "test(\.[a-z]+)+\([[:space:]]*[\"'\`]$ac:" "$spec" | sed -E 's/\(.*/(…)/' | sort -u | paste -sd, - | sed 's/,/, /g' || true)
  if [ -n "$other" ]; then
    echo "$ac has no test that counts in $spec: \"$ac: …\" is declared with $other, which does not prove it. Declare it with a plain test(\"$ac: …\")."
  else
    echo "No test titled \"$ac: …\" in $spec"
  fi
  missing=1
done
# Nothing in the file is skipped, whatever its title (decisions T13).
if skipped=$(grep -nE '\.(skip|fixme)\(' "$spec"); then
  echo "$spec must not skip anything: a skipped test never runs, so it proves no criterion. Remove:"
  sed 's/^/  /' <<<"$skipped"
  missing=1
fi
[ "$missing" -eq 0 ] && echo "All acceptance criteria of #$issue have a test in $spec."
exit "$missing"
