#!/usr/bin/env bash
# Stops a pull request that has used its three fix rounds (decisions A5): flags it and its ticket, and starts a retro.
# Usage: stop-fix-rounds.sh <pr-number>
#        Needs GH_TOKEN (pull-requests, issues and actions: write) and flag-ticket.sh.
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

pr="${1:?Usage: stop-fix-rounds.sh <pr-number>}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

# Both places that find the rounds used stop it here, so that neither stops it in silence (decisions A89h).
gh pr edit "$pr" --add-label needs-human >/dev/null \
  || die "Pull request #$pr has used its three fix rounds, and needs-human could not be added to it."
# The ticket waits with its pull request (decisions A48e).
"$script_dir/flag-ticket.sh" "$pr" || die "Pull request #$pr has used its three fix rounds, and the ticket it closes could not be flagged."
# The first line says what a person must do (decisions A371a).
gh pr comment "$pr" --body "Submit a \"Request changes\" review saying what to change, or close this pull request: a review starts a fix round that is not one of the three.

Three fix rounds have not got this pull request to green, and no fourth starts by itself." >/dev/null \
  || die "Pull request #$pr has used its three fix rounds, and could not be told so."
gh workflow run retro.yml -f pr="$pr" >/dev/null \
  || die "Pull request #$pr has used its three fix rounds and was told so, but the retro could not be started."
