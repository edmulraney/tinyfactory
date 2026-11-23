#!/usr/bin/env bash
# Tests for bootstrap's deploy.sh: setup ends with production running the commit on main.
. "$(dirname "$0")/helpers.sh"

deploy="$root/.claude/skills/bootstrap/scripts/deploy.sh"

# production_holds: main is at abc1234…, and production reports the commit in $T/live (empty: no answer) until a deployment is
# ready, then abc1234…. $T/states holds the deployment's readyState answers, one a line; the body sent to Vercel is kept in $T/body.
production_holds() {
  echo old0000000000000000000000000000000000000 > "$T/live"
  printf 'BUILDING\nREADY\n' > "$T/states"
  stub gh '
    case "$*" in
      "api user --jq .login") echo owner ;;
      "variable get PRODUCTION_URL -R owner/shop") echo https://shop.example ;;
      "api repos/owner/shop/commits/main --jq .sha") echo abc1234000000000000000000000000000000000 ;;
      "api repos/owner/shop --jq .id") echo 42 ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub curl '
    live=$(cat "$T/live"); [ -n "$live" ] || exit 22
    echo "{\"status\":\"ok\",\"commit\":\"$live\"}"'
  stub sleep ':'
  stub npx '
    shift 2
    case "$*" in
      "api /v13/deployments -X POST --input - --raw") cat > "$T/body"; echo "{\"id\":\"dpl_1\"}" ;;
      "api /v13/deployments/dpl_1 --raw")
        state=$(head -n 1 "$T/states"); sed -i.bak 1d "$T/states"
        [ "$state" = READY ] && echo abc1234000000000000000000000000000000000 > "$T/live"
        echo "{\"readyState\":\"$state\"}" ;;
      *) echo "unexpected call: vercel $*" >&2; exit 1 ;;
    esac'
}

scenario "deploys main to production from the repo and waits until production reports its commit"
production_holds
run "$deploy" shop
expect_status 0
expect_calls 1 "api /v13/deployments -X POST"
[ "$(jq -c '{target, project, gitSource}' "$T/body")" = '{"target":"production","project":"shop","gitSource":{"type":"github","repoId":42,"ref":"main"}}' ] \
  || fail "expected a production deployment of main from repo 42, got $(cat "$T/body")"
expect_output "deploy ok: https://shop.example runs abc1234, the commit on main"

scenario "deploys when production answers no health check yet"
production_holds
: > "$T/live"
run "$deploy" shop
expect_status 0
expect_calls 1 "api /v13/deployments -X POST"
expect_output "deploy ok"

scenario "does nothing when production already reports the commit on main"
production_holds
echo abc1234000000000000000000000000000000000 > "$T/live"
run "$deploy" shop
expect_status 0
expect_no_call "api /v13/deployments"
expect_output "deploy ok: https://shop.example runs abc1234"

scenario "stops with where to look when the build fails"
production_holds
printf 'BUILDING\nERROR\n' > "$T/states"
run "$deploy" shop
expect_failure
expect_output "deploy.sh: the production deployment dpl_1 ended ERROR"
expect_no_output "deploy ok"
