#!/usr/bin/env bash
# Tests for linked-issue.sh: the number of the issue a pull request closes, or nothing.
. "$(dirname "$0")/helpers.sh"

pull_request() {
  printf '%s\n' "$1" > "$T/pr.json"
  stub gh 'case "$*" in
    "pr view 7 --json body --jq"*) json "$(cat "$T/pr.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}

scenario "prints the number of the issue the description closes"
pull_request '{"body":"Closes #12\n\n## What changed\nThe forecast exports as CSV."}'
run "$scripts/linked-issue.sh" 7
expect_status 0
[ "$out" = 12 ] || fail "expected exactly: 12"

scenario "reads fixes and resolves too, in any case, and prints only the first"
pull_request '{"body":"This FIXES #40 and resolves #41."}'
run "$scripts/linked-issue.sh" 7
expect_status 0
[ "$out" = 40 ] || fail "expected exactly: 40"

scenario "prints nothing, and succeeds, for a pull request that closes no issue"
pull_request '{"body":"See #12 for the background."}'
run "$scripts/linked-issue.sh" 7
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "prints nothing, and succeeds, for a pull request with no description"
pull_request '{"body":null}'
run "$scripts/linked-issue.sh" 7
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "stops when GitHub cannot be read: that is not a pull request that closes no issue"
stub gh 'echo "gh: could not connect" >&2; exit 1'
run "$scripts/linked-issue.sh" 7
expect_status 1
expect_output "Could not read pull request #7 from GitHub"
