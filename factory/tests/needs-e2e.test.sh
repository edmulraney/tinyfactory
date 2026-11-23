#!/usr/bin/env bash
# Tests for factory/scripts/needs-e2e.sh: whether a pull request's end-to-end tests need to run.
. "$(dirname "$0")/helpers.sh"

# changes <path>...: the pull request changes these files. A path written old:new was renamed.
changes() {
  export GITHUB_REPOSITORY=owner/repo
  local path
  for path in "$@"; do
    case "$path" in
      *:*) jq -n --arg old "${path%%:*}" --arg new "${path#*:}" '{filename: $new, previous_filename: $old}' ;;
      *) jq -n --arg new "$path" '{filename: $new}' ;;
    esac
  done | jq -s . > "$T/files.json"
  [ -f "$T/comments.json" ] || echo '[]' > "$T/comments.json"
  stub gh 'case "$*" in
    "api repos/owner/repo/pulls/7/files --paginate "*) json "$(cat "$T/files.json")" "$@" ;;
    "api repos/owner/repo/issues/7/comments --paginate "*) json "$(cat "$T/comments.json")" "$@" ;;
    "api repos/owner/repo/compare/"*"...head456 "*) [ -f "$T/compare.json" ] && json "$(cat "$T/compare.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
# Only what the script printed on stdout: what the workflow writes to the job's outputs.
# The script is run from a copy that has an apps folder beside it: it looks for the app there, and
# the repository these tests run in may hold none.
decide() {
  mkdir -p "$T/repo/factory/scripts" "$T/repo/apps"
  cp "$scripts/needs-e2e.sh" "$T/repo/factory/scripts/"
  run "$T/repo/factory/scripts/needs-e2e.sh" 7
  result=$("$T/repo/factory/scripts/needs-e2e.sh" 7 2>/dev/null) || true
}
# expect_result <run=…> [reason]: stdout is that line, then one line `reason=`, which holds the reason when one is given.
expect_result() {
  [ "$(sed -n 1p <<<"$result")" = "$1" ] && [ "$(grep -c . <<<"$result")" -eq 2 ] && grep -q '^reason=.' <<<"$(sed -n 2p <<<"$result")" \
    || fail "expected stdout to be exactly \"$1\" and a line \"reason=…\", got \"$result\""
  [ -z "${2:-}" ] || [ "$(sed -n 2p <<<"$result")" = "reason=$2" ] || fail "expected the reason \"$2\", got \"$(sed -n 2p <<<"$result")\""
}

# commented <login> <body>...: the pull request's comments, oldest first, each by that account.
commented() {
  local login="$1"
  shift
  printf '%s\n' "$@" | jq -R --arg login "$login" '{user: {login: $login}, body: .}' | jq -s . > "$T/comments.json"
}
# compared <status> <path>...: GitHub's comparison of the passed commit with head456.
compared() {
  local status="$1"
  shift
  printf '%s\n' "$@" | jq -R 'select(. != "") | {filename: .}' | jq -s --arg status "$status" '{status: $status, files: .}' > "$T/compare.json"
}
old=1111111111111111111111111111111111111111
new=2222222222222222222222222222222222222222

scenario "skips a commit whose app the newest passed commit's tests ran on, and says which"
commented "github-actions[bot]" "End-to-end tests passed for $old against https://a.vercel.app. Screenshots and report - x" \
  "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
compared ahead factory/scripts/ship.sh
changes apps/web/src/app/page.tsx
HEAD_SHA=head456 decide
expect_status 0
expect_result "run=false" "Pull request #7's end-to-end tests passed for 2222222, and no app file has changed since, so they passed on the app this commit holds."
expect_call "gh api repos/owner/repo/compare/$new...head456"

scenario "skips the very commit that passed, run again"
commented "github-actions[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
compared identical
changes apps/web/src/app/page.tsx
HEAD_SHA=head456 decide
expect_result "run=false"

scenario "runs when an app file changed since the commit that passed"
commented "github-actions[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
compared ahead factory/scripts/ship.sh apps/web/src/app/page.tsx
changes apps/web/src/app/page.tsx
HEAD_SHA=head456 decide
expect_result "run=true" "Pull request #7 changes app code (apps/web/src/app/page.tsx), so its end-to-end tests run."

scenario "runs when the commit that passed is not an ancestor of the one to test"
commented "github-actions[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
compared diverged factory/scripts/ship.sh
changes apps/web/src/app/page.tsx
HEAD_SHA=head456 decide
expect_result "run=true"

scenario "runs when GitHub lists as many files as it lists of a comparison, so may have cut it short"
commented "github-actions[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
# shellcheck disable=SC2046
compared ahead $(seq -f 'factory/tests/%g.test.sh' 1 300)
changes apps/web/src/app/page.tsx
HEAD_SHA=head456 decide
expect_result "run=true"

scenario "runs on tests that ran and did not pass, and on a passed comment by any account but the workflow's"
changes apps/web/src/app/page.tsx
commented "claude[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
HEAD_SHA=head456 decide
expect_result "run=true"
expect_no_call "compare"
commented "github-actions[bot]" "End-to-end tests ran against https://b.vercel.app. Screenshots and report - y"
HEAD_SHA=head456 decide
expect_result "run=true"
expect_no_call "compare"

for broken in comments compare; do
  scenario "runs when the $broken read fails"
  commented "github-actions[bot]" "End-to-end tests passed for $new against https://b.vercel.app. Screenshots and report - y"
  changes apps/web/src/app/page.tsx
  # With no comparison written, the stand-in fails that read.
  [ "$broken" = compare ] || echo 'not json' > "$T/comments.json"
  HEAD_SHA=head456 decide
  expect_status 0
  expect_result "run=true"
done

scenario "asks for no passed commit with no commit to test, nor for a pull request that changes no app code"
changes apps/web/src/app/page.tsx
decide
expect_result "run=true"
changes factory/scripts/ship.sh
HEAD_SHA=head456 decide
expect_result "run=false" "Pull request #7 changes no app code, so the app in its preview is the app on main."
expect_no_call "comments"

scenario "skips for a change to a factory script alone"
changes factory/scripts/ship.sh
decide
expect_status 0
expect_result "run=false" "Pull request #7 changes no app code, so the app in its preview is the app on main."
expect_output "changes no app code"

scenario "skips for factory files, skills, workflows and documents together"
changes factory/scripts/ship.sh factory/workflows/ci.yml .claude/skills/implement/SKILL.md \
  .github/PULL_REQUEST_TEMPLATE.md CLAUDE.md product/decisions.md
decide
expect_status 0
expect_result "run=false"

scenario "runs for a change to a page of the app"
changes apps/web/src/app/page.tsx
decide
expect_status 0
expect_result "run=true"
expect_output "changes app code (apps/web/src/app/page.tsx)"

scenario "runs for a change to a shared package"
changes packages/ui/src/button.tsx
decide
expect_result "run=true"

scenario "runs for a change to pnpm-lock.yaml alone"
changes pnpm-lock.yaml
decide
expect_status 0
expect_result "run=true"

scenario "runs for a change to the root package.json alone"
changes package.json
decide
expect_result "run=true"

scenario "runs for a change to pnpm-workspace.yaml alone"
changes pnpm-workspace.yaml
decide
expect_result "run=true"

scenario "runs for a mix of factory files and app code"
changes factory/scripts/ship.sh CLAUDE.md apps/web/src/app/page.tsx factory/README.md
decide
expect_status 0
expect_result "run=true"

scenario "runs for a file moved out of the app: the app lost it"
changes apps/web/NOTES.md:product/notes.md
decide
expect_result "run=true"
expect_output "apps/web/NOTES.md"

scenario "skips for the three file names anywhere but the root, and a folder that only ends in apps"
changes factory/package.json product/pnpm-lock.yaml .claude/pnpm-workspace.yaml factory/apps/web/page.tsx \
  product/packages/notes.md package.json.md
decide
expect_status 0
expect_result "run=false"

scenario "skips for a pull request that changes no file"
changes
decide
expect_status 0
expect_result "run=false"

scenario "runs when the changed files cannot be read, and says why"
export GITHUB_REPOSITORY=owner/repo
stub gh 'echo "gh: could not connect" >&2; exit 1'
decide
expect_status 0
expect_result "run=true"
expect_output "Could not read the files pull request #7 changes"

scenario "runs when the read fails part-way, whatever it had listed by then"
export GITHUB_REPOSITORY=owner/repo
stub gh 'echo factory/scripts/ship.sh; echo "gh: HTTP 502" >&2; exit 1'
decide
expect_status 0
expect_result "run=true"

scenario "runs when the list is as long as GitHub lets one be, so may be cut short"
# shellcheck disable=SC2046
changes $(seq -f 'factory/tests/%g.test.sh' 1 3000)
decide
expect_status 0
expect_result "run=true"
expect_output "GitHub lists no more than that"

scenario "skips one file short of that"
# shellcheck disable=SC2046
changes $(seq -f 'factory/tests/%g.test.sh' 1 2999)
decide
expect_result "run=false"

scenario "asks about the pull request it was given, in this repo, with every page of its files"
changes factory/scripts/ship.sh
decide
expect_call "gh api repos/owner/repo/pulls/7/files --paginate"
[ "$(wc -l < "$T/calls")" -eq 2 ] || fail "expected one call to gh for each of the two runs, and no other"

scenario "stops when it is given no pull request"
run "$scripts/needs-e2e.sh"
expect_failure
expect_output "Usage: needs-e2e.sh <pr-number>"
expect_no_call "gh"

# no_app: a copy of the script in a repository that holds no apps folder, where a stand-in for gh refuses every call.
no_app() {
  mkdir -p "$T/repo/factory/scripts"
  cp "$scripts/needs-e2e.sh" "$T/repo/factory/scripts/"
  export GITHUB_REPOSITORY=owner/repo
}
decide_no_app() {
  run "$1" 7
  result=$("$1" 7 2>/dev/null) || true
  expect_status 0
  expect_result "run=false" "This repository holds no apps folder, so it has no end-to-end tests to run for pull request #7."
  expect_output "This repository holds no apps folder"
  expect_no_call "gh"
}

scenario "skips in a repository with no apps folder, and asks GitHub nothing"
no_app
cd "$T/repo" || exit 1
decide_no_app factory/scripts/needs-e2e.sh

scenario "skips there when called from another folder, also one that holds an apps folder"
no_app
mkdir -p "$T/work/apps/web"
decide_no_app "$T/repo/factory/scripts/needs-e2e.sh"
cd "$T/repo/factory" || exit 1
decide_no_app scripts/needs-e2e.sh

scenario "asks GitHub in a repository that holds an apps folder, called from one that holds none"
no_app
mkdir "$T/repo/apps"
changes apps/web/src/app/page.tsx
run "$T/repo/factory/scripts/needs-e2e.sh" 7
expect_status 0
expect_output "changes app code"
expect_call "gh api repos/owner/repo/pulls/7/files --paginate"

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
needs() { job "$1" | sed -n 's/^    needs: //p'; }

scenario "ci.yml asks it in the e2e job, which waits for no job and runs no test on a plain false"
job e2e | grep -qF 'run: factory/scripts/needs-e2e.sh "$PR" >> "$GITHUB_OUTPUT"' || fail "the e2e job of ci.yml does not write its answer to the step's outputs"
[ -z "$(needs e2e)" ] || fail "expected e2e to need no job, got: $(needs e2e)"
job e2e | grep -qF 'run: ${{ steps.needed.outputs.run }}' || fail "the e2e job does not pass the answer on to the jobs that need it"
job e2e | grep -A1 -F -- '- name: Say that the end-to-end tests were skipped' | grep -qxF "        if: steps.needed.outputs.run == 'false'" \
  || fail "expected the e2e job to say, on a plain false only, that its tests were skipped"
job e2e | grep -qxF '          REASON: ${{ steps.needed.outputs.reason }}   # the sentence needs-e2e.sh printed (decisions M608)' \
  && job e2e | grep -F 'gh pr comment "$PR"' | grep -qF 'were skipped for $HEAD_SHA. $REASON factory/scripts/needs-e2e.sh decides this."' \
  || fail "expected the comment about skipped tests to carry the reason the script printed, and no sentence of the workflow's own"
needs_e2e_line=$(job e2e | grep -n 'run: factory/scripts/needs-e2e.sh' | cut -d: -f1)
for step in 'uses: ./.github/actions/setup' 'name: Wait for the Vercel preview' 'name: Playwright against the preview'; do
  at=$(job e2e | grep -n -F -- "- $step" | cut -d: -f1)
  [ -n "$at" ] && [ "$at" -gt "$needs_e2e_line" ] || fail "expected the step \"$step\" after the one that asks"
  job e2e | sed -n "$((at + 1)),$((at + 2))p" | grep -qxF "        if: steps.needed.outputs.run != 'false'" \
    || fail "expected the step \"$step\" to run on anything but a plain false"
done

scenario "ci.yml gives it the commit to test, and names that commit in its comment only once Playwright passed"
job e2e | sed -n '/^      - name: Do the end-to-end tests need to run?$/,/^      - /p' \
  | grep -qxF '          HEAD_SHA: ${{ github.event.pull_request.head.sha }}' || fail "expected the step that asks to pass it the head commit"
link=$(job e2e | sed -n '/^      - name: Link the visual proof on the pull request$/,$p')
grep -qxF "          PASSED: \${{ steps.playwright.outcome == 'success' }}" <<<"$link" || fail "expected the comment to read Playwright's outcome"
job e2e | grep -A1 -xF '      - name: Playwright against the preview' | grep -qxF '        id: playwright' \
  || fail "expected the Playwright step to have the id its outcome is read from"
commands=$(sed -n '/^        run: |$/,$p' <<<"$link" | sed -e 1d -e 's/^          //')
stub gh 'exit 0'
for passed in true false; do
  run env PASSED=$passed HEAD_SHA=$new PR=7 PREVIEW=https://b.vercel.app PROOF=x GH_TOKEN=t bash --noprofile --norc -e -c "$commands"
  body=$(sed -n 's/^gh pr comment 7 --body //p' "$T/calls" | tail -n 1)
  commented "github-actions[bot]" "$body"
  changes apps/web/src/app/page.tsx
  compared ahead
  HEAD_SHA=head456 decide
  [ "$passed" = true ] && expected=run=false || expected=run=true
  expect_result "$expected"
  stub gh 'exit 0'
done
