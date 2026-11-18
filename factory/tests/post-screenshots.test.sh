#!/usr/bin/env bash
# Tests for post-screenshots.sh: a ticket's acceptance screenshots pushed to the sessions branch and shown in a comment.
. "$(dirname "$0")/helpers.sh"

head=abc1234def5678900000000000000000000000aa
folder="pr-7/screenshots/$head"

. "$(dirname "$0")/sessions-remote.sh"

github() {
  sessions_remote "$@"
  specs=""
}

# took <file> <title> <page|blank> <name> [more results]: a test in the report, whose screenshot is <name>.png.
took() {
  local marks='[]'
  [ "$3" = page ] && marks='[{"type":"opened-a-page"}]'
  mkdir -p "$T/artifact/test-results/$4"
  printf '%s' "$4" > "$T/artifact/test-results/$4/test-finished-1.png"
  specs+=$(jq -nc --arg file "$1" --arg title "$2" --argjson marks "$marks" --argjson earlier "${5:-[]}" \
    --arg path "/home/runner/work/repo/repo/apps/web/test-results/$4/test-finished-1.png" \
    '{title: $title, file: $file, tests: [{annotations: $marks, results: ($earlier + [{status: "passed", attachments: [
       {name: "trace", contentType: "application/zip", path: "/x/test-results/trace.zip"},
       {name: "screenshot", contentType: "image/png", path: $path}]}])}]}')$'\n'
}
report() {
  jq -sc '{suites: [{title: "all", specs: [], suites: (group_by(.file) | map({title: .[0].file, file: .[0].file, specs: .}))}]}' \
    <<<"$specs" > "$T/artifact/test-results/results.json"
}
closes() {
  printf '%s' "$1" > "$T/body"
  stub gh 'case "$*" in
    "pr view 7 --json body --jq"*) json "{\"body\": \"$(cat "$T/body")\"}" "$@" ;;
    "pr comment 7 --body-file "*) cp "$5" "$T/comment.md" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
post() { run "$scripts/post-screenshots.sh" 7 "$head" "$T/artifact"; }
expect_comment() { grep -qF -- "$1" "$T/comment.md" 2>/dev/null || fail "expected the comment to hold: $1"; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"
}
expect_nothing_pushed() {
  [ -z "$(pushed_files | grep screenshots)" ] || fail "expected no screenshot on the sessions branch, found: $(pushed_files)"
}

scenario "shows one image for each of the ticket's tests that opened a page, captioned with its title"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
took acceptance/12-not-found-page.spec.ts "AC2: the endpoint answers 404" blank second
took acceptance/12-not-found-page.spec.ts "AC3: the link leads home" page third
took acceptance/4-landing-page.spec.ts "AC1: a visitor sees the name" page other
took acceptance/120-export.spec.ts "AC1: the forecast exports" page longer-number
took smoke.spec.ts "the home page loads" page smoke
report
post
expect_status 0
expect_output "Posted 2 screenshot(s) from the acceptance tests of #12 on pull request #7."
expect_comment "acceptance tests of #12, at commit abc1234."
expect_comment "**AC1: an unknown path shows the heading**"
expect_comment "![AC1: an unknown path shows the heading](https://github.com/owner/repo/blob/sessions/$folder/1.png?raw=true)"
expect_comment "![AC3: the link leads home](https://github.com/owner/repo/blob/sessions/$folder/2.png?raw=true)"
[ "$(grep -c '^!\[' "$T/comment.md")" = 2 ] || fail "expected exactly two images in the comment"
[ "$(on_github show "sessions:$folder/1.png")" = first ] || fail "expected 1.png to be the first test's screenshot"
[ "$(on_github show "sessions:$folder/2.png")" = third ] || fail "expected 2.png to be the third test's screenshot"
[ "$(pushed_files | grep -c screenshots)" = 2 ] || fail "expected exactly two screenshots pushed, found: $(pushed_files)"
expect_nothing_left

scenario "adds to the sessions branch and touches nothing else: the transcripts stay, and main is as it was"
github sessions
before=$(on_github rev-parse main)
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
post
expect_status 0
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcript to still be on the branch"
[ "$(on_github rev-parse main)" = "$before" ] || fail "expected main not to move"
[ "$(on_github for-each-ref --format='%(refname)' | sort | tr '\n' ' ')" = "refs/heads/main refs/heads/sessions " ] \
  || fail "expected no branch but main and sessions"

scenario "makes the sessions branch when there is none, with the file that stops Vercel deploying it"
github
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
post
expect_status 0
[ "$(on_github show "sessions:$folder/1.png")" = first ] || fail "expected the screenshot on a new sessions branch"
on_github show sessions:apps/web/vercel.json | grep -q '"deploymentEnabled": false' || fail "expected vercel.json to turn deployments off"

scenario "a test that was retried shows its last try"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page last-try \
  '[{"status":"failed","attachments":[{"name":"screenshot","contentType":"image/png","path":"/r/test-results/first-try/test-failed-1.png"}]}]'
report
post
expect_status 0
[ "$(on_github show "sessions:$folder/1.png")" = last-try ] || fail "expected the last try's screenshot"

scenario "run again for the same commit, it replaces the images and leaves none the new comment does not show"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
took acceptance/12-not-found-page.spec.ts "AC3: the link leads home" page third
report
post
specs=""
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
rm -f "$T/comment.md"
post
expect_status 0
[ "$(pushed_files | grep screenshots)" = "$folder/1.png" ] || fail "expected only 1.png, found: $(pushed_files)"
expect_comment "$folder/1.png"

scenario "run again with the same images, it pushes nothing new and still posts the comment"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
post
tip=$(on_github rev-parse sessions)
rm -f "$T/comment.md"
post
expect_status 0
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected no new commit on the sessions branch"
expect_comment "$folder/1.png"

scenario "a title is shown as text: no Markdown of its own, and no mention that would start an agent"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts 'AC1: [x](http://evil) shows *bold* `code` <b> and @claude' page first
report
post
expect_status 0
expect_comment '**AC1: \[x\](http://evil) shows \*bold\* \`code\` \<b\> and claude**'
grep -q '@claude' "$T/comment.md" && fail "expected no @claude in the comment"

scenario "no comment and nothing pushed for a pull request that closes no issue"
github sessions
closes "See #12 for the background."
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
post
expect_status 0
expect_output "closes no issue"
expect_no_call "gh pr comment"
expect_nothing_pushed

scenario "no comment and nothing pushed when none of the ticket's tests opened a page"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC2: the endpoint answers 404" blank second
took acceptance/4-landing-page.spec.ts "AC1: a visitor sees the name" page other
report
post
expect_status 0
expect_output "No acceptance test of #12 opened a page"
expect_no_call "gh pr comment"
expect_nothing_pushed
expect_nothing_left

scenario "stops when the pull request cannot be read: that is not a pull request with nothing to show"
github sessions
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
stub gh 'echo "gh: could not connect" >&2; exit 1'
post
expect_status 1
expect_output "Could not read pull request #7 from GitHub"
expect_no_call "gh pr comment"
expect_nothing_pushed

scenario "stops when there is no test report"
github sessions
closes "Closes #12"
mkdir -p "$T/artifact"
post
expect_status 1
expect_output "No test report at $T/artifact/test-results/results.json"
expect_no_call "gh pr comment"

scenario "stops when the test report cannot be read"
github sessions
closes "Closes #12"
mkdir -p "$T/artifact/test-results" && echo '{"suites": [' > "$T/artifact/test-results/results.json"
post
expect_status 1
expect_output "Could not read the test report"
expect_no_call "gh pr comment"
expect_nothing_pushed

scenario "stops when a screenshot the report names is not in the artifact"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
rm "$T/artifact/test-results/first/test-finished-1.png"
post
expect_status 1
expect_output 'The screenshot of "AC1: an unknown path shows the heading" is not in'
expect_no_call "gh pr comment"
expect_nothing_pushed
expect_nothing_left

scenario "takes no file from outside the artifact, whatever the report says"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
echo secret > "$T/secret.png"
jq '(.. | objects | select(.name? == "screenshot") | .path) = "/r/test-results/../../secret.png"' \
  "$T/artifact/test-results/results.json" > "$T/changed.json" && mv "$T/changed.json" "$T/artifact/test-results/results.json"
post
expect_status 1
expect_output "names a screenshot outside the test results"
expect_no_call "gh pr comment"
expect_nothing_pushed

scenario "takes no file that is not a .png"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
jq '(.. | objects | select(.name? == "screenshot") | .path) = "/r/test-results/results.json"' \
  "$T/artifact/test-results/results.json" > "$T/changed.json" && mv "$T/changed.json" "$T/artifact/test-results/results.json"
post
expect_status 1
expect_output "not a .png file"
expect_nothing_pushed

scenario "takes no link in place of a screenshot"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
echo secret > "$T/secret"
ln -sf "$T/secret" "$T/artifact/test-results/first/test-finished-1.png"
post
expect_status 1
expect_nothing_pushed

scenario "tries again when the push loses a race, and then posts"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
refuses_pushes 1
post
expect_status 0
expect_call "sleep"
[ "$(on_github show "sessions:$folder/1.png")" = first ] || fail "expected the screenshot on the branch after the second try"
expect_comment "$folder/1.png"
expect_nothing_left

scenario "stops, with no comment, when the images cannot be pushed"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
refuses_pushes
post
expect_status 1
expect_output "Could not push the screenshots to the sessions branch (six tries), so no comment was posted."
expect_no_call "gh pr comment"
expect_nothing_pushed
expect_nothing_left

scenario "stops, with no comment, when GitHub cannot be reached at all"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
rm -rf "$T/remote.git"
post
expect_status 1
expect_output "Could not push the screenshots"
expect_no_call "gh pr comment"
expect_nothing_left

scenario "pushes to this repo only: another repo's address leads nowhere"
github sessions
closes "Closes #12"
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
export GITHUB_REPOSITORY=owner/other
# The real git would go to the network for an address the test did not map; it is refused instead.
printf '[url "file://%s/nowhere.git"]\n  insteadOf = https://\n' "$T" >> "$T/gitconfig"
post
expect_status 1
expect_nothing_pushed

scenario "says where the images are when the comment cannot be posted"
github sessions
took acceptance/12-not-found-page.spec.ts "AC1: an unknown path shows the heading" page first
report
stub gh 'case "$*" in
  "pr view 7 --json body --jq"*) json "{\"body\": \"Closes #12\"}" "$@" ;;
  *) echo "gh: could not connect" >&2; exit 1 ;;
esac'
post
expect_status 1
expect_output "The screenshots are on the sessions branch under $folder, but the comment showing them could not be posted on pull request #7."
expect_nothing_left
