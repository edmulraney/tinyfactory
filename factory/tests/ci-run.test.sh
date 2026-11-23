#!/usr/bin/env bash
# Tests for factory/scripts/ci-run.sh, which prints the newest ci run of a commit that this repository started.
. "$(dirname "$0")/helpers.sh"

head=5555555555555555555555555555555555555555

# runs <json>: the ci runs GitHub lists for the commit, newest first as it lists them.
runs() {
  printf '%s\n' "$1" > "$T/runs"
  export head
  stub gh 'case "$*" in
    "api repos/{owner}/{repo}/actions/workflows/ci.yml/runs?per_page=100&head_sha=$head --jq "*) ci_runs "$(cat "$T/runs")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
ci_run() { run "$scripts/ci-run.sh" "$head" "$1"; }
passed='{"databaseId":900,"status":"completed","conclusion":"success","attempt":2}'
skipped='{"databaseId":901,"status":"completed","conclusion":"skipped","attempt":1}'

scenario "prints the fields asked for, in the order asked, of the commit's one ci run"
runs "[$passed]"
ci_run databaseId,status
expect_status 0
[ "$out" = "900 completed" ] || fail "expected exactly: 900 completed"
ci_run attempt
[ "$out" = 2 ] || fail "expected exactly: 2"
ci_run conclusion,databaseId
[ "$out" = "success 900" ] || fail "expected exactly: success 900"

scenario "passes over a newer run of a fork's pull request on the same commit"
fork='{"databaseId":903,"status":"completed","conclusion":"failure","attempt":1,"repository":"stranger/fork"}'
runs "[$fork,$passed]"
ci_run databaseId,conclusion
expect_status 0
[ "$out" = "900 success" ] || fail "expected exactly: 900 success"
runs "[$fork]"
ci_run databaseId
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing when only a fork ran"

scenario "reads every page, so a fork's runs cannot push this repository's off the first"
fork_page=$(jq -c -n --argjson run "$fork" '[range(100) | $run]')
printf '%s\n' "$fork_page" > "$T/page-1"
printf '%s\n' "[$passed]" > "$T/page-2"
# The second page answers only a call that asks for every page, as gh api does.
stub gh 'ci_runs "$(cat "$T/page-1")" "$@"; case " $* " in *" --paginate "*) ci_runs "$(cat "$T/page-2")" "$@" ;; esac'
ci_run databaseId
expect_status 0
[ "$out" = 900 ] || fail "expected exactly: 900, the run on the second page"

scenario "passes over a skipped run that is newer than the one that ran"
runs "[$skipped,$passed]"
ci_run databaseId,conclusion
expect_status 0
[ "$out" = "900 success" ] || fail "expected exactly: 900 success"

scenario "passes over a skipped run that is older than the one that ran"
runs "[$passed,$skipped]"
ci_run databaseId
[ "$out" = 900 ] || fail "expected exactly: 900"

scenario "prints the newest of two runs that both ran"
runs '[{"databaseId":902,"status":"in_progress","conclusion":""},'"$passed]"
ci_run databaseId,status,conclusion
expect_status 0
[ "$out" = "902 in_progress " ] || fail "expected exactly: 902 in_progress and an empty conclusion"

scenario "prints nothing, and succeeds, when the only run was skipped, and when there is none"
runs "[$skipped]"
ci_run databaseId,status
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing for a skipped run"
runs "[]"
ci_run databaseId,status
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing for no run"

scenario "stops when GitHub cannot be read: that is not a commit with no run"
stub gh 'echo "gh: could not connect" >&2; exit 1'
ci_run databaseId,status
expect_failure
expect_output "gh: could not connect"

scenario "refuses fields that are not names separated by commas, and asks GitHub nothing"
runs "[$passed]"
for fields in 'databaseId status' 'databaseId,' '.databaseId' '' 'headSha'; do
  ci_run "$fields"
  expect_failure
done
expect_no_call "gh api"
