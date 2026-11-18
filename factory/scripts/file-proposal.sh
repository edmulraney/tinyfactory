#!/usr/bin/env bash
# Files a retro's proposal as a ticket, or notes it on the open ticket the lesson says already holds it.
# Usage: file-proposal.sh <lesson-file> <open-tickets-file> <lessons-folder>
#        The lesson is as retro.yml saves it; the tickets are `[{number, title, labels}]`, and the file may be missing.
#        The folder holds the earlier lessons, each as retro.yml saved it.
#        Prints the sentence for the run's ticket, or nothing for a lesson below the bar.
#        A filed proposal whose lesson cites a cost in minutes and an earlier lesson, one the folder holds from
#        another pull request, ticket and run, is labelled `ready` and its build started; one that cites neither, or
#        whose build cannot be started, waits for a person (decisions A369a, A369d).
#        Needs GH_TOKEN (issues: write; to start a build, actions: write). A call to GitHub that fails stops it with a
#        message and exit 1, but for a build that cannot be started: the proposal is filed, and the message says it waits.
set -euo pipefail

usage="Usage: file-proposal.sh <lesson-file> <open-tickets-file> <lessons-folder>"
lesson="${1:?$usage}"
tickets="${2:?$usage}"
lessons="${3:?$usage}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }

# A lesson below the bar is saved and files nothing (decisions A223a).
body=$("$script_dir/retro-proposal.sh" "$lesson")
[ -n "$body" ] || exit 0

held=$(jq -r '.lesson.held_by // 0 | if type == "number" then floor else 0 end' "$lesson") \
  || die "The ticket the lesson in $lesson names could not be read, so nothing is filed."

# Only a ticket the list holds is believed: a wrong number, or a list never read, files as before (decisions A218b).
if [ "$held" -gt 0 ]; then
  if jq -e --argjson n "$held" 'any(.[]; .number == $n)' "$tickets" >/dev/null 2>&1; then
    note=$(jq -r '
      (if .facts.run then "the `\(.facts.workflow)` run \(.facts.url)" else "pull request #\(.pr)" end) as $seen
      | "A retro of \($seen) proposes the change this ticket holds, and filed no ticket of its own.\n\n\(.lesson.summary)\n\n"
      + "What the fault cost: \(.lesson.cost.amount)\n\n\(.lesson.change.proposal)\n\n\(.lesson.evidence | map("- " + .) | join("\n"))"' "$lesson") \
      || die "The note for issue #$held could not be written, so nothing is said there and nothing is filed."
    url=$(gh issue comment "$held" --body "$(sed 's/@claude/claude/g' <<<"$note")") \
      || die "Could not comment on issue #$held, which holds the lesson's proposal, so nothing is said there and nothing is filed."
    echo "The change it proposes is already in an open ticket, where the retro noted this run: $url"
    exit 0
  fi
  echo "the lesson names issue #$held, which the open tickets in $tickets do not show: the proposal is filed" >&2
fi

# A fault seen before that cost time (decisions A369a). A link holds digits that count no minutes.
accepted=$(jq -r '.lesson.cost.amount // "" | tostring | gsub("https?://[^ ]+"; "") | test("[0-9] ?(minutes?|mins?)\\b")' "$lesson") \
  && cited=$(jq -r '.lesson.repeats // [] | .[] | tostring | split("\n")[0] // ""' "$lesson") \
  || die "Whether the lesson in $lesson repeats an earlier one could not be read, so nothing is filed."
# Only a cited lesson from another pull request, ticket and run counts (decisions A369d).
seen_before=false
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if jq -e --slurpfile this "$lesson" '
      def same(a; b): a != null and a == b;
      $this[0] as $this
      | (same(.pr; $this.pr) or same(.issue; $this.issue) or same(.facts.run; $this.facts.run)) | not' \
      "$lessons/$(basename -- "$name")" >/dev/null 2>&1; then
    seen_before=true
  fi
done <<<"$cited"
[ "$seen_before" = true ] || accepted=false

# Only an empty title is replaced, so no finding is lost; GitHub refuses one over 256 (decisions T14, A85a).
title=$(jq -r '.lesson.title // "" | split("\n")[0] // "" | gsub("^\\s+|\\s+$"; "")' "$lesson" | cut -c1-256)
[ -n "$title" ] || title=$(jq -r '.lesson.summary | split("\n")[0]' "$lesson" | cut -c1-60)
# `retro` stays for good (decisions T218). Until setup has made the labels GitHub refuses them (decisions A85b).
# A ticket flagged for a person says first what they must do (decisions A371a).
url=$(gh issue create --title "$title" --label factory --label proposal --label retro --body "$body") \
  || url=$(gh issue create --title "$title" --label factory --label needs-human --body "Add the \`ready\` label to have this proposal built, or close it: nothing is built until then.

$body") \
  || die "Could not file the proposal of the lesson in $lesson. The lesson is saved."

number=${url##*/}
if [ "$accepted" = true ] && [[ "$number" =~ ^[0-9]+$ ]]; then
  # ready, then the build by its number (decisions A369b).
  if ! gh issue edit "$number" --add-label ready >/dev/null; then
    echo "Issue #$number, a proposal for a repeated fault, could not be labelled ready: it waits for a person to add the label." >&2
  elif gh workflow run implement.yml -f issue="$number" >/dev/null; then
    gh issue comment "$number" --body "Started without asking: this proposal cites an earlier lesson and a cost in minutes, and the owner's rule accepts and starts a proposal for a fault that has happened before and cost time (\`factory/decisions.md\` A369a). Its build starts once a place is free." >/dev/null \
      || echo "The build of issue #$number was started, and the issue could not be told which rule started it." >&2
    echo "It proposes a change to the factory, and started its build, as the owner's rule for a repeated fault allows: $url"
    exit 0
  elif gh issue edit "$number" --remove-label ready >/dev/null; then
    echo "The build of issue #$number, a proposal for a repeated fault, could not be started: it waits for a person to add the ready label." >&2
  else
    echo "The build of issue #$number, a proposal for a repeated fault, could not be started, and the ready label could not be taken off it: its build starts when a place next frees." >&2
  fi
fi
echo "It proposes a change to the factory: $url"
