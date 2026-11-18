#!/usr/bin/env bash
# Stores an agent's session transcript, or a retro's lesson, on the orphan `sessions` branch (decisions A16).
# Usage: save-session.sh <role> <key> <transcript-file>   e.g. save-session.sh esme issue-12 out.json
#        Needs GH_TOKEN (contents: write) and GITHUB_REPOSITORY.
set -uo pipefail

role="$1"; key="$2"; file="${3:-}"
[ -n "$file" ] && [ -f "$file" ] || { echo "no transcript to save for $role"; exit 0; }

# A file each, so two retros that save a lesson together never edit the same file.
name="$(date -u +%Y%m%dT%H%M%SZ)-$role-run${GITHUB_RUN_ID:-local}.json"

. "$(dirname "$0")/sessions-branch.sh"

# add_transcript <clone>: what push_to_sessions runs in each fresh clone of the branch.
add_transcript() {
  mkdir -p "$1/$key" && cp "$file" "$1/$key/$name"
}

if push_to_sessions "session: $role $key" add_transcript; then
  echo "saved $role session as $key/$name"
else
  echo "could not save the $role session (push kept failing)"
fi
# A lost transcript should not block a merge (decisions A17).
exit 0
