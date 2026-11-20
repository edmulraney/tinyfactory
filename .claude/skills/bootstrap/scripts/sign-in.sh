#!/usr/bin/env bash
# Gives a product with accounts somewhere to keep them: switches Neon Auth on for the production
# branch of the database, and sets what the app needs to use it on the Vercel project:
# NEON_AUTH_BASE_URL (the auth address) and NEON_AUTH_COOKIE_SECRET (generated here, never printed).
# People sign in to a product unless its PURPOSE.md says it has no accounts (the purpose skill
# writes that line); for such a product this script does nothing.
# Why Neon Auth: the users live in the database the project already has, so a preview's own
# database branch holds its own users, and there is no second service or account (decisions S287a).
# People sign in by a link sent to their email and never by a password (decisions S342a): it
# switches Neon Auth's Magic Link on and its email and password off, for the production branch
# and for each preview's branch, which copied production's settings on the day it was made. A
# preview's branch made before Neon Auth was on has none, and is passed over (decisions S384).
# Safe to re-run: Neon answers an "enable" for a branch that has auth with what is there, and a
# variable Vercel already lists, or a branch whose two settings are already so, is left alone, so
# a second run changes nothing.
# Usage: sign-in.sh [name]   (name defaults to the directory name; run after database-key.sh)
set -euo pipefail

name="${1:-$(basename "$PWD")}"
vc() { npx --yes vercel@latest "$@"; }
neon() { npx --yes neonctl@latest "$@"; }

if [ ! -f PURPOSE.md ]; then
  echo "sign-in skipped: there is no PURPOSE.md, so nobody has said whether people sign in. Run the purpose skill, then this script again."
  exit 0
fi
if grep -qF -- '- **Have accounts.**' PURPOSE.md; then
  echo "sign-in skipped: PURPOSE.md says the product has no accounts"
  exit 0
fi

# Read before anything is switched on, so a Vercel login that cannot see the project stops the
# script with nothing changed. listed <variable> <environment>: whether Vercel lists it there.
envs() { vc api "/v9/projects/$name/env" --raw 2>/dev/null | tail -1 | jq -c '[.envs[] | {key, target: ([.target] | flatten)}]'; }
listed() { jq -e --arg key "$1" --arg target "$2" 'any(.[]; .key == $key and (.target | index($target)))' <<<"$vars" >/dev/null; }
vars=$(envs) || { echo "cannot read the environment variables of the Vercel project '$name': sign in to Vercel and re-run"; exit 1; }

owner=$(gh api user --jq .login) || { echo "cannot ask GitHub who is signed in: sign in to gh and re-run"; exit 1; }
project=$(gh variable get NEON_PROJECT_ID -R "$owner/$name") \
  || { echo "cannot read the variable NEON_PROJECT_ID of $owner/$name; run database-key.sh first"; exit 1; }
[ -n "$project" ] || { echo "the variable NEON_PROJECT_ID of $owner/$name is empty; run database-key.sh first"; exit 1; }

# As database-key.sh does: `me` is the one command that never starts the sign-in itself.
if ! neon me >/dev/null 2>&1; then
  echo "approve the Neon sign-in in the browser (sign in the way the Vercel account does)"
  neon auth
fi
branches=$(neon branches list --project-id "$project" --output json) \
  || { echo "the Neon login cannot list the branches of project '$project'; sign in as the account Vercel created the database for and re-run"; exit 1; }
branch=$(jq -r '[.[] | select(.default)][0].id // empty' <<<"$branches")
[ -n "$branch" ] || { echo "Neon names no default branch in project '$project', so there is no production branch to switch sign-in on for"; exit 1; }

# The CLI sends POST /projects/{id}/branches/{id}/auth with {"auth_provider":"better_auth"}, and
# for a branch that already has auth (409) reads what is there instead (neonctl 9.6.0).
if ! auth=$(neon neon-auth enable --project-id "$project" --branch "$branch" --output json); then
  cat <<NOTE

Neon would not switch sign-in on for this database. One browser step instead:
   open     https://console.neon.tech/app/projects/$project/branches/$branch
            (or, from Vercel: Storage → $name → Open in Neon → Branches → the default branch)
   find     Auth
   click    Enable Auth
then run this script again: it confirms the click and sets the variables.
NOTE
  exit 1
fi
url=$(jq -r 'if type == "array" then .[0] else . end | .base_url // empty' <<<"$auth")
[ -n "$url" ] || { echo "Neon switched sign-in on but gave no auth address; run this script again"; exit 1; }
echo "Neon Auth is on for the production branch ($branch): $url"

# settings <branch id>: "<Magic Link on> <email and password on>", as Neon holds them. The CLI has
# no command that changes Magic Link, so its `api` command sends each request with the login the
# CLI holds; it prints Neon's JSON and fails when Neon refuses (neonctl 9.6.3).
settings() { neon api "/projects/$project/branches/$1/auth/plugins" | jq -r '"\(.magic_link.enabled) \(.email_and_password.enabled)"'; }
# by_link_only <branch id> <its name in a sentence>: sets the two, and does not take Neon's word.
by_link_only() {
  local now
  now=$(settings "$1") || { echo "Neon would not show the sign-in settings of $2 ($1); run this script again"; exit 1; }
  if [ "$now" = "true false" ]; then
    echo "$2 already signs people in by an emailed link and takes no password"
    return
  fi
  neon api "/projects/$project/branches/$1/auth/plugins/magic-link" -X PATCH -F enabled=true >/dev/null \
    || { echo "Neon refused to switch Magic Link on for $2 ($1); run this script again"; exit 1; }
  neon api "/projects/$project/branches/$1/auth/email_and_password" -X PATCH -F enabled=false >/dev/null \
    || { echo "Neon refused to switch email and password off for $2 ($1), so anyone can still sign up there with a password; run this script again"; exit 1; }
  now=$(settings "$1") || { echo "cannot read the sign-in settings of $2 ($1) back from Neon; run this script again"; exit 1; }
  [ "$now" = "true false" ] \
    || { echo "Neon does not show Magic Link on and email and password off for $2 ($1) after they were set; run this script again"; exit 1; }
  echo "$2 now signs people in by an emailed link and takes no password"
}
# Before the variables, so that a product whose address is set already takes no password.
by_link_only "$branch" "the production branch"

# Read again: once auth is on, Neon's integration may add the address itself, and Vercel refuses
# a variable it already lists.
vars=$(envs) || { echo "cannot read the environment variables of '$name' from Vercel now that sign-in is on; run this script again"; exit 1; }

# add: reads a variable as JSON on stdin and adds it to the Vercel project.
add() { vc api "/v10/projects/$name/env" -X POST --input - --raw >/dev/null 2>&1; }

# The address is set for production only. A preview has auth of its own, on its own database
# branch, and Neon's integration gives it that address when it builds; production's address set
# here for previews would have every pull request's tests sign users up in production (S287b).
if listed NEON_AUTH_BASE_URL production; then
  echo "NEON_AUTH_BASE_URL is already set for production"
else
  jq -n --arg value "$url" '{key: "NEON_AUTH_BASE_URL", value: $value, type: "encrypted", target: ["production"]}' | add \
    || { echo "Vercel refused NEON_AUTH_BASE_URL for production; run this script again"; exit 1; }
  echo "set NEON_AUTH_BASE_URL for production"
fi
if listed NEON_AUTH_BASE_URL preview; then
  echo "NEON_AUTH_BASE_URL is listed for preview: each preview gets the address of its own database branch"
else
  echo "NEON_AUTH_BASE_URL is not listed for preview: Neon's integration gives each preview its own when it builds (factory/manual-steps.md)"
fi

# A secret for each, so the one that previews hold, where unreviewed code runs, signs nothing
# production accepts (S287c). It goes from openssl to Vercel through pipes alone: no variable,
# no argument, no file. "sensitive" means Vercel never shows it again either.
for target in production preview; do
  if listed NEON_AUTH_COOKIE_SECRET "$target"; then
    echo "NEON_AUTH_COOKIE_SECRET is already set for $target"
    continue
  fi
  openssl rand -base64 32 | tr -d '\n' \
    | jq -Rc --arg target "$target" '{key: "NEON_AUTH_COOKIE_SECRET", value: ., type: "sensitive", target: [$target]}' | add \
    || { echo "could not generate NEON_AUTH_COOKIE_SECRET, or Vercel refused it, for $target; run this script again"; exit 1; }
  echo "set NEON_AUTH_COOKIE_SECRET for $target (generated, shown nowhere)"
done

# Vercel's answer to an add is not trusted: the list is read again.
vars=$(envs) || { echo "cannot read the environment variables of '$name' back from Vercel; run this script again"; exit 1; }
for wanted in "NEON_AUTH_BASE_URL production" "NEON_AUTH_COOKIE_SECRET production" "NEON_AUTH_COOKIE_SECRET preview"; do
  # shellcheck disable=SC2086
  listed $wanted || { echo "Vercel does not list $wanted after it was set; run this script again"; exit 1; }
done

# Last, so that a preview's branch Neon refuses leaves production complete. Vercel's integration
# names a preview's branch `preview/<git branch>`. On descriptor 3, so that npx cannot read the
# list as its own input.
while IFS=$'\t' read -r id preview <&3; do
  [ -n "$id" ] || continue
  # For a branch with no auth, `status` prints this sentence and no JSON, and succeeds; it fails
  # when Neon answers anything but "there is none" (neonctl 9.6.3).
  auth=$(neon neon-auth status --project-id "$project" --branch "$id" --output json) \
    || { echo "Neon would not say whether the preview's branch $preview ($id) has Neon Auth; run this script again"; exit 1; }
  if grep -qF 'Neon Auth is not configured for this branch' <<<"$auth"; then
    echo "passed over the preview's branch $preview ($id): it has no Neon Auth, so nobody can sign in there, by a password or otherwise"
    continue
  fi
  by_link_only "$id" "the preview's branch $preview"
done 3< <(jq -r '.[] | select(.name // "" | startswith("preview/")) | [.id, .name] | @tsv' <<<"$branches")
echo "sign-in ok: Neon Auth on, by emailed link and no password, NEON_AUTH_BASE_URL and NEON_AUTH_COOKIE_SECRET set on Vercel project '$name'"
