#!/usr/bin/env bash
# Closes the idea a closed ticket is a slice of, once no other slice of that idea is open (decisions T569b).
# Usage: close-idea.sh <closed-issue-number>
#        Does nothing for a ticket that is a sub-issue of no open issue labelled `idea`.
#        Needs GH_TOKEN (issues: write). A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

slice="${1:?Usage: close-idea.sh <closed-issue-number>}"
die() { echo "$1" >&2; exit 1; }
[[ "$slice" =~ ^[0-9]+$ ]] || die "\"$slice\" is not an issue number."

parent=$(gh api "repos/{owner}/{repo}/issues/$slice" --jq '.parent_issue_url // ""') \
  || die "Could not read issue #$slice from GitHub, so whether it is the last slice of an idea is not known."
[ -n "$parent" ] || { echo "issue #$slice is a slice of no idea: nothing was closed"; exit 0; }
idea="${parent##*/}"

is_open_idea=$(gh api "repos/{owner}/{repo}/issues/$idea" --jq '.state == "open" and any(.labels[]; .name == "idea")') \
  || die "Could not read issue #$idea, the parent of #$slice, from GitHub, so it was not closed."
[ "$is_open_idea" = true ] || { echo "issue #$idea, the parent of #$slice, is not an open idea: nothing was closed"; exit 0; }

# GitHub can still list a ticket as open seconds after it closed (decisions T359a), so the closed one is not counted.
open=$(gh api "repos/{owner}/{repo}/issues/$idea/sub_issues?per_page=100" --paginate \
    --jq ".[] | select(.state == \"open\" and .number != $slice) | \"#\(.number)\"") \
  || die "Could not read the slices of idea #$idea from GitHub, so it was not closed."
if [ -n "$open" ]; then
  echo "idea #$idea stays open: $(paste -sd' ' <<<"$open") is still open"
  exit 0
fi

gh issue close "$idea" >/dev/null || die "Every slice of idea #$idea has closed, but GitHub did not close the idea."
echo "closed idea #$idea: #$slice was its last open slice"
