#!/usr/bin/env bash
# Flags for a person each ticket in flight that no run is working on and nothing has touched for an hour.
# Usage: flag-idle.sh   (by flag-idle.yml, on its schedule)
#        First it starts again what the Claude usage limit held, once the limit has reset, and then flags nothing.
#        Needs GH_TOKEN (actions and contents: write; pull-requests: read; issues: write) and GITHUB_REPOSITORY, or a checkout gh can read.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1, so nothing was flagged." >&2; exit 1; }

# While the usage limit holds every agent nothing works on a ticket, and what this look starts again has no run yet (decisions A395e).
limit=$("$script_dir/usage-limit.sh" resume) || die "What the Claude usage limit held could not all be started again"
if [ -n "$limit" ]; then
  echo "$limit"
  echo "Nothing was flagged: what the usage limit held is not idle."
  exit 0
fi

# Longer than any gap between two runs of a ticket that is being worked on (decisions T271b).
idle_minutes=60

# Each answer is read on a line of its own (decisions H7).
in_flight=$("$script_dir/in-flight.sh") || die "The tickets in flight could not be listed"
if [ -z "$in_flight" ]; then
  echo "Nothing is in flight: nothing to flag."
  exit 0
fi

# GitHub lists one state a call, and these are all the states of a run that has not ended.
running=""
for state in queued in_progress waiting requested pending; do
  runs=$(gh api --method GET "repos/{owner}/{repo}/actions/runs" -f "status=$state" -f per_page=100 \
    --jq '.workflow_runs[] | "\(.name) \(.head_branch)"') \
    || die "The runs that are $state could not be read from GitHub"
  running+="$runs"$'\n'
done
# Only a `ci` run names its pull request's branch: a run of the others stands for every ticket (decisions T271c).
any=$(awk '$1 == "implement" || $1 == "fix" || $1 == "approve-merge" || $1 == "merge-group" { print $1; exit }' <<<"$running")

# All is read before anything is flagged, so a failed read leaves no ticket flagged and another not.
to_flag=""
while IFS= read -r line; do
  ticket=${line%% *}
  what=${line#* }
  if [ "$ticket" = - ]; then
    echo "left: $what"
    continue
  fi
  # A ticket that waits with ready for a place is started by start-waiting.sh (decisions T505a).
  if [[ "$what" == "#$ticket (waiting with ready; "* ]]; then
    echo "left: #$ticket waits with ready for a place"
    continue
  fi
  about=${what#*(}
  about=${about%)}
  if [[ "$what" == *"waiting for a person"* ]]; then
    echo "left: #$ticket waits for a person"
    continue
  fi
  issue=$(gh issue view "$ticket" --json labels,updatedAt \
    --jq '"\([.labels[].name] | index("needs-human") != null) \(.updatedAt)"') \
    || die "Issue #$ticket could not be read from GitHub"
  if [ "${issue%% *}" = true ]; then
    echo "left: #$ticket waits for a person"
    continue
  fi
  touched=${issue#* }
  run=$any
  ready=""
  conflict=""
  for pr in $(grep -oE 'pull request #[0-9]+' <<<"$about" | grep -oE '[0-9]+' || true); do
    pull=$(gh pr view "$pr" --json updatedAt,headRefName,mergeable,isDraft \
      --jq '"\(.updatedAt) \(.mergeable) \(.isDraft) \(.headRefName)"') \
      || die "Pull request #$pr of ticket #$ticket could not be read from GitHub"
    read -r at mergeable draft branch <<<"$pull"
    [[ "$at" < "$touched" ]] || touched=$at
    [ "$draft" != false ] || ready=$pr
    [ "$mergeable" != CONFLICTING ] || [ "$draft" != false ] || conflict=$pr
    [ -n "$run" ] || run=$(awk -v branch="$branch" '$1 == "ci" && $2 == branch { print $1; exit }' <<<"$running")
  done
  if [ -n "$run" ]; then
    echo "left: #$ticket has a run going or queued ($run)"
    continue
  fi
  minutes=$(jq -rn --arg at "$touched" '(now - ($at | fromdateiso8601)) / 60 | floor') \
    || die "When ticket #$ticket was last touched ($touched) could not be worked out"
  if [ "$minutes" -lt "$idle_minutes" ]; then
    echo "left: #$ticket was touched $minutes minutes ago"
    continue
  fi
  if [ -n "$conflict" ]; then
    todo="Run \`gh workflow run fix.yml -f pr=$conflict\`: a fix round starts and fits the branch to \`main\`."
    next="Pull request #$conflict conflicts with \`main\`, and no fix round is going for it."
  elif [ -n "$ready" ]; then
    todo="Run \`gh pr checks $ready\` and run again the job it shows stopped: the pull request merges once its checks and reviews pass."
    next="Pull request #$ready is ready for review, and no check, review, fix round or merge is going for it."
  else
    todo="Add the \`ready\` label again: a build starts when a place is free."
    next="No build of it is going."
  fi
  to_flag+="$ticket $minutes $touched $about"$'\t'"$next"$'\t'"$todo"$'\n'
done <<<"$in_flight"

if [ -z "$to_flag" ]; then
  echo "Every ticket in flight has a run going or queued, waits for a person, or was touched in the last $idle_minutes minutes: nothing to flag."
  exit 0
fi

run_link=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_link=" Found by $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
status=0
flagged=""
while IFS=$'\t' read -r found next todo; do
  [ -n "$found" ] || continue
  read -r ticket minutes touched about <<<"$found"
  # The label first: it is what keeps the next look from flagging the ticket again (decisions T271d).
  if ! gh issue edit "$ticket" --add-label needs-human --remove-label in-progress >/dev/null; then
    echo "Nothing is working on ticket #$ticket, and needs-human could not be added to it: it was not flagged." >&2
    status=1
    continue
  fi
  flagged=yes
  # The first line says what a person must do (decisions A371a).
  if gh issue comment "$ticket" --body "$todo

Nothing is working on this ticket. It is in flight ($about), no run is going or queued for it, and nothing has happened on it since $touched, $minutes minutes ago. $next$run_link" >/dev/null; then
    echo "flagged: #$ticket ($about), last touched $minutes minutes ago"
  else
    echo "Ticket #$ticket was flagged needs-human, with nothing working on it, but it could not be told why." >&2
    status=1
  fi
done <<<"$to_flag"
# A ticket flagged with no pull request gave its place back, and it goes to a ticket that waits (decisions T297a).
if [ -n "$flagged" ] && ! "$script_dir/start-waiting.sh"; then
  echo "Tickets were flagged, and the tickets that wait with ready were not all started; each is started when a place next frees." >&2
  status=1
fi
exit "$status"
