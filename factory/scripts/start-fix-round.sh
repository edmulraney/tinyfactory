#!/usr/bin/env bash
# Starts a fix round for a pull request, or the owner's round when given the owner's login (decisions A89b).
# Usage: start-fix-round.sh <pr-number> [owner-login]
#        Needs GH_TOKEN (actions, pull-requests and issues: write; for the owner's round, actions: write and
#        pull-requests: read) and, unless it is the owner's round, GITHUB_REPOSITORY.
#        Prints one sentence saying what it did. A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

pr="${1:?Usage: start-fix-round.sh <pr-number> [owner-login]}"; owner="${2:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

# A draft gets no round, the owner's included: its engineer is still building it (decisions A50b).
pull=$(gh pr view "$pr" --json isDraft,labels --jq '"\(.isDraft) \([.labels[].name] | index("waits-for-main") != null)"') \
  || die "No fix round was started for pull request #$pr: GitHub did not say whether it is a draft."
read -r draft marked <<<"$pull"
if [ "$draft" = true ]; then
  echo "pull request #$pr is a draft, which its engineer is still building: no fix round was started"
  exit 0
fi

# The owner's round is not counted: the three stop agents looping, and the owner asking is a decision (decisions A48a).
if [ -n "$owner" ]; then
  requested=$("$script_dir/owner-review.sh" "$pr" "$owner") \
    || die "No fix round was started for pull request #$pr: whether $owner sent it back could not be read."
  if [ -z "$requested" ]; then
    echo "no fix round was started for pull request #$pr: the latest verdict of $owner does not ask for changes to the commit that is there now"
    exit 0
  fi
  whose="the owner's fix round"
else
  # What failed lies outside it, so a round would fix nothing; flagged, it holds no place (decisions A368b, T361b).
  if [ "$marked" = true ]; then
    gh pr edit "$pr" --add-label needs-human >/dev/null \
      || die "Pull request #$pr is labelled waits-for-main, and needs-human could not be added to it, so it still holds a place among the tickets being built."
    echo "pull request #$pr is labelled waits-for-main, as what failed lies outside it: no fix round was started, and the next merge tests it again"
    exit 0
  fi
  rounds=$("$script_dir/fix-rounds.sh" "$pr") \
    || die "No fix round was started for pull request #$pr: its fix rounds could not be counted."

  if [ "$rounds" -ge 3 ]; then
    # A failure no engineer can fix must not stop it: begin-fix-round.sh runs checks again in fix.yml (decisions A134a).
    failures=$(mktemp)
    trap 'rm -f "$failures"' EXIT
    "$script_dir/collect-failures.sh" "$failures" "$pr" >&2 \
      || die "Pull request #$pr has used its three fix rounds, and what failed on it could not be read, so it was neither stopped nor checked again."
    alarm=$("$script_dir/false-alarm.sh" "$pr" "$failures") \
      || die "Pull request #$pr has used its three fix rounds, and whether an engineer can fix what failed is not known, so it was neither stopped nor checked again."
    # Nor must a ci.yml main no longer holds: begin-fix-round.sh begins the round for a fresh run (decisions A142a).
    fresh=false
    [ "$alarm" = true ] || fresh=$("$script_dir/needs-fresh-run.sh" "$pr" "$failures") \
      || die "Pull request #$pr has used its three fix rounds, and whether it needs only a fresh ci run is not known, so it was neither stopped nor given one."
    if [ "${fresh%% *}" = true ]; then
      gh workflow run fix.yml -f pr="$pr" >/dev/null \
        || die "Pull request #$pr could not be given a fresh ci run: GitHub did not start fix.yml."
      echo "the ci run of pull request #$pr uses a ci.yml main no longer holds, which is no fault of the pull request: fix.yml was started for the round that gets it a fresh run, and none of the three is used"
      exit 0
    fi
    if [ "$alarm" != true ]; then
      # Its own message says which call failed.
      "$script_dir/stop-fix-rounds.sh" "$pr" || exit 1
      echo "pull request #$pr has used its three fix rounds: no fix round was started, and it waits for a person"
      exit 0
    fi
    gh workflow run fix.yml -f pr="$pr" >/dev/null \
      || die "The checks of pull request #$pr could not be run again: GitHub did not start fix.yml."
    echo "the checks of pull request #$pr failed because the workflows on main had not settled, which no engineer can fix: fix.yml was started to run them again, and no fix round is used"
    exit 0
  fi
  whose="a fix round"
fi

# Started once and never retried: a start that failed may have happened (decisions M26).
gh workflow run fix.yml -f pr="$pr" >/dev/null \
  || die "The fix round for pull request #$pr could not be started: GitHub did not start fix.yml."
echo "$whose was started for pull request #$pr"
