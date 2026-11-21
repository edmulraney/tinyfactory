#!/usr/bin/env bash
# Tests for factory/scripts/checks-needed.sh: which checks a change can affect.
. "$(dirname "$0")/helpers.sh"

# changes <path>...: a repo whose last commit changes these files. A path written old:new was moved.
changes() {
  git init --quiet .
  mkdir -p apps/web product
  echo page > apps/web/moved.tsx
  echo notes > product/moved.md
  echo first > README.md
  git add . && git commit --quiet -m main
  local path
  for path in "$@"; do
    case "$path" in
      *:*) mkdir -p "$(dirname "${path#*:}")"; git mv "${path%%:*}" "${path#*:}" ;;
      *) mkdir -p "$(dirname "$path")"; echo changed > "$path" ;;
    esac
  done
  git add . && git commit --quiet --allow-empty -m change
}
# Only what the script printed on stdout: what the workflow writes to the step's outputs.
decide() {
  run "$scripts/checks-needed.sh" "${1:-HEAD^}"
  result=$("$scripts/checks-needed.sh" "${1:-HEAD^}" 2>/dev/null) || true
}
expect_result() {
  [ "$result" = "app=$1"$'\n'"factory=$2" ] || fail "expected stdout to be exactly app=$1 and factory=$2, got \"$result\""
}

scenario "a change to the factory alone runs the factory's tests and none of the app's checks"
changes factory/scripts/ship.sh
decide
expect_status 0
expect_result false true
expect_output "changes nothing the app is built from"
expect_output "changes the factory (factory/scripts/ship.sh)"

scenario "a skill or a file under .github is the factory's too"
for path in .claude/skills/implement/SKILL.md .github/PULL_REQUEST_TEMPLATE.md; do
  rm -rf "$T/work" && mkdir "$T/work" && cd "$T/work" || exit 1
  changes "$path"
  decide
  expect_result false true
done

scenario "a change to the app alone runs the app's checks and not the factory's tests"
changes apps/web/src/app/page.tsx
decide
expect_status 0
expect_result true false
expect_output "changes what the app is built from (apps/web/src/app/page.tsx)"
expect_output "changes nothing of the factory's"

scenario "a change to a shared package is the app's"
changes packages/ui/src/button.tsx
decide
expect_result true false

scenario "a shared action sets up every check, so a change to one alone runs everything"
changes .github/actions/setup/action.yml
decide
expect_status 0
expect_result true true
expect_output "changes what the app is built from (.github/actions/setup/action.yml)"

scenario "a file whose name has a letter outside ASCII is still the app's, or the factory's"
changes apps/web/src/café.tsx
decide
expect_result true false
expect_output "apps/web/src/café.tsx"
rm -rf "$T/work" && mkdir "$T/work" && cd "$T/work" || exit 1
changes factory/scripts/café.sh
decide
expect_result false true

scenario "a change to both runs everything"
changes factory/scripts/ship.sh apps/web/src/app/page.tsx CLAUDE.md
decide
expect_status 0
expect_result true true

scenario "the root's package.json, pnpm-lock.yaml or pnpm-workspace.yaml alone runs everything"
for path in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
  rm -rf "$T/work" && mkdir "$T/work" && cd "$T/work" || exit 1
  changes "$path"
  decide
  expect_status 0
  expect_result true true
done

scenario "a change to documents alone runs neither"
changes CLAUDE.md product/decisions.md ARCHITECTURE.md
decide
expect_status 0
expect_result false false

scenario "the three file names anywhere but the root, and folders that only end alike, are not the root's"
changes product/package.json product/pnpm-lock.yaml product/apps/web/page.tsx product/factory/notes.md package.json.md
decide
expect_result false false

scenario "a change that changes no file runs neither"
changes
decide
expect_status 0
expect_result false false

scenario "a file moved out of the app is a change to the app: the app lost it"
changes apps/web/moved.tsx:product/page.md
decide
expect_result true false
expect_output "apps/web/moved.tsx"

scenario "a file moved into the factory is a change to the factory"
changes product/moved.md:factory/notes.md
decide
expect_result false true

scenario "everything runs when the commit of main is not in the checkout, and it says why"
changes factory/scripts/ship.sh
decide 1234567890123456789012345678901234567890
expect_status 0
expect_result true true
expect_output "Could not read the files changed since 1234567890123456789012345678901234567890 from git"

scenario "everything runs in a checkout with no history, where main's commit cannot be named"
git init --quiet .
echo first > README.md
git add . && git commit --quiet -m only
decide
expect_status 0
expect_result true true

scenario "everything runs when git fails part-way, whatever it had listed by then"
changes CLAUDE.md
stub git 'echo CLAUDE.md; echo "fatal: unable to read tree" >&2; exit 128'
decide
expect_status 0
expect_result true true

scenario "everything runs outside a git repository"
decide
expect_status 0
expect_result true true

scenario "it compares the commit it was given with the checkout, each moved file under both names"
changes CLAUDE.md
stub git 'echo CLAUDE.md'
decide abc123
expect_call "git -c core.quotePath=false diff --name-only --no-renames abc123 HEAD"
expect_result false false

scenario "stops when it is given no commit"
run "$scripts/checks-needed.sh"
expect_failure
expect_output "Usage: checks-needed.sh <commit-of-main>"

scenario "what the app is built from is the same list as needs-e2e.sh has"
e2e=$(sed -n "s/^app='^(\(.*\))'$/\1/p" "$scripts/needs-e2e.sh")
both=$(sed -n "s/^both='\(.*\)'$/\1/p" "$scripts/checks-needed.sh")
[ -n "$e2e" ] && [ "$e2e" = "apps/|packages/|$both" ] || fail "expected needs-e2e.sh to list apps/, packages/ and \"$both\", got \"$e2e\""
grep -qxF 'app="^(apps/|packages/|\.github/actions/|$both)"' "$scripts/checks-needed.sh" || fail "checks-needed.sh no longer lists apps/, packages/, the shared actions and the root's three files as the app"

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
condition() { job "$1" | grep -B1 -xF -- "        run: $2" | sed -n 's/^      - if: //p'; }

scenario "ci.yml asks it in checks, before any check it decides, and lint runs whatever it says"
for asking in checks; do
  checks_needed_line=$(job "$asking" | grep -n 'run: factory/scripts/checks-needed.sh' | cut -d: -f1)
  [ -n "$checks_needed_line" ] || { fail "the $asking job does not ask checks-needed.sh"; continue; }
  job "$asking" | grep -F 'run: factory/scripts/checks-needed.sh' | grep -qF '>> "$GITHUB_OUTPUT"' \
    || fail "the $asking job does not write the answer to the step's outputs"
  for check in "pnpm typecheck" "pnpm -r test" "pnpm build"; do
    [ "$(condition "$asking" "$check")" = "steps.needed.outputs.app != 'false'" ] \
      || fail "expected \"$check\" in $asking to run on anything but a plain app=false, got: $(condition "$asking" "$check")"
  done
  [ "$(condition "$asking" "factory/scripts/test-factory.sh HEAD^1")" = "steps.needed.outputs.factory != 'false'" ] \
    || fail "expected the factory's tests in $asking to run on anything but a plain factory=false"
  job "$asking" | grep -qxF '      - run: pnpm lint' || fail "expected $asking to run pnpm lint with no condition"
  for check in "pnpm typecheck" "factory/scripts/test-factory.sh HEAD^1" "pnpm -r test" "pnpm build"; do
    at=$(job "$asking" | grep -n -xF -- "        run: $check" | cut -d: -f1)
    [ -n "$at" ] && [ "$at" -gt "$checks_needed_line" ] || fail "expected \"$check\" in $asking after the step that asks"
  done
  # `pnpm test` whole would run both halves whatever the answer.
  ! job "$asking" | grep -qE 'run: pnpm test$' || fail "expected $asking to run the two halves of pnpm test apart"
done

scenario "ci.yml gives it, and the factory's tests, main's commit: the first parent of the merge commit checks runs on"
job checks | grep -qxF '        run: factory/scripts/checks-needed.sh HEAD^1 >> "$GITHUB_OUTPUT"' \
  || fail "expected checks to compare with the first parent of GitHub's merge commit"
# With no commit test-factory.sh runs every test file, whatever changed (decisions H429a).
job checks | grep -qxF '        run: factory/scripts/test-factory.sh HEAD^1' \
  || fail "expected the factory's tests in checks to be given the first parent of GitHub's merge commit"
# Without the parents in the checkout the comparison fails and every check runs, every time.
job checks | grep -A2 -xF '      - uses: actions/checkout@v4' | grep -qxF '          fetch-depth: 2' \
  || fail "expected the checkout of checks to fetch the merge commit's parents"

scenario "the two halves ci.yml runs are the whole of pnpm test"
[ "$(jq -r .scripts.test "$root/package.json")" = "factory/scripts/test-factory.sh && pnpm -r test" ] \
  || fail "pnpm test is no longer test-factory.sh and pnpm -r test, the two steps ci.yml runs in its place"
