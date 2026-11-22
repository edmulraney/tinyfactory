#!/usr/bin/env bash
# Creates the Vercel project and connects it to the GitHub repo: main deploys to production, pull requests to previews.
# Switches on the project's Web Analytics.
# Usage: vercel.sh [name]   (name defaults to the directory name)
#        Safe to re-run: a project that exists is not made again.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
vc() { npx --yes vercel@latest "$@"; }

if vc api "/v9/projects/$name" --raw >/dev/null 2>&1; then
  echo "vercel project '$name' already exists, skipping create"
else
  project=$(jq -n --arg name "$name" --arg repo "$owner/$name" \
    '{name: $name, framework: "nextjs", rootDirectory: "apps/web", gitRepository: {type: "github", repo: $repo}}')
  if ! created=$(vc api /v11/projects -X POST --input - --raw <<<"$project" 2>&1); then
    echo "$created" >&2
    # Vercel reaches a repository through its GitHub App, which an account may have installed on
    # selected repositories only. A repository made a moment ago is then one it cannot see.
    if grep -qF "couldn't be found" <<<"$created"; then
      owner_block >&2 <<NOTE
Let Vercel see the repository $owner/$name: its GitHub App is installed on selected repositories only.
https://github.com/apps/vercel/installations/new
   choose   your account, then "All repositories" (or add $name to the selected ones)
Then run the same command again. The Claude app needs the same:
https://github.com/apps/claude
NOTE
    fi
    exit 1
  fi
  echo "$created"
fi

# Web Analytics counts the visitors that the layout's Analytics component reports (decisions S644a).
# Its switch takes the project's id, not its name (decisions S644b).
if ! project=$(vc api "/v9/projects/$name" --raw 2>&1) || ! project_id=$(jq -er '.id' <<<"$project" 2>/dev/null); then
  echo "$project" >&2
  echo "vercel.sh: could not read the id of the Vercel project '$name' (GET /v9/projects/$name)." >&2
  exit 1
fi
# The switch is not in Vercel's documentation, so a refusal is the owner's one click and setup carries on (decisions S644b).
analytics=", Web Analytics on"
if ! toggled=$(vc api "/web/insights/toggle?projectId=$project_id" -X POST --input - --raw <<<'{"value": true}' 2>&1) \
  || [ "$(jq -r '.value' <<<"$toggled" 2>/dev/null)" != true ]; then
  echo "$toggled" >&2
  mark needs-owner "Vercel did not switch on Web Analytics: in Vercel's dashboard open the project '$name', choose Analytics and click Enable"
  analytics=""
fi

# Workflows confirm a merge is live by asking production's health endpoint; tell them where it is.
domain=$(vc api "/v9/projects/$name/domains" --raw 2>/dev/null | jq -r '.domains[0].name // empty')
if [ -n "$domain" ]; then
  gh variable set PRODUCTION_URL -R "$owner/$name" --body "https://$domain"
  echo "production URL: https://$domain (stored as repo variable PRODUCTION_URL)"
fi

echo
mark done "vercel ok: project '$name' linked to $owner/$name (root apps/web)$analytics"
