#!/usr/bin/env bash
# Says whether the factory may act for an account: one that may write to the repository, or one of its own two bots.
# Usage: trusted.sh <login>
#        Exit 0: the account is trusted. Exit 1: it is not, as an empty login and one GitHub does not know are not.
#        Exit 2, with a message: GitHub would not say. A caller takes that for "no" and stops.
#        Needs GH_TOKEN, with any permissions, and GITHUB_REPOSITORY or a checkout gh can read.
set -euo pipefail

login="${1:-}"

# The factory's own two, by the full login GitHub's API gives, which no person's username can be (decisions U563a).
case "$login" in
  'github-actions[bot]' | 'claude[bot]') exit 0 ;;
esac

# The login goes into an address, so one that could not be a person's username is asked about nowhere.
if [[ ! "$login" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "\"$login\" is not trusted: it is neither one of the factory's two bots nor a person's username." >&2
  exit 1
fi

if ! answer=$(gh api "repos/{owner}/{repo}/collaborators/$login/permission" 2>&1); then
  if [[ "$answer" == *"HTTP 404"* ]]; then
    echo "$login is not trusted: GitHub knows no such account on this repository." >&2
    exit 1
  fi
  echo "GitHub would not say whether $login may write to this repository, so nothing is done for that account: $answer" >&2
  exit 2
fi

# `permission` is the base role, so a custom role counts as the access it grants (decisions U563a).
if ! permission=$(jq -r '.permission // ""' <<<"$answer" 2>/dev/null) || [ -z "$permission" ]; then
  echo "GitHub's answer names no permission for $login on this repository, so nothing is done for that account: $answer" >&2
  exit 2
fi
case "$permission" in
  admin | maintain | write) exit 0 ;;
esac
echo "$login is not trusted: its permission on this repository is \"$permission\", and the factory acts only for one that may write." >&2
exit 1
