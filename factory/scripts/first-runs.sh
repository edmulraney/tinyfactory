#!/usr/bin/env bash
# Starts a retro for the first finished run of each workflow a merged pull request changed (decisions A185a).
# Usage: first-runs.sh
#        Needs GH_TOKEN (pull-requests: write, actions: write).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

status=0
failed() { echo "$1" >&2; status=1; }

# Read on a line of its own, so that a failed read is never taken for "nothing waits" (decisions H7).
waiting=$(retry gh pr list --state merged --label proof --limit 100 --json number --jq '.[].number') \
  || { echo "Could not list the merged pull requests labelled \`proof\`, so no first run of a changed workflow was looked for." >&2; exit 1; }

for pr in $waiting; do
  # The REST list names the account in full, and only the workflow's own counts: anyone can write a comment.
  if ! comments=$(retry gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
      --jq '.[] | select(.user.login == "github-actions[bot]") | {at: .created_at, body: (.body // "")}'); then
    failed "Could not read the comments of pull request #$pr, so the first runs of the workflows it changed were not looked for."
    continue
  fi
  record=$(jq -sr '[.[] | {at} + (.body | split("\n") | map(select(. != "")) | last // ""
                     | capture("^<!-- factory:installed (?<files>.*) -->$"))]
                   | last // empty | "\(.at) \(.files)"' <<<"$comments")
  if [ -z "$record" ]; then
    echo "pull request #$pr is labelled \`proof\` and holds no record of an install: nothing to look for"
    continue
  fi
  at="${record%% *}"; files="${record#* }"

  pending=0
  for file in $files; do
    # The name goes into the address below, so anything that could not be a workflow's is left out.
    [[ "$file" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || { echo "pull request #$pr: \"$file\" is not a workflow file's name; not looked for"; continue; }
    marker="<!-- factory:first-run $file -->"
    if jq -se --arg marker "$marker" 'any(.[]; .body | startswith($marker))' <<<"$comments" >/dev/null; then continue; fi

    if ! runs=$(retry gh api --method GET "repos/{owner}/{repo}/actions/workflows/$file/runs" \
        -f status=completed -f created=">=$at" -f per_page=100 --paginate \
        --jq '.workflow_runs[] | select(.conclusion != "skipped" and .conclusion != "cancelled") | "\(.created_at) \(.id) \(.html_url)"'); then
      failed "Could not list the runs of $file since pull request #$pr changed it, so its first run was not looked for. If the workflow is gone, take the \`proof\` label off #$pr."
      pending=1
      continue
    fi
    if [ -z "$runs" ]; then
      echo "no run of $file has finished since pull request #$pr changed it"
      pending=1
      continue
    fi
    read -r _ id url <<<"$(sort <<<"$runs" | head -n 1)"

    # Started once and not retried: a call that failed may still have started it (decisions M26).
    if ! gh workflow run retro.yml -f pr="$pr" -f run="$id"; then
      failed "The retro of run $id, the first of $file since pull request #$pr changed it, could not be started."
      pending=1
      continue
    fi
    if ! retry gh pr comment "$pr" --body "${marker}A retro is looking at the first run of \`$file\` since this pull request changed it, and will say here what it finds: $url" >/dev/null; then
      failed "A retro was started for run $id, the first of $file since pull request #$pr changed it, but the comment that records it could not be posted: the next merge starts it again."
      pending=1
      continue
    fi
    echo "started a retro of run $id, the first of $file since pull request #$pr changed it"
  done

  [ "$pending" -eq 0 ] || continue
  retry gh pr edit "$pr" --remove-label proof >/dev/null \
    || failed "Every workflow pull request #$pr changed has had its retro, but the \`proof\` label could not be taken off it."
done
exit "$status"
