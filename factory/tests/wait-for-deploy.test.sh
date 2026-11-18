#!/usr/bin/env bash
# Tests for factory/scripts/wait-for-deploy.sh: wait until production reports a commit, or stop when Vercel skipped it.
. "$(dirname "$0")/helpers.sh"

expected=abcdef0123456789abcdef0123456789abcdef01

# The clock jumps 100 seconds each time it is read and sleeping takes no time, so a ten-minute wait ends at once.
production() {
  echo "{\"commit\":\"$1\"}" > "$T/health"
  echo '[]' > "$T/statuses.json"
  stub curl 'cat "$T/health" 2>/dev/null || { echo "curl: (7) could not connect" >&2; exit 7; }'
  stub gh 'case "$*" in
    "api repos/{owner}/{repo}/commits/'"$expected"'/statuses "*) json "$(cat "$T/statuses.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
  stub sleep ':'
  stub date 'now=$(cat "$T/clock" 2>/dev/null || echo 1000); echo $((now + 100)) > "$T/clock"; echo "$now"'
}
wait_for() { run "$scripts/wait-for-deploy.sh" https://myapp.example/ "$expected"; }
request_count() { grep -c '^curl ' "$T/calls" || true; }

scenario "says live when production reports the commit"
production "$expected"
wait_for
expect_status 0
expect_output "live: https://myapp.example/api/health reports $expected"
expect_call "curl -fsS --max-time 10 https://myapp.example/api/health"
expect_no_call "gh api"

scenario "times out, saying what production reports, when it runs another commit"
production 0000000000000000000000000000000000000000
wait_for
expect_status 1
expect_output "timed out: https://myapp.example/api/health reports '0000000000000000000000000000000000000000', expected $expected"
[ "$(request_count)" -gt 1 ] || fail "expected it to ask production more than once, got $(request_count)"

scenario "times out when production cannot be reached"
production "$expected"
rm "$T/health"
wait_for
expect_status 1
expect_output "reports 'nothing'"

scenario "stops at once, with its own exit, when Vercel says it skipped the deployment"
production 0000000000000000000000000000000000000000
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
wait_for
expect_status 2
expect_output "skipped: Vercel did not deploy $expected (\"Skipped - Not affected\")"
[ "$(request_count)" = 1 ] || fail "expected it to ask production once, got $(request_count)"
expect_no_call "sleep"

scenario "goes by Vercel's newest status: a deployment skipped first and then made is waited for"
production 0000000000000000000000000000000000000000
echo '[{"context":"Vercel","state":"pending","description":"Vercel is deploying your app"},{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
wait_for
expect_status 1
expect_no_output "skipped"

scenario "keeps waiting when only one of Vercel's projects skipped the commit, or the status is someone else's"
production 0000000000000000000000000000000000000000
echo '[{"context":"Vercel – docs","state":"success","description":"Skipped - Not affected"},{"context":"Vercel – myapp","state":"pending","description":"Building"},{"context":"ci","state":"success","description":"Skipped"}]' > "$T/statuses.json"
wait_for
expect_status 1
expect_no_output "skipped"
echo '[{"context":"ci","state":"success","description":"Skipped"},{"context":"Vercel","state":"success","description":null}]' > "$T/statuses.json"
rm "$T/clock"
wait_for
expect_status 1
expect_no_output "skipped"

scenario "keeps waiting when the statuses cannot be read: that is not a skipped deployment, nor a failure"
production 0000000000000000000000000000000000000000
stub gh 'echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1'
wait_for
expect_status 1
expect_output "timed out"
expect_no_output "skipped"

scenario "says live when the commit is live, whatever the statuses say"
production "$expected"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
wait_for
expect_status 0
