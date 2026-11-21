#!/usr/bin/env bash
# Files one slice of an idea as an unstarted ticket and a sub-issue of the idea, and prints the ticket's number.
# Usage: file-slice.sh <idea-number> <type> <title> <body-file>
#        Needs GH_TOKEN (issues: write). A draft its template refuses is printed with what is wrong, and not filed.
#        A ticket GitHub does not add to the idea as a sub-issue is still filed, and the idea says what to do.
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
# The idea then lists its slices, and close-idea.sh closes it with the last of them (decisions T569a).
if ! { id=$(gh api "repos/{owner}/{repo}/issues/$number" --jq .id) \
    && gh api --method POST "repos/{owner}/{repo}/issues/$idea/sub_issues" -F sub_issue_id="$id" >/dev/null; }; then
  echo "Filed #$number, but GitHub did not add it to idea #$idea as a sub-issue." >&2
  gh issue comment "$idea" --body "Add #$number to this idea by hand, under \"Sub-issues\", with \"Add existing issue\": GitHub did not add it when it was filed. Until then this idea does not list #$number, and the factory closes the idea without waiting for #$number to close." >/dev/null \
    || die "Filed #$number, but could not say on idea #$idea that it is not one of its sub-issues. Do not file \"$title\" again."
fi
echo "$number"
