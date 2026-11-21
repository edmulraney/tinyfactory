#!/usr/bin/env bash
# Lets CI reach Vercel's previews, which sit behind a Vercel login, by storing the project's bypass secret.
# Usage: preview-access.sh [name]   (name defaults to the directory name)
#        Stores the repo secret VERCEL_AUTOMATION_BYPASS_SECRET.
#        Safe to re-run: reuses the bypass secret the Vercel project already has.
set -euo pipefail

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
vc() { npx --yes vercel@latest "$@"; }
pick='(.protectionBypass // {}) | to_entries[] | select(.value.scope == "automation-bypass") | .key'

secret=$(vc api "/v9/projects/$name" --raw 2>/dev/null | jq -r "$pick" | head -1)
if [ -z "$secret" ]; then
  secret=$(echo '{"generate": {}}' | vc api "/v1/projects/$name/protection-bypass" -X PATCH --input - --raw 2>/dev/null \
    | jq -r "$pick" | head -1)
  echo "generated a preview bypass secret"
else
  echo "preview bypass secret already exists, reusing it"
fi
[ -n "$secret" ] || { echo "could not create the bypass secret"; exit 1; }

# Piped to gh, so the secret is never printed.
printf %s "$secret" | gh secret set VERCEL_AUTOMATION_BYPASS_SECRET -R "$owner/$name"

url=$(vc api "/v6/deployments?projectId=$name&target=preview&state=READY&limit=1" --raw 2>/dev/null | jq -r '.deployments[0].url // empty')
if [ -n "$url" ]; then
  with=$(curl -s -o /dev/null -w '%{http_code}' -H "x-vercel-protection-bypass: $secret" "https://$url")
  without=$(curl -s -o /dev/null -w '%{http_code}' "https://$url")
  echo "preview check: with secret HTTP $with, without HTTP $without"
  [ "$with" = 200 ] || { echo "bypass secret did not open the preview"; exit 1; }
fi
echo "preview access ok: secret VERCEL_AUTOMATION_BYPASS_SECRET stored"
