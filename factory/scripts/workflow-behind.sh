#!/usr/bin/env bash
# Says whether the workflow run this is called in uses a workflow file that main no longer holds.
# Usage: workflow-behind.sh   (from the checkout of the run; reads GITHUB_WORKFLOW_REF and GITHUB_BASE_REF)
#        Prints one sentence when the run is behind, which needs-fresh-run.sh looks for in the job's log.
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
if ! git fetch --quiet origin "$branch" 2>/dev/null; then
  echo "$branch could not be read, so whether this run's $file is the one $branch holds is not known" >&2
  exit 0
fi
# The run's file is the one its checkout holds: GitHub's merge of the pull request with main as main was at the push.
id() { git rev-parse --quiet --verify "$1:$file" 2>/dev/null || echo absent; }
[ "$(id HEAD)" != "$(id FETCH_HEAD)" ] || exit 0
# The Claude app gives a token only in a run whose file is main's, and a rerun keeps the file (decisions A89a, A142c).
echo "$file on $branch has changed since this run began: this run uses the workflow from before the install, and no reviewer is given a token in a run whose workflow is not the one $branch holds. Merge $branch into the branch and push, which starts a run with the workflow $branch holds: git fetch origin $branch && git merge origin/$branch"
