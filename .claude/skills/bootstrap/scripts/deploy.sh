#!/usr/bin/env bash
# Deploys main to production and waits until production's health endpoint reports main's commit.
# Usage: deploy.sh [name]   (name defaults to the directory name)
#        Runs after every step that sets an environment variable, which a deployment reads when it is built.
#        Safe to re-run: production that already reports main's commit, built after its variables last changed,
#        is not deployed again.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
vc() { npx --yes vercel@latest "$@"; }

if ! sha=$(gh api "repos/$owner/$name/commits/main" --jq .sha) || [ -z "$sha" ]; then
  echo "deploy.sh: could not read the commit on main of $owner/$name." >&2
  exit 1
fi
if ! url=$(gh variable get PRODUCTION_URL -R "$owner/$name") || [ -z "$url" ]; then
  echo "deploy.sh: $owner/$name has no repo variable PRODUCTION_URL, which vercel.sh sets: run the same command again." >&2
  exit 1
fi

live() {
  mark done "deploy ok: $url runs main ($sha)"
  [ -z "${SETUP_PRODUCTION:-}" ] || printf '%s\n' "$url" > "$SETUP_PRODUCTION"
}

# built_after_variables: production's newest deployment was built after every production variable last changed.
# A deployment reads its variables when it is built (decisions S677d).
built_after_variables() {
  local built changed
  if ! built=$(vc api "/v6/deployments?projectId=$name&target=production&state=READY&limit=1" --raw 2>/dev/null | tail -1 \
    | jq -er '.deployments[0].created // 0' 2>/dev/null); then
    echo "deploy.sh: could not read when production of '$name' was built (GET /v6/deployments)." >&2
    exit 1
  fi
  if ! changed=$(vc api "/v9/projects/$name/env" --raw 2>/dev/null | tail -1 \
    | jq -er '[.envs[] | select([.target] | flatten | index("production")) | .updatedAt // .createdAt] | max // 0' 2>/dev/null); then
    echo "deploy.sh: could not read the environment variables of '$name' (GET /v9/projects/$name/env)." >&2
    exit 1
  fi
  [ "$built" -ge "$changed" ]
}

reported=$(curl -fsS --max-time 10 "$url/api/health" 2>/dev/null | jq -r '.commit // empty' 2>/dev/null || true)
if [ "$reported" = "$sha" ] && built_after_variables; then
  echo "production already reports $sha, built after its variables last changed, skipping the deployment"
  live
  exit 0
fi

# github.sh pushed main before vercel.sh made the project, and Vercel deploys only a push it saw (decisions S677a).
deployment=$(jq -n --arg name "$name" --arg owner "$owner" --arg sha "$sha" \
  '{name: $name, project: $name, target: "production", gitSource: {type: "github", org: $owner, repo: $name, ref: "main", sha: $sha}}')
if ! created=$(vc api /v13/deployments -X POST --input - --raw <<<"$deployment" 2>&1); then
  echo "$created" >&2
  echo "deploy.sh: Vercel refused to deploy main ($sha) of '$name' to production." >&2
  exit 1
fi
echo "deploying main ($sha) to production: $(tail -1 <<<"$created" | jq -r '.inspectorUrl // empty' 2>/dev/null || true)"

if ! "$PWD/factory/scripts/wait-for-deploy.sh" "$url" "$sha"; then
  # A build may lack what a step still waiting for the owner sets, so setup lists that step instead (decisions S677b).
  if [ -s "${SETUP_NEEDS_OWNER:-/dev/null}" ]; then
    echo "production did not report main's commit: the deployment runs again when you rerun setup after the steps above"
    exit 0
  fi
  echo "deploy.sh: production did not report main's commit: Vercel's dashboard shows the deployment's build log." >&2
  exit 1
fi
live
