#!/usr/bin/env bash
# Flags the ticket a pull request closes for a person, as the merge gate does: `needs-human` on, `in-progress` off.
# Usage: flag-ticket.sh <pr-number>
#        Needs GH_TOKEN (pull-requests: read; issues: write).
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

pr="${1:?Usage: flag-ticket.sh <pr-number>}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# The board's "Needs you" view lists tickets, so one left unflagged would wait unseen (decisions T5).
issue=$("$script_dir/linked-issue.sh" "$pr") \
  || { echo "The ticket pull request #$pr closes could not be read, so it was not flagged for a person." >&2; exit 1; }
[ -n "$issue" ] || exit 0
gh issue edit "$issue" --add-label needs-human --remove-label in-progress >/dev/null \
  || { echo "Could not add needs-human to issue #$issue, which pull request #$pr closes." >&2; exit 1; }
