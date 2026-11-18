#!/usr/bin/env bash
# Ships a pull request the repo's owner approved, once its checks passed for that commit: approve-merge.yml runs it.
# Usage: approve-merge.sh <pr-number> <owner-login>
#        Needs what ship.sh needs: GH_TOKEN, PRODUCTION_URL and, when set, BOARD_TOKEN.
set -euo pipefail

pr="$1"; owner="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

view=$(retry gh pr view "$pr" --json state,headRefOid,reviews) \
  || not_merged "GitHub did not return this pull request, so its approval could not be checked"
if [ "$(jq -r .state <<<"$view")" != OPEN ]; then echo "pull request #$pr is not open; nothing to do"; exit 0; fi
head=$(jq -r .headRefOid <<<"$view")
# A push after the approval needs a fresh one.
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

exec "$script_dir/ship.sh" "$pr" "$head"
