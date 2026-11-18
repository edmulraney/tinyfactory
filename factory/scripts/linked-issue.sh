#!/usr/bin/env bash
# Prints the number of the issue a pull request closes ("Closes #12" in its description), or nothing.
# Usage: linked-issue.sh <pr-number>
set -euo pipefail
# Read on a line of its own, so a failed read stops this script and its caller (decisions H7).
body=$(gh pr view "$1" --json body --jq '.body // ""') \
  || { echo "Could not read pull request #$1 from GitHub, so the issue it closes is not known." >&2; exit 1; }
printf '%s\n' "$body" \
  | grep -oiE '(closes|fixes|resolves) #[0-9]+' | grep -oE '[0-9]+' | head -1 || true
