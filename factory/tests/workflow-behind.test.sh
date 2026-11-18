#!/usr/bin/env bash
# Tests for workflow-behind.sh: whether its run uses a workflow file main no longer holds (decisions A142c).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

in_ci="GITHUB_WORKFLOW_REF=owner/myapp/.github/workflows/ci.yml@refs/pull/7/merge"

a_run() {
  git init --quiet --initial-branch=main "$T/origin"
  mkdir -p "$T/origin/.github/workflows"
  echo "name: ci" > "$T/origin/.github/workflows/ci.yml"
  echo "name: fix" > "$T/origin/.github/workflows/fix.yml"
  git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "the workflows"
  git clone --quiet "$T/origin" "$T/work"
}
# on_main <file> <contents>: an install lands on main after the run's checkout was made.
on_main() {
  echo "$2" > "$T/origin/.github/workflows/$1"
  git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "ci: install $1"
}
behind() { run env "$@" "$scripts/workflow-behind.sh"; }

scenario "prints nothing for a run whose ci.yml is the one main holds"
a_run
behind "$in_ci"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "prints the sentence, and how to get a fresh run, when main's ci.yml has changed since the checkout was made"
a_run; on_main ci.yml "name: ci, changed"
behind "$in_ci"
expect_status 0
[ "$out" = "$review_behind" ] || fail "expected the sentence the fix round's tests use, and nothing else"

scenario "prints nothing when another workflow changed on main: this run's file is still main's"
a_run; on_main fix.yml "name: fix, changed"
behind "$in_ci"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "compares the workflow the run is in, and the branch the pull request merges into"
a_run; on_main fix.yml "name: fix, changed"
git -C "$T/origin" checkout --quiet -b release
on_main ci.yml "name: ci, changed on release"
behind "GITHUB_WORKFLOW_REF=owner/myapp/.github/workflows/fix.yml@refs/heads/main"
expect_output ".github/workflows/fix.yml on main has changed since this run began"
behind "$in_ci" GITHUB_BASE_REF=release
expect_output ".github/workflows/ci.yml on release has changed since this run began"
expect_output "git fetch origin release && git merge origin/release"

scenario "prints the sentence when main no longer holds the workflow at all"
a_run
git -C "$T/origin" rm --quiet .github/workflows/ci.yml && git -C "$T/origin" commit --quiet -m "ci: remove ci.yml"
behind "$in_ci"
expect_output "this run uses the workflow from before the install"

scenario "outside a workflow run it prints no sentence, says why, and does not fail"
a_run; on_main ci.yml "name: ci, changed"
behind GITHUB_BASE_REF=main
expect_status 0
expect_output "not in a workflow run"
expect_no_output "this run uses the workflow from before the install"

scenario "when main cannot be read it prints no sentence, says why, and does not fail: its caller asks for a person"
a_run; on_main ci.yml "name: ci, changed"
git remote set-url origin "$T/nowhere"
behind "$in_ci"
expect_status 0
expect_output "main could not be read, so whether this run's .github/workflows/ci.yml is the one main holds is not known"
expect_no_output "this run uses the workflow from before the install"
only=$(env "$in_ci" "$scripts/workflow-behind.sh" 2>/dev/null)
[ -z "$only" ] || fail "expected nothing on its standard output, which is all its caller reads"
