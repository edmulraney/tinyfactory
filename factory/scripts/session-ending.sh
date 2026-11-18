#!/usr/bin/env bash
# Prints, in one word, how a saved agent session ended: `usage_limit`, its `terminal_reason`, or `none` if unreadable.
# Usage: session-ending.sh <execution-file>   (the file the Claude action saves; may be empty)
set -uo pipefail

file="${1:-}"
reason=""
if [ -n "$file" ] && [ -f "$file" ]; then
  reason=$(jq -r '(if type == "array" then .[-1] else . end)
    | if type != "object" or .type != "result" then ""
      # Told by the name of the error or the words of its message, whichever the result holds (decisions A231a).
      elif .is_error == true and (.api_error == "usage_limit_reached"
        or (.result | type == "string" and test("^You.ve hit your .+ limit"))) then "usage_limit"
      else .terminal_reason // "" end' "$file" 2>/dev/null) || reason=""
fi
# The word tells a session cut short from outside, worth trying again, from one that ended of its own (decisions A24).
echo "${reason:-none}"
