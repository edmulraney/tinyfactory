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
  stub gh 'case "$*" in
    "api repos/owner/repo/pulls/7/files --paginate "*) json "$(cat "$T/files.json")" "$@" ;;
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
