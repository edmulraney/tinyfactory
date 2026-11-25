#!/usr/bin/env bash
# Answers a permission request: allows a write to a skill file the ticket, the pull request or the owner's review names.
# Usage: allow-skill-write.sh [ticket-text | --owner-review <file>]
#        A PermissionRequest hook: the request is JSON on standard input, the branch is checked out.
#        ticket-text     In a build, a file holding the ticket as thread.sh printed it before the session began.
#        --owner-review  In a fix round, the file begin-fix-round.sh writes what the owner asked for to, in the owner's round alone.
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
if [ $# -gt 0 ] && [ "$1" != --owner-review ]; then
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
if grep -qxF -- "$path" <<<"$changed"; then
  allow
  exit 0
fi

# The owner's round also writes a path the owner's review names, or one in a folder it names (decisions A695a).
review="${2:-}"
[ -n "$review" ] && [ -e "$review" ] || exit 0
# A path with `..` in it could name a file outside the skills.
[[ "$path" != *..* ]] || exit 0
# A name counts only when a space, a quote, a closing bracket, punctuation or the line's end follows it: one cut short at
# another character, such as the `[` of `app/[id]/page.tsx`, would name the folder above the file the owner named.
# The match holds that following character, which a path never holds, because BSD grep has no lookahead (decisions H632a).
# grep exits 1 when the review names no skill path, and higher when it could not read the file.
found=$(grep -oE '\.claude/skills/[A-Za-z0-9_./-]+($|[][:space:]`'\''",:;?!)])' "$review") || [ $? -eq 1 ] || {
  echo "Could not read what the owner asked for in $review, so the write to $file stays refused." >&2
  exit 1
}
# Each path as the review writes it, without the character that follows it, the slash that ends a folder or the full
# stop that ends a sentence.
while IFS= read -r name; do
  name=$(sed -E 's#[^A-Za-z0-9_./-]$##; s#[./]+$##' <<<"$name")
  # What is left of a path that named the skills folder itself would allow every skill.
  [[ "$name" == .claude/skills/?* ]] || continue
  if [ "$path" = "$name" ] || [[ "$path" == "$name"/* ]]; then
    allow
    exit 0
  fi
done <<<"$found"
