#!/usr/bin/env bash
# Begins a group, as the first job of merge-group.yml: says which pull requests it holds and whether to test them.
# Usage: begin-group.sh <result-file>   (from a checkout of main)
#        Prints, alone on stdout: `main=`, the commit of main the group is tested with; `group=`, a "<pr>:<head>"
#        for each pull request that waits to merge, in the order added; and `test=`, `true` or `false`.
#        Writes the result file, as test-group.sh does, when there is a group and no test to run.
#        Needs GH_TOKEN (actions: write; contents and pull-requests: read) and GITHUB_REPOSITORY.
#        A call that fails stops it with a message and exit 1; `ship.sh --not-begun` then starts the run again (decisions M455j).
set -euo pipefail

result="${1:?Usage: begin-group.sh <result-file>}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

. "$script_dir/shipping.sh"

# A fault that is no pull request's own: those that wait keep their place (decisions M455j).
die() { echo "$1" >&2; exit 1; }

# A merged workflow change is installed by a commit to main some seconds later, and until then lint fails on main
# for every pull request. No event reaches a job that waits, so main is read again (decisions M455f).
installed() { diff -rq factory/workflows .github/workflows >/dev/null 2>&1; }
tries=0
until installed || [ "$tries" -ge 30 ]; do
  tries=$((tries + 1))
  sleep 10
  git fetch --quiet origin main && git checkout --quiet --detach FETCH_HEAD \
    || die "main could not be read again from GitHub, so whether its workflow changes are installed is not known and no group was begun."
done
main=$(git rev-parse HEAD)

waiting=$(retry "$script_dir/merge-queue.sh" list) || die "No group was begun."
group=$(awk 'NF { printf "%s%s:%s", sep, $1, $2; sep = " " }' <<<"$waiting")
echo "main=$main"
echo "group=$group"
if [ -z "$group" ]; then
  echo "No pull request waits to merge." >&2
  echo "test=false"
  exit 0
fi
echo "The group, to merge into main at ${main:0:7}: $group" >&2

if ! installed; then
  jq -n --arg main "$main" '{main: $main, not_tested: "`main` holds a workflow change that was not installed five minutes after it merged, so `pnpm lint` fails on `main` for every pull request, and no group is tested until `.github/workflows/` matches `factory/workflows/`"}' > "$result"
  echo "main's workflow changes are not installed: the group is not tested." >&2
  echo "test=false"
  exit 0
fi

# A group of one that its own `checks` job tested with main as it is now is that test (decisions M17, M19).
# Unsure, it is tested.
if [ "$(wc -l <<<"$waiting" | tr -d ' ')" = 1 ]; then
  read -r pr head <<<"$waiting"
  if run=$("$script_dir/ci-run.sh" "$head" databaseId) && [ -n "$run" ] \
    && tested=$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" --paginate --jq '.artifacts[].name') \
    && grep -qxF "tested-with-main-$main" <<<"$tested"; then
    jq -n --arg main "$main" --argjson pr "$pr" --arg head "$head" \
      '{main: $main, tree: "", pulls: [{number: $pr, head: $head, result: "passed"}]}' > "$result"
    echo "The checks of pull request #$pr passed with main at ${main:0:7}: it merges with no second test." >&2
    echo "test=false"
    exit 0
  fi
fi
echo "test=true"
