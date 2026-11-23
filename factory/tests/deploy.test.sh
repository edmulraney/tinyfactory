#!/usr/bin/env bash
# Tests for bootstrap's deploy.sh: main is deployed to production and waited for, unless production already runs it.
. "$(dirname "$0")/helpers.sh"

deploy="$root/.claude/skills/bootstrap/scripts/deploy.sh"
main=abcdef0123456789abcdef0123456789abcdef01
old=0000000000000000000000000000000000000000

# a_project <commit>: production reports the commit until Vercel is asked to deploy, then main's; it was built at
# $T/built and its variables last changed at $T/changed; $T/fail holds a word of the call to fail. The clock jumps 100 seconds each time it is read, so a ten-minute wait ends at once.
a_project() {
  mkdir -p factory/scripts
  cp "$scripts/wait-for-deploy.sh" factory/scripts/
  echo "{\"commit\":\"$1\"}" > "$T/health"
  echo none > "$T/fail"
  echo 2000 > "$T/built"
  echo 1000 > "$T/changed"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"gh $*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "api repos/owner/shop/commits/main "*) json "{\"sha\":\"'"$main"'\"}" "$@" ;;
      "variable get PRODUCTION_URL -R owner/shop") echo https://shop.example ;;
      "api repos/{owner}/{repo}/commits/'"$main"'/statuses "*) json "[]" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub curl 'cat "$T/health"'
  stub npx '
    if grep -qF -- "$(cat "$T/fail")" <<<"npx $*"; then echo "Error: forbidden" >&2; exit 1; fi
    case "$*" in
      "--yes vercel@latest api /v13/deployments -X POST --input - --raw")
        cat > "$T/deployment"
        echo "{\"commit\":\"$(cat "$T/answers-after" 2>/dev/null || jq -r .gitSource.sha "$T/deployment")\"}" > "$T/health"
        echo "Vercel CLI 50.0.0"
        echo "{\"inspectorUrl\":\"https://vercel.com/owner/shop/dpl1\"}" ;;
      "--yes vercel@latest api /v6/deployments?projectId=shop&target=production&state=READY&limit=1 --raw")
        echo "Vercel CLI 50.0.0"
        echo "{\"deployments\":[{\"created\":$(cat "$T/built")}]}" ;;
      "--yes vercel@latest api /v9/projects/shop/env --raw")
        echo "Vercel CLI 50.0.0"
        echo "{\"envs\":[{\"key\":\"DATABASE_URL\",\"target\":[\"production\",\"preview\"],\"updatedAt\":$(cat "$T/changed")},{\"key\":\"LOCAL\",\"target\":\"development\",\"updatedAt\":9999}]}" ;;
      *) echo "unexpected call: npx $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
  stub date 'now=$(cat "$T/clock" 2>/dev/null || echo 1000); echo $((now + 100)) > "$T/clock"; echo "$now"'
  export SETUP_PRODUCTION="$T/production" SETUP_NEEDS_OWNER="$T/needs-owner"
  : > "$T/needs-owner"
}

scenario "asks Vercel for a production deployment of main's commit, and ends once production's health endpoint reports it"
a_project "$old"
run "$deploy" shop
expect_status 0
expect_call "npx --yes vercel@latest api /v13/deployments -X POST --input - --raw"
[ "$(jq -c '{target, project, gitSource}' "$T/deployment")" = '{"target":"production","project":"shop","gitSource":{"type":"github","org":"owner","repo":"shop","ref":"main","sha":"'"$main"'"}}' ] \
  || fail "expected a production deployment of main's commit from owner/shop, asked for: $(cat "$T/deployment")"
expect_output "deploying main ($main) to production: https://vercel.com/owner/shop/dpl1"
expect_call "curl -fsS --max-time 10 https://shop.example/api/health"
expect_output "deploy ok: https://shop.example runs main ($main)"
[ "$(cat "$T/production")" = https://shop.example ] || fail "expected the closing summary to be given https://shop.example, got: $(cat "$T/production")"

scenario "deploys nothing when production already reports main's commit, built after its variables last changed"
a_project "$main"
run "$deploy" shop
expect_status 0
expect_no_call "/v13/deployments"
expect_output "production already reports $main, built after its variables last changed, skipping the deployment"
expect_output "deploy ok: https://shop.example runs main ($main)"
[ "$(cat "$T/production")" = https://shop.example ] || fail "expected the closing summary to be given https://shop.example"

scenario "deploys again when production reports main's commit but was built before a variable was set"
a_project "$main"
echo 3000 > "$T/changed"
run "$deploy" shop
expect_status 0
expect_call "npx --yes vercel@latest api /v13/deployments -X POST --input - --raw"
expect_no_output "skipping the deployment"
expect_output "deploy ok: https://shop.example runs main ($main)"

scenario "stops, deploying nothing, when Vercel cannot say when production was built"
a_project "$main"
echo "/v6/deployments" > "$T/fail"
run "$deploy" shop
expect_status 1
expect_output "deploy.sh: could not read when production of 'shop' was built"
expect_no_call "/v13/deployments"

scenario "stops, deploying nothing, when Vercel cannot list the project's variables"
a_project "$main"
echo "/env" > "$T/fail"
run "$deploy" shop
expect_status 1
expect_output "deploy.sh: could not read the environment variables of 'shop'"
expect_no_call "/v13/deployments"

scenario "deploys while an earlier step waits for the owner"
a_project "$old"
echo "database: set preview retention to one day" > "$T/needs-owner"
run "$deploy" shop
expect_status 0
expect_call "npx --yes vercel@latest api /v13/deployments -X POST --input - --raw"
expect_output "deploy ok: https://shop.example runs main ($main)"

scenario "leaves setup to list the owner's steps when production does not report main's commit while one waits"
a_project "$old"
echo "$old" > "$T/answers-after"
echo "database: agree to Neon's terms" > "$T/needs-owner"
run "$deploy" shop
expect_status 0
expect_output "production did not report main's commit: the deployment runs again when you rerun setup after the steps above"
expect_no_output "deploy ok"
[ ! -s "$T/production" ] || fail "expected no production address for the closing summary"

scenario "stops with Vercel's answer when Vercel refuses the deployment, and waits for nothing"
a_project "$old"
echo "/v13/deployments" > "$T/fail"
run "$deploy" shop
expect_status 1
expect_output "Error: forbidden"
expect_output "deploy.sh: Vercel refused to deploy main ($main) of 'shop' to production."
expect_no_call "sleep"
[ ! -s "$T/production" ] || fail "expected no production address for the closing summary"

scenario "stops when production never reports main's commit"
a_project "$old"
echo "$old" > "$T/answers-after"
run "$deploy" shop
expect_status 1
expect_output "timed out: https://shop.example/api/health reports '$old', expected $main"
expect_output "deploy.sh: production did not report main's commit"
expect_no_output "deploy ok"
[ ! -s "$T/production" ] || fail "expected no production address for the closing summary"

scenario "stops, deploying nothing, when GitHub cannot say which commit is on main"
a_project "$old"
echo "commits/main" > "$T/fail"
run "$deploy" shop
expect_status 1
expect_output "deploy.sh: could not read the commit on main of owner/shop."
expect_no_call "npx"

scenario "stops, deploying nothing, when the repo has no production address"
a_project "$old"
echo "PRODUCTION_URL" > "$T/fail"
run "$deploy" shop
expect_status 1
expect_output "deploy.sh: owner/shop has no repo variable PRODUCTION_URL"
expect_no_call "npx"
