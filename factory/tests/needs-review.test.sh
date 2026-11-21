#!/usr/bin/env bash
# Tests for factory/scripts/needs-review.sh: whether a pull request's commit is worth a review.
. "$(dirname "$0")/helpers.sh"

head=2dc3c98c0a86b1f120cacb6996aabafd73156a13

# branch <commits-ahead> <path>...: what GitHub says the commit adds to main.
branch() {
  export GITHUB_REPOSITORY=owner/repo
  local ahead="$1"
  shift
  printf '%s\n' "$@" | jq -R 'select(. != "") | {filename: .}' | jq -s --argjson ahead "$ahead" '{ahead_by: $ahead, files: .}' > "$T/compare.json"
  stub gh 'case "$*" in
    "api repos/owner/repo/compare/main...'"$head"' --jq "*) json "$(cat "$T/compare.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
# Only what the script printed on stdout: what the workflow writes to the job's outputs.
decide() {
  run "$scripts/needs-review.sh" main "$head"
  result=$("$scripts/needs-review.sh" main "$head" 2>/dev/null) || true
}
expect_result() { [ "$result" = "$1" ] || fail "expected stdout to be exactly \"$1\", got \"$result\""; }

scenario "no review for a pull request holding only its start commit, which changes no file"
branch 1
decide
expect_status 0
expect_result "review=false"
expect_output "Commit 2dc3c98 is the only one on its branch and changes no file"

scenario "a review for a first commit that changes a file"
branch 1 factory/scripts/ship.sh
decide
expect_status 0
expect_result "review=true"
expect_output "Commit 2dc3c98 is not a build's empty first commit alone"

scenario "a review for the start commit and the work pushed after it"
branch 2 factory/scripts/ship.sh
decide
expect_result "review=true"

scenario "a review for a later commit, though the branch now changes no file"
branch 3
decide
expect_status 0
expect_result "review=true"

scenario "a review when GitHub cannot be read, and it says why"
export GITHUB_REPOSITORY=owner/repo
stub gh 'echo "gh: could not connect" >&2; exit 1'
decide
expect_status 0
expect_result "review=true"
expect_output "Could not read from GitHub what commit 2dc3c98 adds to main"

scenario "a review when the read fails part-way, whatever it had printed by then"
export GITHUB_REPOSITORY=owner/repo
stub gh 'echo "1 0"; echo "gh: HTTP 502" >&2; exit 1'
decide
expect_status 0
expect_result "review=true"

scenario "a review when GitHub's answer holds neither number"
export GITHUB_REPOSITORY=owner/repo
stub gh 'json "{}" "$@"'
decide
expect_status 0
expect_result "review=true"

scenario "asks once, about the commit it was given and its base, in this repo"
branch 1
decide
expect_call "gh api repos/owner/repo/compare/main...$head --jq"
[ "$(wc -l < "$T/calls")" -eq 2 ] || fail "expected one call to gh for each of the two runs, and no other"

scenario "stops when it is given no commit"
run "$scripts/needs-review.sh" main
expect_failure
expect_output "Usage: needs-review.sh <base-branch> <head-sha>"
expect_no_call "gh"

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }

scenario "ci.yml asks it in the e2e job, about the commit the run began for, and passes the answer on"
job e2e | grep -qF 'run: factory/scripts/needs-review.sh "$BASE" "$HEAD_SHA" >> "$GITHUB_OUTPUT"' \
  || fail "the e2e job of ci.yml does not write the answer to the step's outputs"
asking=$(job e2e | grep -B6 -F 'run: factory/scripts/needs-review.sh')
grep -qxF '          BASE: ${{ github.base_ref }}' <<<"$asking" || fail "expected the step to be given the pull request's base branch"
grep -qxF '          HEAD_SHA: ${{ github.event.pull_request.head.sha }}' <<<"$asking" || fail "expected the step to be given the commit the run began for"
grep -qxF '        id: reviewable' <<<"$asking" || fail "expected the step to be called reviewable"
! grep -q 'if:' <<<"$asking" || fail "expected the step to carry no condition"
job e2e | grep -qF 'review: ${{ steps.reviewable.outputs.review }}' || fail "the e2e job does not pass the answer on to the reviews"

# With a status function in it, a review would run after a failed e2e, or on a draft (decisions A50c).
scenario "ci.yml starts neither review on a plain false, and on any other answer only when e2e passed"
[ "$(job review | grep '^    if:')" = "    if: needs.e2e.outputs.review != 'false'" ] \
  || fail "expected the review job to carry the one condition, on e2e's answer, with no status function"
