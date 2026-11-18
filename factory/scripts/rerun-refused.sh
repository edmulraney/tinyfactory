#!/usr/bin/env bash
# Runs again, once and oldest first, the jobs GitHub refused to start for billing (decisions H220a, H220e).
# Usage: rerun-refused.sh   (by flag-idle.yml on its schedule, and by the driver once jobs start again)
#        Needs GH_TOKEN (actions: write, checks: read) and GH_REPO, or a checkout gh can read.
set -euo pipefail

die() { echo "$1, so nothing was run again." >&2; exit 1; }
refusal="The job was not started because recent account payments have failed or your spending limit needs to be increased"

# Each answer is read on a line of its own (decisions H7). GitHub lists the newest run first.
# Runs of the last day, those still in progress among them (decisions H220d, H220f).
# jq works the time out: GNU and BSD date disagree on how to ask for a day ago.
since=$(jq -rn 'now - 86400 | todate') || die "The time a day ago could not be worked out"
runs=$(gh api --method GET "repos/{owner}/{repo}/actions/runs" -f "created=>=$since" -f per_page=100 \
  --jq '.workflow_runs[] | "\(.id) \(.conclusion) \(.run_attempt) \(.name): \(.display_title)"') \
  || die "The latest runs could not be listed from GitHub"

found=""
refused=""
while read -r id conclusion attempt title; do
  [ -n "$id" ] || continue
  if [ "$attempt" = 1 ] && [ "$conclusion" != failure ]; then
    [ "$conclusion" = success ] || continue
  else
    # The first attempt is read: a run already run again still marks its outage (decisions H220d).
    steps=$(gh api "repos/{owner}/{repo}/actions/runs/$id/attempts/1/jobs?per_page=100" --paginate \
      --jq '.jobs[] | "\(.id) \(.conclusion) \(.steps // [] | length)"') \
      || die "The jobs of run $id ($title) could not be read from GitHub"
    [ -n "$steps" ] || continue
    was_refused=""
    for job in $(awk '$2 == "failure" && $3 == 0 { print $1 }' <<<"$steps"); do
      annotations=$(gh api "repos/{owner}/{repo}/check-runs/$job/annotations?per_page=100" --jq '.[].message') \
        || die "What GitHub said of job $job in run $id ($title) could not be read"
      [[ "$annotations" == *"$refusal"* ]] || continue
      was_refused=1
      found=1
      # A run already run again is left, whatever came of it (decisions H220b).
      # Each newer line goes below, which leaves the oldest first.
      # The look that calls this is never run again beside itself (decisions T271g).
      [ "$attempt" != 1 ] || [[ "$title" == "flag-idle: "* ]] || refused="$id $title"$'\n'"$refused"
      break
    done
    # A run refused in part does not end the search: its other jobs began before the refusals or after them.
    [ -z "$was_refused" ] || continue
    grep -qv ' 0$' <<<"$steps" || continue
  fi
  # A run that started ahead of the refusals found ends the search (decisions H220c).
  [ -z "$found" ] || break
done <<<"$runs"

if [ -z "$refused" ]; then
  echo "No run among the latest 100 of the last day was refused for billing and not yet run again: nothing to run again."
  exit 0
fi

status=0
while read -r id title; do
  [ -n "$id" ] || continue
  # Asked once: a call that failed may still have started it (decisions M26).
  if gh run rerun "$id" --failed >/dev/null </dev/null; then
    echo "running again: $id $title"
  else
    echo "Run $id ($title) was refused for billing, and GitHub did not run it again." >&2
    status=1
  fi
done <<<"$refused"
exit "$status"
