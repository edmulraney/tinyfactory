#!/usr/bin/env bash
# Files one slice of an idea as an unstarted ticket, says so on the idea, and prints the ticket's number.
# Usage: file-slice.sh <idea-number> <type> <title> <body-file>
#        Needs GH_TOKEN (issues: write). A draft its template refuses is printed with what is wrong, and not filed.
set -euo pipefail

usage="Usage: file-slice.sh <idea-number> <type> <title> <body-file>"
idea="${1:?$usage}"; type="${2:?$usage}"; title="${3:?$usage}"; body="${4:?$usage}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

# gh reads commas in a label as several, so the type is one word and the only label: never `ready` (decisions A353b).
[[ "$idea" =~ ^[0-9]+$ ]] || die "\"$idea\" is not an idea's number."
[[ "$type" =~ ^[a-z]+$ ]] || die "\"$type\" is not a ticket type."
[ -f "$body" ] || die "$body is not a file, so no ticket was filed."

# Checked before it is filed: GitHub deletes no issue for an agent, so a refused one would stay (decisions T353b).
status=0
problems=$("$script_dir/check-ticket.sh" --draft "$type" "$title" "$body") || status=$?
[ "$status" -le 1 ] || die "check-ticket.sh could not check the draft, so no ticket was filed."
if [ "$status" -eq 1 ]; then
  printf 'Not filed, because the ticket does not follow its template:\n%s\n' "$problems"
  exit 1
fi

url=$(gh issue create --title "$title" --label "$type" --body-file "$body") \
  || die "Could not file \"$title\" on GitHub."
number="${url##*/}"
# The idea is what Peta's next run reads, so a run cut short files no slice twice (decisions A353g).
gh issue comment "$idea" --body "Filed #$number: $title" >/dev/null \
  || die "Filed #$number, but could not say so on idea #$idea. Do not file \"$title\" again."
echo "$number"
