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
decide() {
  run "$scripts/needs-e2e.sh" 7
  result=$("$scripts/needs-e2e.sh" 7 2>/dev/null) || true
}
expect_result() { [ "$result" = "$1" ] || fail "expected stdout to be exactly \"$1\", got \"$result\""; }

scenario "skips for a change to a factory script alone"
changes factory/scripts/ship.sh
decide
expect_status 0
expect_result "run=false"
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

# job <name>: the lines of that job in ci.yml.
job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
needs() { job "$1" | sed -n 's/^    needs: //p'; }
draft="github.event.pull_request.draft == false"

# A change to the order must fail here: a review that waits for `checks` again costs every run its length (decisions A2).
scenario "ci.yml asks it in the e2e job, which waits for no job and runs no test on a plain false"
job e2e | grep -qF 'run: factory/scripts/needs-e2e.sh "$PR" >> "$GITHUB_OUTPUT"' || fail "the e2e job of ci.yml does not write its answer to the step's outputs"
[ -z "$(needs e2e)" ] || fail "expected e2e to need no job, got: $(needs e2e)"
job e2e | grep -qF 'run: ${{ steps.needed.outputs.run }}' || fail "the e2e job does not pass the answer on to the jobs that need it"
job e2e | grep -A1 -F -- '- name: Say that the end-to-end tests were skipped' | grep -qxF "        if: steps.needed.outputs.run == 'false'" \
  || fail "expected the e2e job to say, on a plain false only, that its tests were skipped"
needs_e2e_line=$(job e2e | grep -n 'run: factory/scripts/needs-e2e.sh' | cut -d: -f1)
for step in 'uses: ./.github/actions/setup' 'name: Wait for the Vercel preview' 'name: Playwright against the preview'; do
  at=$(job e2e | grep -n -F -- "- $step" | cut -d: -f1)
  [ -n "$at" ] && [ "$at" -gt "$needs_e2e_line" ] || fail "expected the step \"$step\" after the one that asks"
  job e2e | sed -n "$((at + 1)),$((at + 2))p" | grep -qxF "        if: steps.needed.outputs.run != 'false'" \
    || fail "expected the step \"$step\" to run on anything but a plain false"
done

scenario "ci.yml starts each review when e2e has passed, without waiting for checks"
for reviewer in adam ryan; do
  [ "$(needs "$reviewer")" = e2e ] || fail "expected $reviewer to need e2e alone, got: $(needs "$reviewer")"
  # With a status function in its condition it would have to name e2e's result, or run after a failed e2e.
  ! job "$reviewer" | grep '^    if:' | grep -qE 'always\(|cancelled\(|failure\(|success\(' \
    || fail "expected $reviewer to carry no status function, so that a failed or skipped e2e skips it"
done

scenario "ci.yml merges only when every job passed, and starts a fix round when any failed"
for last in merge start-fix; do
  [ "$(needs "$last")" = "[checks, e2e, adam, ryan, fits-main]" ] || fail "expected $last to need every other job, got: $(needs "$last")"
done
merge=$(job merge | sed -n '/^    if: >-$/,/^    runs-on:/p')
for passed in checks e2e adam ryan; do
  grep -qF "needs.$passed.result == 'success'" <<<"$merge" || fail "expected merge to run only when $passed passed"
done
# Without `skipped` no first attempt would merge: fits-main runs only when asked for again (decisions M17).
grep -qF "(needs.fits-main.result == 'success' || needs.fits-main.result == 'skipped')" <<<"$merge" \
  || fail "expected merge to run only when fits-main passed or was skipped"
grep -qF '!cancelled()' <<<"$merge" || fail "expected merge not to run in a cancelled run"
fix=$(job start-fix | sed -n '/^    if: >-$/,/^    runs-on:/p')
for failed in checks e2e adam ryan fits-main; do
  grep -qF "needs.$failed.result == 'failure'" <<<"$fix" || fail "expected start-fix to run when $failed failed"
done

scenario "ci.yml runs nothing on a draft: each job that needs no other carries the condition"
for first in checks e2e fits-main; do
  [ -z "$(needs "$first")" ] || fail "expected $first to need no job, got: $(needs "$first")"
  job "$first" | grep -q "^    if: $draft" || fail "expected $first to be skipped for a draft"
done
