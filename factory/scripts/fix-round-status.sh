#!/usr/bin/env bash
# Sets the status "fix round" on a commit, so that a pull request's checks say a round is running, then how it ended.
# Usage: fix-round-status.sh <commit> <round's name> working <engineer>
#        fix-round-status.sh <commit> <round's name> <how the job stands>
#        The round's name is the `label` begin-fix-round.sh wrote.
#        Needs GH_TOKEN (statuses: write) and GITHUB_REPOSITORY. Links the run when GITHUB_RUN_ID is set.
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

usage="Usage: fix-round-status.sh <commit> <round's name> working <engineer> | <how the job stands>"
commit="${1:?$usage}"; label="${2:?$usage}"; how="${3:?$usage}"; name="${4:-}"

# A round runs in fix.yml, which is not one of the pull request's checks (decisions A124d).
case "$how" in
  working) state=pending; description="$label: ${name:?$usage} is working" ;;
  success) state=success; description="$label has ended" ;;
  *)       state=failure; description="$label failed: its run says why" ;;
esac

run=""
[ -z "${GITHUB_RUN_ID:-}" ] || run="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
# The same context each time, so the second call replaces the first.
gh api "repos/$GITHUB_REPOSITORY/statuses/$commit" -f state="$state" -f context="fix round" -f description="$description" ${run:+-f "target_url=$run"} >/dev/null \
  || { echo "Could not set the status \"$description\" on ${commit:0:7}, so the pull request's checks do not show it." >&2; exit 1; }
echo "set the status on ${commit:0:7}: $description"
