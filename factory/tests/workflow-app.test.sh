#!/usr/bin/env bash
# Tests for bootstrap's workflow-app.sh: the app is put on the bypass list of the ruleset that locks main.
. "$(dirname "$0")/helpers.sh"

workflow_app="$root/.claude/skills/bootstrap/scripts/workflow-app.sh"

# an_app: the repo has the app `myapp-workflows`, id 77, unless $T/no-app is there. GitHub refuses rulesets as a free
# plan does on a private repo unless $T/ruleset holds the ruleset on main; $T/fail holds a word of the call to fail.
an_app() {
  echo none > "$T/fail"
  : > "$T/put"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"gh $*"; then echo "gh: could not connect (HTTP 502)" >&2; exit 1; fi
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "secret list -R owner/myapp "*) [ -e "$T/no-app" ] || echo WORKFLOW_APP_PRIVATE_KEY ;;
      "variable list -R owner/myapp "*) [ -e "$T/no-app" ] || printf "%s\n" WORKFLOW_APP_CLIENT_ID WORKFLOW_APP_SLUG ;;
      "variable get WORKFLOW_APP_SLUG -R owner/myapp") echo myapp-workflows ;;
      "api repos/owner/myapp/rulesets")
        [ -e "$T/ruleset" ] || { echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1; }
        jq -c "[{id: 9, name: \"another\"}, {id: .id, name: .name}]" "$T/ruleset" ;;
      "api apps/myapp-workflows "*) json "{\"id\":77}" "$@" ;;
      "api repos/owner/myapp/rulesets/5") cat "$T/ruleset" ;;
      "api -X PUT repos/owner/myapp/rulesets/5 --input -") cat > "$T/put" ;;
      "api -X POST app-manifests/code-1/conversions") echo "{\"slug\":\"myapp-workflows\",\"client_id\":\"Iv1\",\"pem\":\"key\"}" ;;
      "variable set WORKFLOW_APP_CLIENT_ID -R owner/myapp --body Iv1" | "variable set WORKFLOW_APP_SLUG -R owner/myapp --body myapp-workflows") ;;
      "secret set WORKFLOW_APP_PRIVATE_KEY -R owner/myapp") cat > /dev/null ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
locked() { echo '{"id":5,"name":"main is merge-only","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' > "$T/ruleset"; }

scenario "puts the app on the bypass list of the ruleset on main, beside the admin"
an_app
locked
run "$workflow_app" myapp
expect_status 0
[ "$(jq -c '.bypass_actors' "$T/put")" = '[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":77,"actor_type":"Integration","bypass_mode":"always"}]' ] \
  || fail "expected the admin and the app on the bypass list, got: $(cat "$T/put")"
expect_output "the ruleset on main lets 'myapp-workflows' push"
expect_output "workflow app ok"

scenario "changes nothing when the app is on the bypass list already"
an_app
echo '{"id":5,"name":"main is merge-only","bypass_actors":[{"actor_id":77,"actor_type":"Integration","bypass_mode":"always"}]}' > "$T/ruleset"
run "$workflow_app" myapp
expect_status 0
expect_no_call "-X PUT"
expect_output "workflow app ok"

scenario "changes nothing where GitHub's plan has no rulesets, as on a private repository on the free plan"
an_app
run "$workflow_app" myapp
expect_status 0
expect_no_call "-X PUT"
expect_no_call "api apps/"
expect_output "workflow app ok"

scenario "changes nothing when no ruleset is the one github.sh sets"
an_app
echo '{"id":5,"name":"another","bypass_actors":[]}' > "$T/ruleset"
run "$workflow_app" myapp
expect_status 0
expect_no_call "-X PUT"

for call in "api repos/owner/myapp/rulesets" "variable get WORKFLOW_APP_SLUG" "api apps/myapp-workflows" "api repos/owner/myapp/rulesets/5" "api -X PUT"; do
  scenario "stops, saying what it could not do, when GitHub fails the call: gh $call"
  an_app
  locked
  echo "gh $call" > "$T/fail"
  run "$workflow_app" myapp
  expect_failure
  expect_output "cannot "
  expect_output "re-run"
  expect_no_output "workflow app ok"
done

scenario "puts a newly made app on the bypass list once its key is stored"
an_app
locked
touch "$T/no-app"
stub python3 'echo code-1'
stub openssl 'cat > /dev/null; echo signed'
stub open 'exit 0'
stub curl '
  case "$*" in
    *"/repos/owner/myapp/installation") echo "{\"id\":3,\"repository_selection\":\"selected\",\"permissions\":{\"contents\":\"write\",\"workflows\":\"write\"}}" ;;
    *"/app/installations/3/access_tokens") echo "{\"token\":\"t\"}" ;;
    *"/installation/repositories?per_page=2") echo "{\"total_count\":1,\"repositories\":[{\"full_name\":\"owner/myapp\"}]}" ;;
    *"/installation/token") ;;
    *) echo "unexpected call: curl $*" >&2; exit 1 ;;
  esac'
run "$workflow_app" myapp
expect_status 0
expect_call "gh secret set WORKFLOW_APP_PRIVATE_KEY -R owner/myapp"
[ "$(jq -c '.bypass_actors[1]' "$T/put")" = '{"actor_id":77,"actor_type":"Integration","bypass_mode":"always"}' ] \
  || fail "expected the new app on the bypass list, got: $(cat "$T/put")"
expect_no_output "AN APP IS LEFT ON GITHUB"
