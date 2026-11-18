#!/usr/bin/env bash
# Runs `checks` again for a pull request, in the latest ci run for its head (decisions A134a).
# Usage: rerun-checks.sh <pr-number> [seconds to wait for the run to end]
#        Needs GH_TOKEN (actions: write, pull-requests: read).
set -euo pipefail

pr="${1:?Usage: rerun-checks.sh <pr-number> [seconds to wait for the run to end]}"; wait="${2:-0}"

die() { echo "$1" >&2; exit 1; }
unread="so its checks were not run again"

# Each answer is read on a line of its own (decisions H7).
head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid) \
  || die "Could not read pull request #$pr from GitHub, $unread."
run=$("$(dirname "$0")/ci-run.sh" "$head" databaseId,status) \
  || die "Could not list the ci runs for ${head:0:7}, the head of pull request #$pr, $unread."
[ -n "$run" ] || die "Pull request #$pr has no ci run for its head ${head:0:7}, $unread."
id="${run%% *}"; status="${run##* }"

# GitHub re-runs nothing in a run that is still going, so the run is waited for (decisions A134a).
deadline=$(( $(date +%s) + wait ))
while [ "$status" != completed ] && [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 5
  status=$(gh run view "$id" --json status --jq .status) \
    || die "Could not read whether ci run $id for pull request #$pr has ended, $unread."
done
[ "$status" = completed ] || die "The ci run $id for pull request #$pr had not ended after $wait seconds, $unread."

job=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --paginate --jq '.jobs[] | select(.name == "checks") | .id') \
  || die "Could not list the jobs of ci run $id for pull request #$pr, $unread."
[ -n "$job" ] || die "The ci run $id for pull request #$pr has no job named checks, $unread."
gh run rerun --job "$job" >/dev/null \
  || die "GitHub did not run checks again in ci run $id for pull request #$pr."
echo "checks is running again for pull request #$pr"
