#!/usr/bin/env bash
# Tests for factory/scripts/ci-run.sh, which prints the newest ci run for a commit that was not skipped.
. "$(dirname "$0")/helpers.sh"

head=5555555555555555555555555555555555555555

# runs <json>: the ci runs GitHub lists for the commit, newest first as it lists them.
runs() {
  printf '%s\n' "$1" > "$T/runs"
  export head
  stub gh 'case "$*" in
    "run list --workflow ci.yml --commit $head --limit 20 --json "*) json "$(cat "$T/runs")" "$@" ;;
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

scenario "asks GitHub for the conclusion as well as the fields, and only once"
runs "[$passed]"
ci_run databaseId,status
expect_call "gh run list --workflow ci.yml --commit $head --limit 20 --json databaseId,status,conclusion --jq"
ci_run databaseId,conclusion
expect_call "gh run list --workflow ci.yml --commit $head --limit 20 --json databaseId,conclusion --jq"

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
for fields in 'databaseId status' 'databaseId,' '.databaseId' ''; do
  ci_run "$fields"
  expect_failure
done
expect_no_call "gh run list"
