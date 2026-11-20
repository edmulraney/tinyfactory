#!/usr/bin/env bash
# Says whether the workflow run this is called in uses a workflow file that main no longer holds or is about to replace.
# Usage: workflow-behind.sh   (from a checkout of the repo; reads GITHUB_WORKFLOW_REF, GITHUB_WORKFLOW_SHA and GITHUB_BASE_REF,
#        and GH_TOKEN to fetch with from a checkout that keeps no token)
#        Prints one sentence when the run is behind, which needs-fresh-run.sh looks for in the job's log: main's
#        file differs from the run's, or from its source in factory/workflows/, whose install is still to come.
#        Prints nothing and exits 0 when it is not, outside a workflow run, or when main cannot be read.
set -euo pipefail

# GitHub names the file as owner/repo/.github/workflows/ci.yml@refs/pull/7/merge.
running="${GITHUB_WORKFLOW_REF:-}"
running="${running%@*}"
case "$running" in
  */.github/workflows/*) file=".github/workflows/${running##*/.github/workflows/}" ;;
  *) echo "not in a workflow run: there is no workflow to compare with main's" >&2; exit 0 ;;
esac
branch="${GITHUB_BASE_REF:-main}"

# Not knowing is no answer: the caller then goes on as it would have without this, and asks for a person.
# The run's file is in the commit GitHub ran it from, its merge of the pull request with main as main was at the push:
# the review job checks out the base, which has main's file (decisions A427e).
# The review job's checkout keeps no token, so git asks for the caller's when GitHub wants one (decisions A541d).
fetch() {
  # shellcheck disable=SC2016
  git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' fetch --quiet origin "$1"
}
if ! [[ "${GITHUB_WORKFLOW_SHA:-}" =~ ^[0-9a-f]{40,64}$ ]] || ! fetch "$GITHUB_WORKFLOW_SHA" 2>/dev/null \
    || ! run=$(git rev-parse --quiet --verify 'FETCH_HEAD^{commit}'); then
  echo "the commit this run's $file came from could not be read, so whether it is the one $branch holds is not known" >&2
  exit 0
fi
if ! fetch "$branch" 2>/dev/null; then
  echo "$branch could not be read, so whether this run's $file is the one $branch holds is not known" >&2
  exit 0
fi
id() { git rev-parse --quiet --verify "$1" 2>/dev/null || echo absent; }
installed=$(id "FETCH_HEAD:$file")
source="factory/workflows/${file##*/}"
merged=$(id "FETCH_HEAD:$source")
if [ "$(id "$run:$file")" != "$installed" ]; then
  change="has changed since this run began"
# Merged, with its install still to come: the run has the file main holds, which is about to go (decisions A541a).
elif [ "$merged" != absent ] && [ "$merged" != "$installed" ]; then
  change="is about to be installed from $source"
else
  exit 0
fi
# A job run again keeps the file, so only a push has main's ci.yml review it (decisions A142c).
echo "$file on $branch $change: this run uses the workflow from before the install. Merge $branch into the branch and push, which starts a run with the workflow $branch holds: git fetch origin $branch && git merge origin/$branch"
