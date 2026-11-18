#!/usr/bin/env bash
# Creates the Vercel project and connects it to the GitHub repo, so pushes to main deploy to
# production and pull requests get preview URLs. Safe to re-run.
# Usage: vercel.sh [name]   (name defaults to the directory name)
set -euo pipefail

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
vc() { npx --yes vercel@latest "$@"; }

if vc api "/v9/projects/$name" --raw >/dev/null 2>&1; then
  echo "vercel project '$name' already exists, skipping create"
else
  cat <<EOF | vc api /v11/projects -X POST --input - --raw
{
  "name": "$name",
  "framework": "nextjs",
  "rootDirectory": "apps/web",
  "gitRepository": { "type": "github", "repo": "$owner/$name" }
}
EOF
fi

# Workflows confirm a merge is live by asking production's health endpoint; tell them where it is.
domain=$(vc api "/v9/projects/$name/domains" --raw 2>/dev/null | jq -r '.domains[0].name // empty')
if [ -n "$domain" ]; then
  gh variable set PRODUCTION_URL -R "$owner/$name" --body "https://$domain"
  echo "production URL: https://$domain (stored as repo variable PRODUCTION_URL)"
fi

echo
echo "vercel ok: project '$name' linked to $owner/$name (root apps/web)"
