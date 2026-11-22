#!/usr/bin/env bash
# Lists the tickets in flight, one per line starting with the ticket's number (decisions T64b).
# Usage: in-flight.sh        (needs GH_TOKEN and GITHUB_REPOSITORY, or a checkout gh can read)
#                            A ticket whose draft a build cut short left, and that waits with `ready`, is listed as
#                            `(waiting with ready; draft pull request #<n>, left unfinished)` and holds no place.
#        in-flight.sh full   reads such a list on standard input, and calls nothing. When a further build may start
#                            it prints nothing. Otherwise it prints three things: what is at its limit, on one line;
#                            what frees a place, on one line; then each line of the list that holds one.
set -euo pipefail

# Each is a judgement, not a measurement (decisions T64a, T361a).
building_limit=5
owner_limit=5

if [ "${1:-}" = full ]; then
  # A ticket cut short that waits with `ready` holds no place (decisions T505a).
  list=$(grep -v '^[0-9]* #[0-9]* (waiting with ready; ' || true)
  # A ticket waits for the owner when each of its pull requests ready for review does (decisions T361b).
  waits='^([0-9]+ #[0-9]+ \((pull request #[0-9]+, waiting for a person(; |\)$))+|- pull request #[0-9]+, which names no ticket, waiting for a person)$'
  waiting=$(grep -E "$waits" <<<"$list" || true)
  building=$(grep -vE "$waits" <<<"$list" | grep . || true)
  if [ "$(grep -c . <<<"$building" || true)" -ge "$building_limit" ]; then
    echo "$building_limit tickets are being built or checked"
    echo "one of them has merged, been closed or been left for a person"
    echo "$building"
  elif [ "$(grep -o 'waiting for a person' <<<"$waiting" | grep -c . || true)" -ge "$owner_limit" ]; then
    echo "$owner_limit pull requests wait for the owner"
    echo "the owner has merged or closed one of them"
    echo "$waiting"
  fi
  exit 0
fi

die() { echo "$1" >&2; exit 1; }

# Each is read on a line of its own (decisions H7). The issues are listed, not searched (decisions T331).
issues=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100" --paginate \
    --jq '.[] | select(.pull_request == null) | .number') \
  || die "The issues labelled in-progress could not be read from GitHub, so it is not known what is in flight."
pulls=$(gh pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft) \
  || die "The open pull requests could not be read from GitHub, so it is not known what is in flight."

# `app/claude` is how gh writes the app that opens the factory's pull requests.
# A draft whose ticket is not `in-progress` is what a build cut short left behind (decisions T64h).
list=$(jq -rn --arg listed "$issues" --argjson pulls "$pulls" '
  ($listed | split("\n") | map(tonumber)) as $issues |
  [$pulls[] | select(.author.login == "app/claude") | {
    pr: .number,
    draft: .isDraft,
    waits: ([.labels[].name] | index("needs-human") != null),
    ticket: ((.headRefName | capture("^[a-z]+/(?<n>[0-9]+)-").n | tonumber) // null)
  }] as $open
  | ($issues + [$open[].ticket | values] | unique) as $tickets
  | ($tickets[] | . as $ticket
      | [$open[] | select(.ticket == $ticket and (.draft | not))
          | "pull request #\(.pr)" + (if .waits then ", waiting for a person" else "" end)] as $its
      | ([$open[] | select(.ticket == $ticket and .draft) | "draft pull request #\(.pr)"] | join("; ")) as $drafts
      | "\($ticket) #\($ticket) ("
        + (if ($its | length) > 0 then $its | join("; ")
           elif $drafts == "" then "being built"
           elif ($issues | index($ticket)) != null then "being built, in \($drafts)"
           else "\($drafts), left unfinished" end)
        + ")"),
    ($open[] | select(.ticket == null) | "- pull request #\(.pr), which names no ticket" + (if .waits and (.draft | not) then ", waiting for a person" else "" end))') \
  || die "What GitHub answered about the issues and pull requests could not be read, so it is not known what is in flight."
[ -n "$list" ] || exit 0

# Such a ticket is marked when it waits with `ready`, which is read only when a draft was left unfinished (decisions T505a).
if grep -q 'left unfinished)$' <<<"$list"; then
  ready=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100" --paginate \
      --jq '.[] | select(.pull_request == null) | .number') \
    || die "The issues labelled ready could not be read from GitHub, so it is not known which unfinished draft holds a place."
  # The numbers reach awk through the environment (decisions H632a).
  list=$(READY="$ready" awk 'BEGIN { split(ENVIRON["READY"], numbers, "\n"); for (i in numbers) waits[numbers[i]] }
    /left unfinished\)$/ && ($1 in waits) { sub(/\(/, "(waiting with ready; ") }
    { print }' <<<"$list")
fi
printf '%s\n' "$list"
