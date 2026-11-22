#!/usr/bin/env bash
# Closes a ticket just filed when another run filed the same ticket first, so two runs leave one (decisions T620).
# Usage: close-duplicate.sh <ticket-number> [<other-title>...]   by a script that files a ticket only when none is open,
#                                       after it filed one. The same ticket is an open one with a smaller number, the
#                                       filed ticket's author, and its title or one of the other titles.
#        Prints the number of the ticket that stays when it closed the filed one, and nothing when the filed one stays.
#        Needs GH_TOKEN (issues: write). A call to GitHub that fails stops it with a message and exit 1, the ticket open.
set -euo pipefail

usage="Usage: close-duplicate.sh <ticket-number> [<other-title>...]"
filed="${1:?$usage}"; shift
[[ "$filed" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 1; }
die() { echo "$1" >&2; exit 1; }

# Listed: a search would miss a ticket seconds old. One page, newest first: the other run filed its ticket seconds ago.
open=$(gh api "repos/{owner}/{repo}/issues?state=open&sort=created&direction=desc&per_page=100") \
  && first=$(jq -r --argjson filed "$filed" '
    (map(select(.number == $filed))[0] // error("the list does not hold the ticket")) as $mine
    | map(select(.pull_request == null and .number < $filed and .user.login == $mine.user.login
        and (.title == $mine.title or (.title as $title | $ARGS.positional | index($title) != null))) | .number)
    | min // empty' --args "$@" <<<"$open") \
  || die "Whether another run filed the same ticket as #$filed could not be read from GitHub, so #$filed stays open."
[ -n "$first" ] || exit 0

# ready goes first: a build the other run started in this second is then refused by start-build.sh.
gh issue edit "$filed" --remove-label ready >/dev/null \
  && gh issue close "$filed" --reason duplicate --comment "Nothing to do: two runs filed this ticket at once, and #$first, filed first, is the one that is built." >/dev/null \
  || die "Ticket #$filed is the same as #$first, filed first by another run, and could not be closed: close #$filed."
echo "$first"
