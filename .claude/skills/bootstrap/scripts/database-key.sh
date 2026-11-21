#!/usr/bin/env bash
# Creates a Neon API key for this project's database alone, and stores it as the repo secret NEON_API_KEY.
# Usage: database-key.sh [name]   (name defaults to the directory name; run after database.sh)
#        Stores the Neon project id as the repo variable NEON_PROJECT_ID.
#        Safe to re-run: skips when the secret and the variable exist (FORCE=1 replaces them).
set -euo pipefail

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
repo="$owner/$name"
vc() { npx --yes vercel@latest "$@"; }
neon() { npx --yes neonctl@latest "$@"; }

# Read on their own lines so that a login that cannot read the repo's secrets stops here, before
# any key is made. Inside the `if`, that error would read as "not set" and every retry would
# make one more key that could not be stored.
secrets=$(gh secret list -R "$repo" --json name --jq '.[].name') \
  || { echo "cannot read the secrets of $repo: sign in to gh as an admin of the repo and re-run"; exit 1; }
variables=$(gh variable list -R "$repo" --json name --jq '.[].name') \
  || { echo "cannot read the variables of $repo: sign in to gh as an admin of the repo and re-run"; exit 1; }
if [ "${FORCE:-}" != 1 ] && grep -qx NEON_API_KEY <<<"$secrets" && grep -qx NEON_PROJECT_ID <<<"$variables"; then
  echo "database key ok: secret NEON_API_KEY and variable NEON_PROJECT_ID already set (FORCE=1 to replace them)"
  exit 0
fi

# The Neon project id is the database resource's external id in Vercel. The CLI's record and the
# storage API name the field differently, so both are asked; Neon confirms the answer below.
resource=$(vc integration resource inspect "$name" --json 2>/dev/null | jq -c '.resource // {}') || resource='{}'
project=$(jq -r '.externalResourceId // .externalId // empty' <<<"$resource")
if [ -z "$project" ]; then
  store=$(jq -r '.id // empty' <<<"$resource")
  [ -n "$store" ] || { echo "no database called '$name' on Vercel; run database.sh first"; exit 1; }
  project=$(vc api "/v1/storage/stores/$store" --raw 2>/dev/null | tail -1 \
    | jq -r '.store | .externalResourceId // .externalId // empty') || project=''
fi
[ -n "$project" ] || { echo "could not read the Neon project id from Vercel's record of database '$name'"; exit 1; }

# `me` exits 1 when nobody is signed in and is the one command that never starts the sign-in
# itself, on any machine (neonctl 9.5.0); `auth` then opens the browser, prints the URL and waits.
if ! neon me >/dev/null 2>&1; then
  echo "approve the Neon sign-in in the browser (sign in the way the Vercel account does)"
  neon auth
fi
# The organisation is kept because a key limited to a project belongs to it, and revoking one
# needs it.
org=$(neon projects get "$project" --output json 2>/dev/null | jq -r '.org_id // empty') \
  || { echo "the Neon login cannot see project '$project'; sign in as the account Vercel created the database for and re-run"; exit 1; }

# Limited to this one project: the key sits where agents run, and the database will hold
# production data (decisions M15). A run with FORCE=1 leaves the earlier key valid in
# Neon, but its value exists nowhere once the secret is replaced.
# If Neon answers without a key, the CLI revokes what it made and fails, and the script stops here.
created=$(neon api-keys create --name "$name-github-actions" --project-id "$project" --output json)
key=$(jq -r '.key // empty' <<<"$created")
key_id=$(jq -r '.id // empty' <<<"$created")

# From here until the secret is stored, the key is live and held only by this process. Whatever
# stops the script, take the key back, or say exactly which one to revoke: an unrecorded key to
# this database must not be left behind, and a retry would add another.
stored=''
withdraw() {
  [ -z "$stored" ] || return 0
  if [ -n "$key_id" ] && neon api-keys revoke "$key_id" ${org:+--org-id "$org"} >/dev/null 2>&1; then
    echo "revoked the key just made (id $key_id): nothing is left in Neon"
  else
    echo "A KEY IS STILL LIVE IN NEON and stored nowhere: '$name-github-actions'${key_id:+, id $key_id}."
    echo "Revoke it: npx neonctl api-keys revoke ${key_id:-<id from api-keys list>} ${org:+--org-id $org}"
  fi
}
trap withdraw EXIT
[ -n "$key" ] || { echo "Neon returned no key"; exit 1; }

branches=$(NEON_API_KEY="$key" neon branches list --project-id "$project" --output json | jq length) \
  || { echo "the new key cannot list the branches of project '$project'"; exit 1; }

gh variable set NEON_PROJECT_ID -R "$repo" --body "$project"
# ci.yml deletes the database branch of a pull request that is gone with this key (factory/free-tier.md, entry 8).
# Piped to gh, so the key is never printed or written to disk.
printf %s "$key" | gh secret set NEON_API_KEY -R "$repo"
stored=1
echo "database key ok: secret NEON_API_KEY stored (this project only), variable NEON_PROJECT_ID=$project, $branches database branches now"
