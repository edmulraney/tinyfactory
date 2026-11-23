#!/usr/bin/env bash
# Prints the ci run that judges a commit: the newest this repository started that was not skipped, or nothing.
# Usage: ci-run.sh <commit> <fields>
#        The fields are comma-separated, from databaseId, status, conclusion and attempt: `databaseId,status` prints "900 completed".
#        Needs GH_TOKEN (actions: read).
set -euo pipefail

commit="${1:?Usage: ci-run.sh <commit> <fields>}"; fields="${2:?Usage: ci-run.sh <commit> <fields>}"

IFS=, read -r -a names <<<"$fields,"
for name in "${names[@]}"; do
  case "$name" in
    databaseId | status | conclusion | attempt) ;;
    *) echo "ci-run.sh: the fields must be databaseId, status, conclusion or attempt, separated by commas, not: $fields" >&2; exit 1 ;;
  esac
done
show="\"\\(.${fields//,/) \\(.})\""

# Only a run this repository started judges the commit (decisions M668a), and a skipped one judges nothing (decisions M205).
# Every page (decisions M668b).
runs=$(gh api "repos/{owner}/{repo}/actions/workflows/ci.yml/runs?per_page=100&head_sha=$commit" \
  --jq ".workflow_runs[] | select(.head_repository.full_name == .repository.full_name and .conclusion != \"skipped\")
        | {databaseId: .id, status, conclusion: (.conclusion // \"\"), attempt: .run_attempt} | $show" --paginate)
[ -z "$runs" ] || head -n 1 <<<"$runs"
