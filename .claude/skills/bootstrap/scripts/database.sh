#!/usr/bin/env bash
# Creates a free Neon Postgres database through Vercel's marketplace and connects it to the Vercel project.
# Usage: database.sh [name]   (name defaults to the directory name)
#        Safe to re-run. Needs only the Vercel login. Before it creates the database it prints the links to
#        Neon's marketplace terms and accepts them for the Vercel team only once a person at the terminal
#        agrees; with no terminal it stops there (decisions S601).
set -euo pipefail

name="${1:-$(basename "$PWD")}"
vc() { npx --yes vercel@latest "$@"; }

# `integration add` connects the resource to the project this directory is linked to.
if [ ! -f .vercel/project.json ]; then
  had_env_local=$([ -f .env.local ] && echo yes || echo no)
  vc link --yes --project "$name" >/dev/null 2>&1
  # link drops a .env.local holding a short-lived Vercel token; remove it unless it was already there.
  [ "$had_env_local" = yes ] || rm -f .env.local
fi

created=no
if vc integration resource inspect "$name" --json >/dev/null 2>&1; then
  echo "database '$name' already exists, skipping create"
else
  # Vercel holds the two addresses for Neon, and its own CLI shows the same three before it asks.
  terms=$(vc api /v2/integrations/integration/neon --raw 2>/dev/null | tail -1 \
    | jq -er '"Neon terms of service: \(.eulaDocUri // empty)", "Neon privacy policy: \(.privacyDocUri // empty)"') \
    || { echo "could not read the links to Neon's terms from Vercel, so no database was created"; exit 1; }
  echo "creating the database accepts these terms for your Vercel team:"
  echo "Vercel marketplace addendum: https://vercel.com/legal/integration-marketplace-end-users-addendum"
  echo "$terms"
  if [ ! -t 0 ]; then
    echo "database not created: nobody is at a terminal to agree to these terms. Read them, then run this in a terminal:"
    # The script acts on the directory it runs in, and the person starts in another.
    printf '   cd %q && %q %q\n' "$PWD" "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$name"
    exit 1
  fi
  read -r -p "Do you agree to them? [y/N] " answer
  case "$answer" in
    y|Y|yes|Yes) ;;
    *) echo "database not created: the terms were not agreed to"; exit 1 ;;
  esac
  vc integration accept-terms neon --yes >/dev/null 2>&1 \
    || { echo "Vercel did not accept Neon's terms, so no database was created"; exit 1; }
  created=yes
  # iad1 is where Vercel runs functions by default, so the database sits next to the code that queries it.
  # auth=false: sign-in.sh switches Neon's auth on, only for a product with accounts, and for a
  # database that already exists too (decisions S287a).
  vc integration add neon --name "$name" --billing-plan free_v3 \
    --meta region=iad1 --meta auth=false --no-env-pull --json </dev/null >/dev/null 2>&1
  echo "created database '$name' (Neon free plan, region iad1)"
fi

vc api "/v9/projects/$name/env" --raw 2>/dev/null \
  | jq -e '[.envs[].key] | index("DATABASE_URL")' >/dev/null \
  || { echo "DATABASE_URL is not set on the Vercel project"; exit 1; }
echo "database ok: DATABASE_URL set on Vercel project '$name'"

resource=$(vc integration resource inspect "$name" --json 2>/dev/null | jq -c '.resource // {}')
store=$(jq -r '.id // empty' <<<"$resource")

# A database branch per preview, so a pull request's migrations never run against production data
# before review, its tests never write into real records, and open pull requests never share a
# schema. ARCHITECTURE.md (Environments) has the full reasoning.
# This is the dashboard's "Require Active Resource Before Deploy" switch plus "Create Database
# Branch For Deployment → Preview". The field is in neither Vercel's CLI nor its public API
# spec; it was found by comparing the connection record before and after ticking the boxes.
# `required` makes a build wait until its database branch exists.
branching='{"required":true,"actions":[{"slug":"Neon","environments":["preview"]}]}'
connected() { vc api "/v1/storage/stores/$store" --raw 2>/dev/null | tail -1 \
  | jq -c --arg name "$name" '.store.projectsMetadata[] | select(.name == $name)'; }
connection=$(connected)
if [ "$(jq -cS '.deployments // {}' <<<"$connection")" = "$(jq -cS . <<<"$branching")" ]; then
  echo "previews already get their own database branch"
else
  jq -n --argjson deployments "$branching" '{deployments: $deployments}' \
    | vc api "/v1/storage/stores/$store/connections/$(jq -r .id <<<"$connection")" -X PATCH --input - --raw >/dev/null 2>&1
  [ "$(connected | jq -cS '.deployments // {}')" = "$(jq -cS . <<<"$branching")" ] \
    || { echo "could not switch on a database branch per preview"; exit 1; }
  echo "previews now get their own database branch"
fi

# Previews kept for one day. Why: a preview's database branch is deleted only when Vercel deletes
# the last deployment of its git branch. Kept as long as Vercel's default, a month's pull requests
# outrun the branches Neon's free plan allows, and the next gets no database and fails to build.
# The numbers are in factory/free-tier/entry-1.md. Vercel's project API rejects this setting
# (`deploymentExpiration`), so it is the one step left for the human; the script reads it back and
# confirms it.
team=$(jq -r '.dashboard // empty' <<<"$resource" | sed -E 's|https://vercel.com/([^/]+)/.*|\1|')
settings="https://vercel.com/${team:-<your-team>}/$name/settings/build-and-deployment#deployment-retention-policy"
keep=$(vc api "/v9/projects/$name" --raw 2>/dev/null | tail -1 \
  | jq -r '.deploymentExpiration | [.expirationDays, .expirationDaysCanceled, .expirationDaysErrored] | map(. // 30) | max')

if [ "${keep:-30}" -le 1 ]; then
  echo "previews are kept for one day"
else
  cat <<NOTE

one browser step is left, because Vercel's API rejects this setting (now: up to ${keep:-30} days):
   open     $settings
   find     Deployment Retention Policy
   set      Canceled Deployments → 1 day
            Errored Deployments → 1 day          (a failed preview holds a database branch too)
            Pre-Production Deployments → 1 day
            Production Deployments → leave at 30 days, so production can be rolled back
   click    Save
it keeps the project inside Neon's free plan: see factory/free-tier/entry-1.md.
NOTE
  if [ "$created" = yes ]; then (open "$settings" || xdg-open "$settings") >/dev/null 2>&1 || true; fi
fi
