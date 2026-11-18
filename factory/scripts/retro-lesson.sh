#!/usr/bin/env bash
# Prints the lesson a retro's session returned, as one line of JSON, or stops with "the retro returned no lesson".
# Usage: OUTPUT='<json, or nothing>' retro-lesson.sh <execution-file>   (the file may be missing)
set -uo pipefail

file="${1:-}"
lesson="${OUTPUT:-}"
if ! jq -e '.cause' <<<"$lesson" >/dev/null 2>&1; then
  lesson=""
  # The action gives no output for a session it counts past `--max-turns`, though its lesson is saved (decisions A141).
  if [ -n "$file" ] && [ -f "$file" ]; then
    lesson=$(jq -c '(if type == "array" then .[-1] else . end)
      | select(type == "object" and .type == "result" and .subtype == "success" and (.is_error | not))
      | .structured_output | select(type == "object" and .cause)' "$file" 2>/dev/null) || lesson=""
    [ -z "$lesson" ] || echo "the action gave no lesson: it is read from the session's saved result" >&2
  fi
fi
[ -n "$lesson" ] || { echo "the retro returned no lesson" >&2; exit 1; }
jq -c . <<<"$lesson"
