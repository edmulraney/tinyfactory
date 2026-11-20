#!/usr/bin/env bash
# Tests for bootstrap's sign-in.sh: Neon Auth on, by emailed link alone, its variables in Vercel.
. "$(dirname "$0")/helpers.sh"

sign_in="$root/.claude/skills/bootstrap/scripts/sign-in.sh"
secret="c2VjcmV0LW9mLXRoaXJ0eS10d28tY2hhcmFjdGVycw=="

# a_product: has accounts; Vercel lists the variables in $T/vercel as `KEY target` lines; $T/fail holds a word of the call to fail.
# Neon holds each branch's two settings as `<Magic Link on> <email and password on>` in $T/settings-<branch id>, and a
# branch with no such file has Neon's own: no link, a password. $T/branches, when there, is the list of branches Neon
# answers, and $T/no-auth holds the id of each branch that has no Neon Auth, one a line.
a_product() {
  echo "# Purpose" > PURPOSE.md
  echo "DATABASE_URL production" > "$T/vercel"
  echo "DATABASE_URL preview" >> "$T/vercel"
  echo none > "$T/fail"
  : > "$T/posted"
  : > "$T/no-auth"
  touch "$T/signed-in"
  stub openssl '
    if grep -qF -- "$(cat "$T/fail")" <<<"openssl $*"; then exit 1; fi
    [ "$*" = "rand -base64 32" ] || { echo "unexpected call: openssl $*" >&2; exit 1; }
    echo "'"$secret"'"'
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"gh $*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "variable get NEON_PROJECT_ID -R owner/myapp") echo "quiet-wood-1" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub npx '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "could not connect" >&2; exit 1; fi
    # Asked of every call about the sign-in of a branch, before the call is answered. A case of its own, because
    # the bash a Mac ships has no `;;&` to carry on to the next pattern.
    case "$*" in "--yes neonctl@latest api /projects/quiet-wood-1/branches/"*"/auth/"*)
      id=${4#/projects/quiet-wood-1/branches/}; id=${id%%/*}
      if grep -qxF -- "$id" "$T/no-auth"; then echo "ERROR: Neon Auth is not enabled for this branch" >&2; exit 1; fi ;;
    esac
    case "$*" in
      "--yes vercel@latest api /v9/projects/myapp/env --raw")
        if [ -f "$T/second-read-fails" ] && grep -q "neon-auth enable" "$T/calls"; then echo "could not connect" >&2; exit 1; fi
        jq -Rc "split(\" \") | {key: .[0], target: [.[1]]}" "$T/vercel" | jq -sc "{envs: .}" ;;
      "--yes vercel@latest api /v10/projects/myapp/env -X POST --input - --raw")
        body=$(cat); printf "%s\n" "$body" >> "$T/posted"
        if grep -qxF -- "$(jq -r "\"\(.key) \(.target[0])\"" <<<"$body")" "$T/vercel"; then echo "already exists" >&2; exit 1; fi
        [ -f "$T/vercel-forgets" ] || jq -r "\"\(.key) \(.target[0])\"" <<<"$body" >> "$T/vercel"
        echo "$body" ;;
      "--yes neonctl@latest neon-auth status --project-id quiet-wood-1 --branch "*" --output json")
        if grep -qxF -- "$8" "$T/no-auth"; then printf "\nNeon Auth is not configured for this branch\n\n"; exit 0; fi
        echo "{\"auth_provider\":\"better_auth\",\"branch_id\":\"$8\",\"base_url\":\"https://ep-$8.neonauth.aws.neon.tech/neondb/auth\"}" ;;
      "--yes neonctl@latest api /projects/quiet-wood-1/branches/"*"/auth/plugins")
        if [ -f "$T/read-back-fails" ] && grep -q "PATCH" "$T/calls"; then echo "could not connect" >&2; exit 1; fi
        id=${4#/projects/quiet-wood-1/branches/}; id=${id%/auth/plugins}
        read -r link password < <(cat "$T/settings-$id" 2>/dev/null || echo "false true")
        echo "{\"magic_link\":{\"enabled\":$link,\"expires_in\":5},\"email_and_password\":{\"enabled\":$password},\"allow_localhost\":true}" ;;
      "--yes neonctl@latest api /projects/quiet-wood-1/branches/"*"/auth/plugins/magic-link -X PATCH -F enabled=true")
        id=${4#/projects/quiet-wood-1/branches/}; id=${id%/auth/plugins/magic-link}
        read -r link password < <(cat "$T/settings-$id" 2>/dev/null || echo "false true")
        [ -f "$T/neon-keeps-settings" ] || echo "true $password" > "$T/settings-$id"
        echo "{\"enabled\":true,\"expires_in\":5,\"disable_sign_up\":false}" ;;
      "--yes neonctl@latest api /projects/quiet-wood-1/branches/"*"/auth/email_and_password -X PATCH -F enabled=false")
        id=${4#/projects/quiet-wood-1/branches/}; id=${id%/auth/email_and_password}
        read -r link password < <(cat "$T/settings-$id" 2>/dev/null || echo "false true")
        [ -f "$T/neon-keeps-settings" ] || echo "$link false" > "$T/settings-$id"
        echo "{\"enabled\":false,\"email_verification_method\":\"otp\"}" ;;
      "--yes neonctl@latest me") [ -f "$T/signed-in" ] ;;
      "--yes neonctl@latest auth") touch "$T/signed-in" ;;
      "--yes neonctl@latest branches list --project-id quiet-wood-1 --output json")
        [ -f "$T/branches" ] && { cat "$T/branches"; exit 0; }
        [ -f "$T/no-default" ] && { echo "[{\"id\":\"br-preview-9\",\"name\":\"preview/feat/12-export\",\"default\":false}]"; exit 0; }
        echo "[{\"id\":\"br-preview-9\",\"name\":\"preview/feat/12-export\",\"default\":false},{\"id\":\"br-main-1\",\"name\":\"main\",\"default\":true},{\"id\":\"br-dev-3\",\"name\":\"dev\",\"default\":false}]" ;;
      "--yes neonctl@latest neon-auth enable --project-id quiet-wood-1 --branch br-main-1 --output json")
        [ -f "$T/integration-adds" ] && echo "NEON_AUTH_BASE_URL production" >> "$T/vercel"
        echo "{\"auth_provider\":\"better_auth\",\"base_url\":\"https://ep-main.neonauth.aws.neon.tech/neondb/auth\"}" ;;
      *) echo "unexpected call: npx $*" >&2; exit 1 ;;
    esac'
}
posted() { jq -e "$1" "$T/posted" >/dev/null 2>&1 || fail "expected Vercel to be sent a variable matching: $1"; }

scenario "does nothing for a product whose purpose says it has no accounts"
a_product
printf '## What it will not do\n\n- **Have accounts.** Nobody signs in.\n' >> PURPOSE.md
run "$sign_in" myapp
expect_status 0
expect_output "sign-in skipped: PURPOSE.md says the product has no accounts"
[ ! -s "$T/calls" ] || fail "expected no outside call at all"

scenario "does nothing, and says why, while there is no PURPOSE.md to say whether people sign in"
a_product
rm PURPOSE.md
run "$sign_in" myapp
expect_status 0
expect_output "sign-in skipped: there is no PURPOSE.md"
[ ! -s "$T/calls" ] || fail "expected no outside call at all"

scenario "switches Neon Auth on for the production branch and sets the address and a secret in Vercel"
a_product
run "$sign_in" myapp
expect_status 0
expect_call "neon-auth enable --project-id quiet-wood-1 --branch br-main-1"
posted 'select(.key == "NEON_AUTH_BASE_URL" and .value == "https://ep-main.neonauth.aws.neon.tech/neondb/auth" and .target == ["production"])'
posted 'select(.key == "NEON_AUTH_COOKIE_SECRET" and .value == "'"$secret"'" and .type == "sensitive" and .target == ["production"])'
posted 'select(.key == "NEON_AUTH_COOKIE_SECRET" and .type == "sensitive" and .target == ["preview"])'
expect_output "sign-in ok: Neon Auth on"
expect_no_call "neonctl@latest auth"

scenario "never prints the secret, nor passes it as an argument"
a_product
run "$sign_in" myapp
expect_status 0
expect_no_output "$secret"
expect_no_call "$secret"

scenario "leaves a preview's auth address to Neon's integration, and never gives previews production's"
a_product
run "$sign_in" myapp
expect_status 0
[ "$(jq -c 'select(.key == "NEON_AUTH_BASE_URL") | .target' "$T/posted")" = '["production"]' ] \
  || fail "expected NEON_AUTH_BASE_URL to be set for production alone"
expect_output "NEON_AUTH_BASE_URL is not listed for preview: Neon's integration gives each preview its own"

scenario "changes nothing on a second run"
a_product
run "$sign_in" myapp
: > "$T/posted"
: > "$T/calls"
run "$sign_in" myapp
expect_status 0
[ ! -s "$T/posted" ] || fail "expected nothing to be sent to Vercel on the second run"
expect_no_call "PATCH"
expect_output "the production branch already signs people in by an emailed link and takes no password"
expect_output "the preview's branch preview/feat/12-export already signs people in by an emailed link and takes no password"
expect_output "NEON_AUTH_COOKIE_SECRET is already set for production"
expect_output "sign-in ok"

scenario "leaves alone an address Neon's integration already set, and sets only what is missing"
a_product
printf 'NEON_AUTH_BASE_URL production\nNEON_AUTH_BASE_URL preview\nNEON_AUTH_COOKIE_SECRET production\n' >> "$T/vercel"
run "$sign_in" myapp
expect_status 0
[ "$(jq -r '"\(.key) \(.target[0])"' "$T/posted")" = "NEON_AUTH_COOKIE_SECRET preview" ] \
  || fail "expected only the preview's secret to be sent to Vercel"
expect_output "NEON_AUTH_BASE_URL is listed for preview"

scenario "leaves alone an address Neon's integration adds as auth is switched on"
a_product
touch "$T/integration-adds"
run "$sign_in" myapp
expect_status 0
[ -z "$(jq -r 'select(.key == "NEON_AUTH_BASE_URL") | .key' "$T/posted")" ] \
  || fail "expected the address the integration added not to be sent to Vercel again"
expect_output "NEON_AUTH_BASE_URL is already set for production"
expect_output "sign-in ok"

scenario "stops when Vercel's variables cannot be read once sign-in is on"
a_product
touch "$T/second-read-fails"
run "$sign_in" myapp
expect_failure
expect_output "from Vercel now that sign-in is on"
[ ! -s "$T/posted" ] || fail "expected nothing to be sent to Vercel"
expect_no_output "sign-in ok"

scenario "starts the Neon sign-in when nobody is signed in"
a_product
rm "$T/signed-in"
run "$sign_in" myapp
expect_status 0
expect_output "approve the Neon sign-in in the browser"
expect_call "npx --yes neonctl@latest auth"

scenario "stops before switching anything on when Vercel's variables cannot be read"
a_product
echo "/v9/projects/myapp/env" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "cannot read the environment variables of the Vercel project 'myapp'"
expect_no_call "neon-auth enable"
expect_no_output "sign-in ok"

scenario "stops before switching anything on when the Neon project's id cannot be read"
a_product
echo "variable get" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "cannot read the variable NEON_PROJECT_ID of owner/myapp; run database-key.sh first"
expect_no_call "neonctl"

scenario "stops when GitHub cannot say who is signed in"
a_product
echo "api user" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "cannot ask GitHub who is signed in"
expect_no_call "neonctl"

scenario "stops when the Neon sign-in fails"
a_product
rm "$T/signed-in"
echo "neonctl@latest auth" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_no_call "neon-auth enable"
expect_no_output "sign-in ok"

scenario "stops when Neon's branches cannot be listed"
a_product
echo "branches list" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "cannot list the branches of project 'quiet-wood-1'"
expect_no_call "neon-auth enable"

scenario "stops when Neon names no production branch"
a_product
touch "$T/no-default"
run "$sign_in" myapp
expect_failure
expect_output "Neon names no default branch"
expect_no_call "neon-auth enable"

scenario "prints the clicks, and sets no variable, when Neon refuses to switch sign-in on"
a_product
echo "neon-auth enable" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon would not switch sign-in on for this database"
expect_output "open     https://console.neon.tech/app/projects/quiet-wood-1/branches/br-main-1"
expect_output "click    Enable Auth"
[ ! -s "$T/posted" ] || fail "expected nothing to be sent to Vercel"
expect_no_output "sign-in ok"

scenario "stops when Vercel refuses a variable"
a_product
echo "-X POST" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Vercel refused NEON_AUTH_BASE_URL for production"
expect_no_output "sign-in ok"

scenario "stops, with nothing sent to Vercel as a secret, when no secret can be generated"
a_product
echo "openssl rand" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "could not generate NEON_AUTH_COOKIE_SECRET"
expect_no_output "set NEON_AUTH_COOKIE_SECRET"
expect_no_output "sign-in ok"

scenario "does not take Vercel's word that a variable was added"
a_product
touch "$T/vercel-forgets"
run "$sign_in" myapp
expect_failure
expect_output "Vercel does not list NEON_AUTH_BASE_URL production after it was set"
expect_no_output "sign-in ok"

scenario "switches the emailed link on and the password off for the production branch, and reads both back"
a_product
run "$sign_in" myapp
expect_status 0
expect_call "api /projects/quiet-wood-1/branches/br-main-1/auth/plugins/magic-link -X PATCH -F enabled=true"
expect_call "api /projects/quiet-wood-1/branches/br-main-1/auth/email_and_password -X PATCH -F enabled=false"
[ "$(cat "$T/settings-br-main-1")" = "true false" ] || fail "expected Neon to hold the link on and the password off for production"
expect_output "the production branch now signs people in by an emailed link and takes no password"
expect_output "sign-in ok: Neon Auth on, by emailed link and no password"

scenario "sets both on each preview's branch too, and on no other branch"
a_product
run "$sign_in" myapp
expect_status 0
expect_call "api /projects/quiet-wood-1/branches/br-preview-9/auth/plugins/magic-link -X PATCH -F enabled=true"
expect_call "api /projects/quiet-wood-1/branches/br-preview-9/auth/email_and_password -X PATCH -F enabled=false"
expect_output "the preview's branch preview/feat/12-export now signs people in by an emailed link and takes no password"
expect_no_call "br-dev-3"

scenario "changes only the branch whose settings are not yet so"
a_product
echo "true false" > "$T/settings-br-main-1"
run "$sign_in" myapp
expect_status 0
expect_no_call "br-main-1/auth/plugins/magic-link"
expect_no_call "br-main-1/auth/email_and_password"
expect_call "br-preview-9/auth/plugins/magic-link -X PATCH"

scenario "switches the password off on a branch that already has the link on"
a_product
echo "true true" > "$T/settings-br-main-1"
run "$sign_in" myapp
expect_status 0
expect_call "br-main-1/auth/email_and_password -X PATCH -F enabled=false"
[ "$(cat "$T/settings-br-main-1")" = "true false" ] || fail "expected the password to be off for production"

scenario "stops, with nothing changed, when Neon will not show the settings"
a_product
echo "auth/plugins" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon would not show the sign-in settings of the production branch (br-main-1)"
expect_no_call "PATCH"
[ ! -s "$T/posted" ] || fail "expected nothing to be sent to Vercel"
expect_no_output "sign-in ok"

scenario "stops when Neon refuses to switch the link on"
a_product
echo "magic-link -X PATCH" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon refused to switch Magic Link on for the production branch (br-main-1)"
expect_no_output "sign-in ok"

scenario "stops, and says a password still works, when Neon refuses to switch the password off"
a_product
echo "email_and_password" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon refused to switch email and password off for the production branch (br-main-1), so anyone can still sign up there with a password"
expect_no_output "sign-in ok"

scenario "does not take Neon's word that the settings were changed"
a_product
touch "$T/neon-keeps-settings"
run "$sign_in" myapp
expect_failure
expect_output "Neon does not show Magic Link on and email and password off for the production branch (br-main-1) after they were set"
expect_no_output "sign-in ok"

scenario "stops when the settings cannot be read back from Neon"
a_product
touch "$T/read-back-fails"
run "$sign_in" myapp
expect_failure
expect_output "cannot read the sign-in settings of the production branch (br-main-1) back from Neon"
expect_no_output "sign-in ok"

scenario "has finished production when Neon refuses a preview's branch"
a_product
echo "br-preview-9/auth/plugins/magic-link" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon refused to switch Magic Link on for the preview's branch preview/feat/12-export (br-preview-9)"
[ "$(cat "$T/settings-br-main-1")" = "true false" ] || fail "expected production to sign people in by link"
grep -qxF "NEON_AUTH_COOKIE_SECRET production" "$T/vercel" || fail "expected the variables to be set"
expect_no_output "sign-in ok"

# three_previews: Neon lists production's branch and three previews' branches, the middle one made before auth was on.
three_previews() {
  jq -nc '[{id: "br-main-1", name: "main", default: true}, {id: "br-preview-7", name: "preview/feat/7-first"},
    {id: "br-preview-8", name: "preview/feat/8-made-before-auth"}, {id: "br-preview-9", name: "preview/feat/9-last"}]
    | map({default: false} + .)' > "$T/branches"
  echo "br-preview-8" > "$T/no-auth"
}

scenario "passes over a preview's branch that has no Neon Auth, says which and why, and sets the ones around it"
a_product
three_previews
run "$sign_in" myapp
expect_status 0
expect_output "passed over the preview's branch preview/feat/8-made-before-auth (br-preview-8): it has no Neon Auth, so nobody can sign in there"
[ "$(cat "$T/settings-br-preview-7")" = "true false" ] || fail "expected the preview's branch before it to sign people in by link"
[ "$(cat "$T/settings-br-preview-9")" = "true false" ] || fail "expected the preview's branch after it to sign people in by link"
expect_no_call "br-preview-8/auth"
expect_output "sign-in ok"

scenario "stops when Neon will not say whether a preview's branch has Neon Auth"
a_product
three_previews
echo "neon-auth status --project-id quiet-wood-1 --branch br-preview-8" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon would not say whether the preview's branch preview/feat/8-made-before-auth (br-preview-8) has Neon Auth"
expect_no_call "br-preview-8/auth"
expect_no_call "br-preview-9/auth"
expect_no_output "sign-in ok"

scenario "still stops at a preview's branch that has Neon Auth when Neon will not show its settings"
a_product
three_previews
echo "br-preview-9/auth/plugins" > "$T/fail"
run "$sign_in" myapp
expect_failure
expect_output "Neon would not show the sign-in settings of the preview's branch preview/feat/9-last (br-preview-9)"
expect_no_output "sign-in ok"
