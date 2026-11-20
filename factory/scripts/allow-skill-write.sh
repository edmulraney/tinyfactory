#!/usr/bin/env bash
# Answers a permission request: allows a write to a skill file the pull request already changes (decisions A475b).
# Usage: allow-skill-write.sh   (a PermissionRequest hook: the request is JSON on standard input, the branch is checked out)
set -euo pipefail

request=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$request") || {
  echo "Could not read the permission request, so the write stays refused." >&2
  exit 1
}
root=$(git rev-parse --show-toplevel)
path=${file#"$root"/}
changed=$(git -C "$root" diff --name-only origin/main...HEAD -- .claude/skills) || {
  echo "Could not read from git which skill files this pull request changes, so the write to $file stays refused." >&2
  exit 1
}
# Printing no decision leaves the write refused, as it is with no hook.
grep -qxF -- "$path" <<<"$changed" || exit 0
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
