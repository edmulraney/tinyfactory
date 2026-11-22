#!/usr/bin/env bash
# Tests for bootstrap's vercel.sh: it switches on Web Analytics, and reports it on only when Vercel says so.
. "$(dirname "$0")/helpers.sh"

vercel="$root/.claude/skills/bootstrap/scripts/vercel.sh"

# vercel_holds: Vercel has the project shop, with the id prj_1 and the domain shop.example, unless $T/new exists, when it
# is made on the first call. $T/toggle holds the answer to the Web Analytics switch: `on`, `off` or `fails`; the body sent
# to it is kept in $T/toggled. $T/project holds `fails` when the project cannot be read after it is made.
vercel_holds() {
  echo on > "$T/toggle"
  echo ok > "$T/project"
  stub gh '
    case "$*" in
      "api user --jq .login") echo owner ;;
      "variable set "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub npx '
    shift 2
    case "$*" in
      "api /v9/projects/shop --raw")
        if [ -e "$T/new" ]; then rm "$T/new"; exit 1; fi
        [ "$(cat "$T/project")" = ok ] || { echo "Error: could not reach Vercel" >&2; exit 1; }
        echo "{\"id\":\"prj_1\",\"name\":\"shop\"}" ;;
      "api /v11/projects -X POST --input - --raw") cat > /dev/null; echo "{\"id\":\"prj_1\"}" ;;
      "api /web/insights/toggle?projectId=prj_1 -X POST --input - --raw")
        cat > "$T/toggled"
        case "$(cat "$T/toggle")" in
          on) echo "{\"value\":true}" ;;
          off) echo "{\"value\":false}" ;;
          fails) echo "Error: You do not have permission to access this resource." >&2; exit 1 ;;
        esac ;;
      "api /v9/projects/shop/domains --raw") echo "{\"domains\":[{\"name\":\"shop.example\"}]}" ;;
      *) echo "unexpected call: vercel $*" >&2; exit 1 ;;
    esac'
}

scenario "switches on Web Analytics for the project that exists, by its id, and reports it on"
vercel_holds
run "$vercel" shop
expect_status 0
expect_calls 1 "api /web/insights/toggle?projectId=prj_1 -X POST"
[ "$(jq -r .value "$T/toggled")" = true ] || fail "expected the switch to be sent {\"value\": true}, got $(cat "$T/toggled")"
expect_output "vercel ok: project 'shop' linked to owner/shop (root apps/web), Web Analytics on"

scenario "switches on Web Analytics for a project it makes"
vercel_holds
touch "$T/new"
run "$vercel" shop
expect_status 0
expect_calls 1 "api /v11/projects -X POST"
expect_calls 1 "api /web/insights/toggle?projectId=prj_1 -X POST"
expect_output "Web Analytics on"

scenario "carries on when the switch fails, with Vercel's answer and the owner's one click"
vercel_holds
echo fails > "$T/toggle"
run "$vercel" shop
expect_status 0
expect_output "You do not have permission to access this resource."
expect_output "Vercel did not switch on Web Analytics: in Vercel's dashboard open the project 'shop', choose Analytics and click Enable"
expect_output "vercel ok: project 'shop' linked to owner/shop (root apps/web)"
expect_no_output "Web Analytics on"

scenario "does not report Web Analytics on when Vercel answers that it is off"
vercel_holds
echo off > "$T/toggle"
run "$vercel" shop
expect_status 0
expect_output "Vercel did not switch on Web Analytics"
expect_no_output "Web Analytics on"

scenario "stops with a message when the project's id cannot be read, and sends no switch"
vercel_holds
echo fails > "$T/project"
run "$vercel" shop
expect_failure
expect_output "could not reach Vercel"
expect_output "vercel.sh: could not read the id of the Vercel project 'shop'"
expect_no_call "/web/insights/toggle"
expect_no_output "vercel ok"
