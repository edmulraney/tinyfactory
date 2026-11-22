#!/usr/bin/env bash
# Files one slice of an idea as an unstarted ticket and a sub-issue of the idea, and prints the ticket's number.
# Usage: file-slice.sh <idea-number> <type> <title> <body-file>
#        Needs GH_TOKEN (issues: write). A draft its template refuses is printed with what is wrong, and not filed.
#        Nor is one whose "States" hold a row that is not in the journey's map: the part "## Journey" of the last
#        comment of Peta's on the idea that has one, and product/journeys/<journey>.md (run from the repo root).
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

# A slice's rows are the journey's, as its map and its file word them (decisions T606a).
section() {
  awk -v h="## $1" '$0 == h {on = 1; next} /^## / {on = 0} on' | sed 's/<!--.*-->//g' | grep -v '^[[:space:]]*$' || true
}
rows=$(tr -d '\r' < "$body" | section "States" | grep '^- ' || true)
if [ -n "$rows" ]; then
  # Peta's comments are the Claude app's (decisions A563e), so a map the owner quotes is not read as hers.
  proposals=$(gh api "repos/{owner}/{repo}/issues/$idea/comments?per_page=100" --paginate \
    --jq '.[] | select(.user.login == "claude[bot]" and .user.type == "Bot") | (.body // "") | select(test("(^|\n)## Journey\r?\n")) | @json') \
    || die "Could not read the comments on idea #$idea from GitHub, so the journey's map is not known and no ticket was filed."
  map=$(tail -n 1 <<<"$proposals" | jq -r . | tr -d '\r' | section "Journey")
  journey=$(sed -n 1p <<<"$map")
  if ! [[ "$journey" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Not filed, because no proposal on idea #$idea holds the journey's map, and this slice changes a screen. Propose again, with the map under \"## Journey\"."
    exit 1
  fi
  file="product/journeys/$journey.md"
  known=$({ cat <<<"$map"; [ ! -f "$file" ] || cat "$file"; } | sed -n '/^- /{s/^- *//;s/ *:.*//;p;}')
  problems=""
  while read -r row; do
    state=$(sed 's/^- *//; s/ *:.*//' <<<"$row")
    grep -qxF -- "$state" <<<"$known" \
      || problems+="- The row \"$row\" under \"## States\" is not in the map of your proposal, nor in $file. Name each screen and state as the map does."$'\n'
  done <<<"$rows"
  docs=$(tr -d '\r' < "$body" | section "Docs to update")
  grep -qF -- "$file" <<<"$docs" \
    || problems+="- \"## Docs to update\" does not list \`$file\`, where the slice keeps its rows of the map."$'\n'
  if [ -n "$problems" ]; then
    printf 'Not filed, because the ticket does not follow the map of the %s journey:\n%s' "$journey" "$problems"
    exit 1
  fi
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
