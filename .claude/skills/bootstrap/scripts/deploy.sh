#!/usr/bin/env bash
# Deploys main to production and waits until production reports it, so that setup ends with the app live.
# `github.sh` pushes the first commit before `vercel.sh` connects the repo, and Vercel deploys only on a later push.
# Usage: deploy.sh [name]   (name defaults to the directory name)
#        Safe to re-run: it does nothing when production already reports the commit on main.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
vc() { npx --yes vercel@latest "$@"; }

url=$(gh variable get PRODUCTION_URL -R "$owner/$name" 2>/dev/null) \
  || { echo "deploy.sh: the repo variable PRODUCTION_URL is not set, so production cannot be checked; run the same command again." >&2; exit 1; }
commit=$(gh api "repos/$owner/$name/commits/main" --jq .sha)
# One look, for a re-run: the wait after a deployment is factory/scripts/wait-for-deploy.sh's.
live=$(curl -fsS --max-time 10 "$url/api/health" 2>/dev/null | jq -r '.commit // empty' 2>/dev/null || true)
if [ "$live" = "$commit" ]; then
  mark done "deploy ok: $url runs ${commit:0:7}, the commit on main"
  exit 0
fi

# Deployed from the repo, not from this folder, so the build carries the commit the health check reports.
body=$(jq -n --arg name "$name" --argjson repo "$(gh api "repos/$owner/$name" --jq .id)" \
  '{name: $name, project: $name, target: "production", gitSource: {type: "github", repoId: $repo, ref: "main"}}')
errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
# Only stdout is the answer: the CLI writes its banner to stderr, which is shown only when the call fails.
if ! created=$(vc api /v13/deployments -X POST --input - --raw <<<"$body" 2>"$errors") || ! id=$(jq -er '.id' <<<"$created" 2>/dev/null); then
  cat "$errors" >&2
  echo "$created" >&2
  echo "deploy.sh: Vercel did not start a production deployment of main." >&2
  exit 1
fi
echo "deploying ${commit:0:7} to production ($id)"

# Vercel ends a build that overruns its own limit as ERROR or CANCELED, so only repeated failed reads stop the wait.
failed_reads=0
while :; do
  if ! state=$(vc api "/v13/deployments/$id" --raw 2>/dev/null | jq -er '.readyState' 2>/dev/null); then
    failed_reads=$((failed_reads + 1))
    [ "$failed_reads" -lt 6 ] || { echo "deploy.sh: Vercel did not answer six reads of the deployment $id in a row." >&2; exit 1; }
    sleep 10
    continue
  fi
  failed_reads=0
  case "$state" in
    READY) break ;;
    ERROR | CANCELED)
      echo "deploy.sh: the production deployment $id ended $state; its build log is in Vercel's dashboard, under the project '$name'." >&2
      exit 1 ;;
  esac
  sleep 10
done

factory/scripts/wait-for-deploy.sh "$url" "$commit" \
  || { echo "deploy.sh: the deployment $id is ready, but $url/api/health does not report ${commit:0:7}." >&2; exit 1; }
mark done "deploy ok: $url runs ${commit:0:7}, the commit on main"
