#!/usr/bin/env bash
# Answers a permission request: allows a write to a skill file the ticket names or the pull request already changes.
# Usage: allow-skill-write.sh [ticket-text]   (a PermissionRequest hook: the request is JSON on standard input, the branch is checked out)
#        ticket-text  In a build, a file holding the ticket as thread.sh printed it before the session began.
set -euo pipefail

allow() { echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'; }

request=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$request") || {
  echo "Could not read the permission request, so the write stays refused." >&2
  exit 1
}
root=$(git rev-parse --show-toplevel)
path=${file#"$root"/}

# Printing no decision leaves the write refused, as it is with no hook.
# A build's new branch changes no file, so its ticket's text decides (decisions A550).
if [ $# -gt 0 ]; then
  [ -r "$1" ] || {
    echo "Could not read the ticket's text in $1, so the write to $file stays refused." >&2
    exit 1
  }
  # A path with `..` in it could name a file outside the skills.
  [[ "$path" != *..* ]] || exit 0
  # Each path as the ticket writes it, without the full stop that ends a sentence or the line number after a colon.
  named=$(grep -oE '\.claude/skills/[A-Za-z0-9_./-]+' "$1" | sed 's/\.*$//') || true
  grep -qxF -- "$path" <<<"$named" || exit 0
  allow
  exit 0
fi

# A fix round (decisions A475b).
changed=$(git -C "$root" diff --name-only origin/main...HEAD -- .claude/skills) || {
  echo "Could not read from git which skill files this pull request changes, so the write to $file stays refused." >&2
  exit 1
}
grep -qxF -- "$path" <<<"$changed" || exit 0
allow
