#!/usr/bin/env bash
# Makes a pull request the repo's owner approved wait to merge, once its checks passed for that commit.
# Usage: approve-merge.sh <pr-number> <owner-login>
#        Needs GH_TOKEN (pull-requests, issues and actions: write).
set -euo pipefail

pr="$1"; owner="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

view=$(retry gh pr view "$pr" --json state,headRefOid,reviews,isDraft,author) \
  || not_merged "GitHub did not return this pull request, so its approval could not be checked"
if [ "$(jq -r .state <<<"$view")" != OPEN ]; then echo "pull request #$pr is not open; nothing to do"; exit 0; fi
head=$(jq -r .headRefOid <<<"$view")
# A commit pushed after the approval is the merge gate's to judge (decisions M456a).
approved=$(jq -r --arg owner "$owner" --arg head "$head" \
  '[.reviews[] | select(.author.login == $owner)] | last | (.state == "APPROVED" and .commit.oid == $head)' <<<"$view")
if [ "$approved" != true ]; then echo "the owner has not approved commit ${head:0:7}; nothing to do"; exit 0; fi

# Once the owner is told, nothing failed: a green run starts no retro (decisions M78).
not_passed() {
  notify_not_merged "the checks for ${head:0:7} have not passed ($1)" || exit 1
  exit 0
}

# The run that judges the commit is never one that was skipped (decisions M205).
run=$(retry "$script_dir/ci-run.sh" "$head" databaseId,conclusion) \
  || not_merged "GitHub did not return the checks for ${head:0:7}, so nothing shows they passed"
id="${run%% *}"; checks="${run#* }"

# No ci run of the commit ran its jobs, so a second approval would find none either (decisions M543a).
# A draft is still being built (decisions A50b), and a fix round runs only for a pull request the factory opened (decisions A89f).
if [ -z "$run" ] && [ "$(jq -r '"\(.isDraft) \(.author.login)"' <<<"$view")" = "false app/claude" ]; then
  unrun="no ci run of ${head:0:7} ran its jobs"
  started=$(retry "$script_dir/fix-rounds.sh" "$pr" start-checks "$head") \
    || not_merged "GitHub did not return this pull request's comments, so whether the checks for ${head:0:7} were started before is not known"
  if [ "$started" -ne 0 ]; then
    # Once for a commit (decisions M543b), then the owner's own click starts them (decisions M543c).
    notify_not_merged "$unrun, and the fix round the factory started for that commit left it so" \
      "Convert this pull request to a draft, then mark it ready for review: that starts its checks, and it merges when they pass." || exit 1
    exit 0
  fi
  # The record first, so that a start GitHub refuses is not made again at the next approval (decisions M543b).
  retry gh pr comment "$pr" --body "<!-- factory:checks-started $head -->Nothing to do: the factory is starting the checks for ${head:0:7}, and this pull request merges when they pass, with the approval it has.

No ci run of ${head:0:7} ran its jobs. A fix round that is not one of the three marks this pull request ready for review again, which starts them." >/dev/null \
    || not_merged "GitHub did not take the comment that says the checks for ${head:0:7} are being started, so they were not started"
  # Never asked twice: a start that failed may have happened (decisions M26).
  if ! gh workflow run fix.yml -f pr="$pr" >/dev/null; then
    notify_not_merged "$unrun, and GitHub did not start \`fix.yml\`, the fix round that starts them" \
      "Start the fix round: \`gh workflow run fix.yml -f pr=$pr\`. It starts the checks, and this pull request merges when they pass." || true
    exit 1
  fi
  echo "$unrun: fix.yml was started for the round that starts them"
  exit 0
fi

case "$checks" in
  success) ;;
  failure)
    # A failed merge fails the ci run it was a job of, and approving again must be able to retry it (decisions M31).
    jobs=$(retry gh api "repos/{owner}/{repo}/actions/runs/$id/jobs" --paginate --jq '.jobs[] | "\(.name) \(.conclusion)"') \
      || not_merged "GitHub did not return the jobs of the checks for ${head:0:7}, so nothing shows which of them failed"
    others=$(grep -v '^merge ' <<<"$jobs" | grep -vE ' (success|skipped)$' | sed 's/ [^ ]*$//' | paste -sd, - | sed 's/,/, /g' || true)
    if [ -n "$others" ] || ! grep -qx 'merge failure' <<<"$jobs"; then
      not_passed "ci failed${others:+: $others}"
    fi ;;
  *) not_passed "ci: ${checks:-none has finished}" ;;
esac

exec "$script_dir/merge-queue.sh" add "$pr" "$head"
