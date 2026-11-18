#!/usr/bin/env bash
# Runs `fits-main` again for a pull request: the ci.yml job that tests it merged with main as it is (decisions M16).
# Usage: rerun-fits-main.sh <pr-number> [seconds to wait for a run that is ending]
#        Needs GH_TOKEN (actions: write, pull-requests: read); GITHUB_RUN_ID says which run this is.
set -euo pipefail

pr="$1"; wait="${2:-0}"

# Each answer is read on a line of its own, so a failed read stops the script (decisions H7).
head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
run=$("$(dirname "$0")/ci-run.sh" "$head" databaseId,status)
if [ -z "$run" ]; then
  # GitHub starts no run for a push that already conflicts, so there is no job to run again.
  echo "pull request #$pr has no ci run for its head ${head:0:7}, so there is no fits-main to run again" >&2
  exit 1
fi
id="${run%% *}"; status="${run##* }"

# GitHub re-runs nothing in a run that is still going (decisions M20).
if [ "$status" != completed ]; then
  if [ "$id" = "${GITHUB_RUN_ID:-}" ]; then
    gh workflow run rerun-fits-main.yml -f pr="$pr" >/dev/null
    echo "fits-main will run again for pull request #$pr as soon as this run has ended"
    exit 0
  fi
  # Any other run is waited for, then left alone: its own fits-main and merge gate have still to judge the pull request.
  deadline=$(( $(date +%s) + wait ))
  while [ "$status" != completed ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 5
    status=$(gh run view "$id" --json status --jq .status)
  done
  if [ "$status" != completed ]; then
    echo "the ci run for pull request #$pr is still going, and tests it with main itself before it merges"
    exit 0
  fi
fi

job=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --paginate --jq '.jobs[] | select(.name == "fits-main") | .id')
if [ -z "$job" ]; then
  echo "the ci run for pull request #$pr began before fits-main was installed, so it has no such job to run again"
  exit 0
fi
gh run rerun --job "$job" >/dev/null
echo "fits-main is running again for pull request #$pr"
