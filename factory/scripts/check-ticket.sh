#!/usr/bin/env bash
# Checks that an issue follows its ticket template: prints one line per problem and exits 1 if any.
# Usage: check-ticket.sh <issue-number>   (needs GH_TOKEN or a gh login, inside the repo)
#        check-ticket.sh --draft <type> <title> <body-file>   checks a ticket before it is filed, and calls nothing
set -euo pipefail

if [ "$1" = --draft ]; then
  usage="Usage: check-ticket.sh --draft <type> <title> <body-file>"
  [ -f "${4:?$usage}" ] || { echo "$4 is not a file, so the draft was not checked." >&2; exit 2; }
  # A draft has no opening time, so the limit on "Change" counts it.
  json=$(jq -n --arg type "$2" --arg title "$3" --rawfile body "$4" '{title: $title, body: $body, labels: [{name: $type}]}')
else
  json=$(gh issue view "$1" --json title,body,labels,createdAt)
fi
title=$(jq -r '.title // ""' <<<"$json")
body=$(jq -r '.body // ""' <<<"$json" | tr -d '\r')
labels=" $(jq -r '[.labels[].name] | join(" ")' <<<"$json") "
created=$(jq -r '.createdAt // ""' <<<"$json")
# A ticket opened before the limit began is not counted; UTC times compare as text (decisions T173a, T173b).
change_limit=120
limit_began="2026-11-18T00:00:00Z"

# Whether the first word is an imperative verb, and whether it says what changes, is for a reader (decisions T14, T15).
problems=0
title_problem() { echo "- The title \"$title\" $1"; problems=1; }
if [ "${#title}" -gt 60 ]; then
  title_problem "is ${#title} characters long, and the limit is 60. Name the change in one clause; the reason belongs in the body."
fi
case "$title" in *:*) title_problem "has a colon. A title is one clause: an imperative verb, then what changes." ;; esac
case "$title" in *,*) title_problem "has a comma. A title is one clause: an imperative verb, then what changes." ;; esac
case "$title" in *.) title_problem "ends in a full stop. Take it off." ;; esac
if ! [[ "$title" =~ ^[[:upper:]] ]]; then
  title_problem "does not start with a capital letter. Start with an imperative verb, in sentence case (\"Add a ticket queue\")."
fi

# A proof ticket is never built, so the gate refuses it without asking for a type (decisions T85g).
case "$labels" in
  *" proof "*) echo "- A ticket labelled \`proof\` has nothing to build. Close it once the run it names has been seen."; exit 1 ;;
esac

# Exactly one type: it picks the template here and the engineer in the build (decisions T85a, T33b).
types=(initiative bug tweak chore research factory)
found=()
for type in "${types[@]}"; do
  case "$labels" in *" $type "*) found+=("$type") ;; esac
done
all=$(printf '%s, ' "${types[@]}"); all=${all%, }
if [ "${#found[@]}" -eq 0 ]; then
  echo "- No ticket type. Add one of the labels: $all."
  exit 1
fi
if [ "${#found[@]}" -gt 1 ]; then
  carried=$(printf '%s, ' "${found[@]}"); carried=${carried%, }
  echo "- More than one ticket type: $carried. Keep one of the labels: $all."
  exit 1
fi
case "${found[0]}" in
  initiative) required=("Problem" "Hypothesis" "Success metric" "Scope" "Acceptance criteria" "Docs to update") ;;
  bug)        required=("What happens" "What should happen" "Steps to reproduce" "Acceptance criteria" "Docs to update") ;;
  tweak)      required=("Change" "Acceptance criteria" "Docs to update") ;;
  # No behaviour changes, so there is nothing new to accept: the existing tests are the proof.
  chore)      required=("Change" "Docs to update") ;;
  # Its output is files in product/, which check-research.sh checks as "Checks" says (decisions T33c).
  research)   required=("Question" "What to read" "Output" "Checks") ;;
  # A change to the factory itself cannot be tested through the app; it says how it will be proven.
  factory)    required=("Change" "How we will know it works") ;;
esac

# Text under a "## Heading", up to the next heading, without template comments or blank lines.
section() {
  awk -v h="## $1" '$0 == h {on = 1; next} /^## / {on = 0} on' <<<"$body" \
    | sed 's/<!--.*-->//g' | grep -v '^[[:space:]]*$' || true
}

for heading in "${required[@]}"; do
  if [ -z "$(section "$heading")" ]; then
    echo "- Section \"## $heading\" is missing or empty."
    problems=1
  fi
done
# A ticket with no opening time is counted: a missing answer must not read as an old ticket.
words=$(section "Change" | wc -w | tr -d ' ')
if [[ " ${required[*]} " == *" Change "* && "$words" -gt "$change_limit" ]] \
  && [[ -z "$created" || ! "$created" < "$limit_began" ]]; then
  echo "- Section \"## Change\" is $words words long, and the limit is $change_limit. State the change and its reason; evidence is a link to the run or pull request, not the story of it."
  problems=1
fi
if [[ " ${required[*]} " == *" Acceptance criteria "* ]] && ! section "Acceptance criteria" | grep -qE 'AC[0-9]+'; then
  echo "- No numbered acceptance criteria. Write each as \"- **AC1:** Given …, when …, then …\"."
  problems=1
fi
# A ticket check-research.sh would refuse after the build is refused here before it (decisions T33g).
if [[ " ${required[*]} " == *" Checks "* ]] && [ -n "$(section "Checks")" ]; then
  checks=$(section "Checks" | grep -E '^- ' || true)
  if [ -z "$checks" ]; then
    echo "- No check a script can run. Write each as \"- 5 files \`product/research/*-profile.md\`, each with \`## Sources\`\": a path under product/ in backticks, then each line the files must hold."
    problems=1
  elif ! refused=$("$(dirname "$0")/check-research.sh" --runnable <<<"$checks"); then
    [ -n "$refused" ] || refused="The lines under \"## Checks\" could not be judged: check-research.sh failed."
    sed 's/^/- /' <<<"$refused"
    problems=1
  fi
fi
exit "$problems"
