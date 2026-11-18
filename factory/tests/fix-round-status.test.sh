#!/usr/bin/env bash
# Tests for factory/scripts/fix-round-status.sh, which sets the status that shows a fix round in a pull request.
. "$(dirname "$0")/helpers.sh"

commit=5555555555555555555555555555555555555555

github() {
  stub gh '
    case "$*" in
      "api repos/owner/myapp/statuses/'"$commit"' "*) [ ! -e "$T/fail" ] || { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
        echo "{\"id\":1}" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
status() { run env -u GITHUB_RUN_ID GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/fix-round-status.sh" "$commit" "$@"; }

scenario "a round that begins is shown as pending, with its name and who is working"
github
status "fix round 2 of 3" working Fred
expect_status 0
expect_call "gh api repos/owner/myapp/statuses/$commit -f state=pending -f context=fix round -f description=fix round 2 of 3: Fred is working"
expect_output "set the status on 5555555: fix round 2 of 3: Fred is working"
[ -z "$out" ] || [ "$(wc -l <<<"$out")" -eq 1 ] || fail "expected GitHub's answer not to be printed"

scenario "a round whose job succeeded is shown as ended, under the same context, so it replaces the first"
github
status "the owner's fix round" success
expect_status 0
expect_call "gh api repos/owner/myapp/statuses/$commit -f state=success -f context=fix round -f description=the owner's fix round has ended"

for how in failure cancelled; do
  scenario "a round whose job ended in $how is shown as failed"
  github
  status "fix round for a conflict" "$how"
  expect_status 0
  expect_call "gh api repos/owner/myapp/statuses/$commit -f state=failure -f context=fix round -f description=fix round for a conflict failed: its run says why"
done

scenario "links the run it is called in, and no run when there is none"
github
run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID=900 GITHUB_SERVER_URL=https://github.example "$scripts/fix-round-status.sh" "$commit" "fix round 1 of 3" success
expect_call "-f description=fix round 1 of 3 has ended -f target_url=https://github.example/owner/myapp/actions/runs/900"
: > "$T/calls"
status "fix round 1 of 3" success
expect_no_call "target_url"

scenario "stops with a message when the status cannot be set"
github
: > "$T/fail"
status "fix round 2 of 3" working Fred
expect_status 1
expect_output "Could not set the status \"fix round 2 of 3: Fred is working\" on 5555555, so the pull request's checks do not show it."
expect_no_output "set the status on"

scenario "refuses a call that names no engineer for a round that begins, or no state at all"
github
status "fix round 2 of 3" working
expect_failure
expect_output "Usage: fix-round-status.sh"
status "fix round 2 of 3"
expect_failure
expect_no_call "gh api"

scenario "leaves nothing behind"
github
status "fix round 2 of 3" working Fred
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
