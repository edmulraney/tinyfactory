#!/usr/bin/env bash
# Writes what failed on a pull request to a file: each failed job's log tail, a conflict, an overtaken workflow.
# Usage: collect-failures.sh <output-file> <pr-number>
#        Needs GH_TOKEN (actions, contents and pull-requests: read) and GITHUB_REPOSITORY.
set -euo pipefail

[ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "Usage: collect-failures.sh <output-file> <pr-number>" >&2; exit 1; }
out="$1"; pr="$2"

# The file is not left behind half-written.
die() { rm -f "$out"; echo "$1" >&2; exit 1; }
# Holds what gh says when a log does not come (decisions A236).
error_file=$(mktemp) || die "Could not make a temporary file, so what failed on pull request #$pr was not collected."
trap 'rm -f "$error_file"' EXIT

: > "$out"
# GitHub answers UNKNOWN for `mergeable` until it has worked it out, some time after a push or a merge.
for try in 1 2 3 4 5 6; do
  pull=$(gh pr view "$pr" --json headRefOid,baseRefName,mergeable --jq '"\(.headRefOid) \(.baseRefName) \(.mergeable)"') \
    || die "Could not read pull request #$pr from GitHub, so what failed on it is not known."
  read -r head base mergeable <<<"$pull"
  if [ "$mergeable" != UNKNOWN ] || [ "$try" -eq 6 ]; then break; fi
  sleep 5
done
run=$("$(dirname "$0")/ci-run.sh" "$head" databaseId) \
  || die "Could not list the ci runs for ${head:0:7}, the head of pull request #$pr, so what failed on it is not known."
if [ "$mergeable" = CONFLICTING ]; then
  {
    echo "===== conflict with $base ====="
    echo "GitHub reports that this pull request conflicts with $base as it is now, and runs no checks on it until it does not."
    echo "Merge $base into the branch (git fetch origin $base && git merge origin/$base), resolve the conflict and push."
    echo
  } >> "$out"
fi
# Git sees no conflict in it, and ship.sh does not merge it (decisions W281a, W281b).
overtaken=$("$(dirname "$0")/overtaken.sh" "$pr" "$base" "$head") \
  || die "Could not read whether $base has overtaken a workflow change in pull request #$pr, so what there is to fix on it is not known."
if [ -n "$overtaken" ]; then
  {
    echo "===== overtaken by $base ====="
    echo "$overtaken"
    echo "The installer installs a workflow change only when $base still holds the source its diff was made against, so this pull request is not merged as it is."
    echo "Merge $base into the branch (git fetch origin $base && git merge origin/$base), keep both changes and push; the new commit is then checked and merged like any other."
    echo
  } >> "$out"
fi

failed=""
if [ -n "$run" ]; then
  failed=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/jobs" --paginate \
      --jq '.jobs[] | select(.conclusion == "failure")
        | "\(.id)\t\(.name)\t\([.steps[]? | select(.conclusion == "failure") | .name] | join("; "))"') \
    || die "Could not list the jobs of workflow run $run, so which of them failed is not known."
fi
while IFS=$'\t' read -r id name steps; do
  [ -n "$id" ] || continue
  {
    echo "===== failed job: $name ====="
    # GitHub takes a while to serve a job's log after the job ends (decisions A19).
    log=""
    for _ in 1 2 3 4 5 6; do
      # gh refuses to print a log that holds a colour code unless asked (decisions A284).
      log=$(gh api "repos/$GITHUB_REPOSITORY/actions/jobs/$id/logs" --allow-escape-sequences 2>"$error_file") && [ -n "$log" ] && break
      log=""; sleep 10
    done
    if [ -n "$log" ]; then
      sed -E -e 's/^[0-9T:.-]+Z //' -e $'s/\033\\[[0-9;?]*[A-Za-z]//g' <<<"$log" | { grep -v '^##\[group\]\|^##\[endgroup\]' || true; } | tail -n 150
    else
      echo "(log not available after a minute; read the failed job on the pull request's Checks tab)"
      echo "failed steps: ${steps:-none that GitHub lists}"
      # Indented, so no line of it reads as a heading to false-alarm.sh or needs-fresh-run.sh.
      if [ -s "$error_file" ]; then echo "gh's last error:"; sed 's/^/  /' "$error_file"; else echo "gh's last answer: an empty log, with no error"; fi
    fi
    echo
  } >> "$out"
done <<<"$failed"
echo "wrote $(wc -l < "$out" | tr -d ' ') lines to $out"
