#!/usr/bin/env bash
# Prints the verdict a review ended with: its last session's saved one, or else what the action gave (decisions A199).
# Usage: OUTPUT='<json, or nothing>' review-verdict.sh <execution-file>   (the file may be missing)
set -uo pipefail

file="${1:-}"
saved=""
if [ -n "$file" ] && [ -f "$file" ]; then
  saved=$(jq -c '(if type == "array" then .[-1] else . end)
    | select(type == "object" and .type == "result" and .subtype == "success" and (.is_error | not))
    | .structured_output | select(type == "object" and (.findings | type) == "array")' "$file" 2>/dev/null) || saved=""
fi
# Never fails: that a result is no verdict is for post-verdict.sh to say.
if [ -z "$saved" ]; then
  printf '%s\n' "${OUTPUT:-}"
  exit 0
fi
[ -n "${OUTPUT:-}" ] || echo "the action gave no verdict: it is read from the session's saved result" >&2
printf '%s\n' "$saved"
