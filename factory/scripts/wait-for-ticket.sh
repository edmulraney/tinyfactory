#!/usr/bin/env bash
# Leaves a ticket, whose build found that it needs another open ticket merged first, to wait for it (decisions T622a).
# Usage: wait-for-ticket.sh <ticket> <needed ticket> <reason>
#        The engineer runs it, then stops. The ticket's body gains the line `After #<needed ticket>`, the ticket takes
#        `ready` for `in-progress`, and a comment gives the reason: start-waiting.sh starts its build once the needed
#        ticket, an issue or a pull request, has closed.
#        Exit 2, with nothing changed: the needed ticket is closed, is the ticket itself or waits for it, so a person is asked.
#        Needs GH_TOKEN (issues: write) and GITHUB_REPOSITORY, or a checkout gh can read.
#        A call to GitHub that fails stops it with a message and exit 1, and the body is as it was.
set -euo pipefail

usage="Usage: wait-for-ticket.sh <ticket> <needed ticket> <reason>"
ticket="${1:?$usage}"; needed="${2:?$usage}"; reason="${3:?$usage}"

die() { echo "$1" >&2; exit 1; }
person() { echo "$1 Nothing was changed: comment on issue #$ticket and add needs-human, as for any other stop." >&2; exit 2; }

# The numbers go into calls and a pattern, so anything that is not one is refused.
[[ "$ticket" =~ ^[0-9]+$ ]] || die "\"$ticket\" is not an issue number."
[[ "$needed" =~ ^[0-9]+$ ]] || die "\"$needed\" is not an issue number."

[ "$needed" != "$ticket" ] || person "Issue #$ticket cannot wait for itself."
its=$(gh api "repos/{owner}/{repo}/issues/$needed" --jq '.state, (.body // "")') \
  || die "Issue #$ticket was not left to wait: whether #$needed is open could not be read from GitHub. Nothing was changed."
[ "$(sed -n 1p <<<"$its")" = open ] || person "#$needed is closed, so issue #$ticket has nothing to wait for."
# Two tickets that each wait for the other are never started.
! tr -d '\r' <<<"$its" | grep -qE "^After #$ticket\s*$" || person "#$needed waits for issue #$ticket, as its body says, so neither would ever start."

body=$(gh issue view "$ticket" --json body --jq .body) \
  || die "Issue #$ticket was not left to wait for #$needed: its body could not be read from GitHub. Nothing was changed."
named=""
! tr -d '\r' <<<"$body" | grep -qE "^After #$needed\s*$" || named=yes
if [ -z "$named" ]; then
  gh issue edit "$ticket" --body "$body

After #$needed" >/dev/null \
    || die "Issue #$ticket was not left to wait for #$needed: the line \`After #$needed\` could not be added to its body. Nothing was changed."
fi

# ready before the comment: a ticket that waits untold is told by start-waiting.sh, and one told and not waiting never starts.
if ! gh issue edit "$ticket" --add-label ready --remove-label in-progress >/dev/null; then
  [ -n "$named" ] || gh issue edit "$ticket" --body "$body" >/dev/null \
    || die "Issue #$ticket was not left to wait for #$needed: its labels could not be changed, and the line \`After #$needed\` could not be taken out of its body again."
  die "Issue #$ticket was not left to wait for #$needed: its labels could not be changed. Its body is as it was."
fi

# The first line says what a person must do (decisions A371a).
gh issue comment "$ticket" --body "Nothing to do: the factory builds this ticket once #$needed has closed.

The build stopped, because this ticket needs #$needed merged first: $reason

The ticket's body now says \`After #$needed\`, and the ticket waits with the \`ready\` label." >/dev/null \
  || die "Issue #$ticket waits with ready for #$needed to close, but the reason could not be commented on it: comment it by hand."
echo "issue #$ticket waits with ready for #$needed to close"
