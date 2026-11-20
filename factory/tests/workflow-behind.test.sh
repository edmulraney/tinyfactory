#!/usr/bin/env bash
# Tests for workflow-behind.sh: whether its run uses a workflow file main no longer holds (decisions A142c).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

in_ci="GITHUB_WORKFLOW_REF=owner/myapp/.github/workflows/ci.yml@refs/pull/7/merge"

# a_run: GitHub ran the workflow from the commit $ran, and serves any commit by its id, as a local repo does only when told.
a_run() {
  git init --quiet --initial-branch=main "$T/origin"
  git -C "$T/origin" config uploadpack.allowAnySHA1InWant true
  mkdir -p "$T/origin/.github/workflows"
  echo "name: ci" > "$T/origin/.github/workflows/ci.yml"
  echo "name: fix" > "$T/origin/.github/workflows/fix.yml"
  git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "the workflows"
  ran=$(git -C "$T/origin" rev-parse HEAD)
}
# on_main <file> <contents>: an install lands on main after the run began.
on_main() {
  echo "$2" > "$T/origin/.github/workflows/$1"
  git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "ci: install $1"
}
# behind: from a checkout of the base as it is now, as the review job has (decisions A427e).
behind() {
  [ -d "$T/work/.git" ] || git clone --quiet "$T/origin" "$T/work"
  run env GITHUB_WORKFLOW_SHA="$ran" "$@" "$scripts/workflow-behind.sh"
}

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

scenario "prints the sentence when main holds a ci.yml merged and not installed yet, and nothing once it is installed"
a_run
mkdir -p "$T/origin/factory/workflows"; echo "name: ci, changed" > "$T/origin/factory/workflows/ci.yml"
git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "the change merged"
ran=$(git -C "$T/origin" rev-parse HEAD)
behind "$in_ci"
expect_status 0
expect_output ".github/workflows/ci.yml on main is about to be installed from factory/workflows/ci.yml: this run uses the workflow from before the install. Merge main into the branch and push"
on_main ci.yml "name: ci, changed"
ran=$(git -C "$T/origin" rev-parse HEAD)
behind "$in_ci"
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

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

scenario "when the commit the run came from cannot be read it prints no sentence, says why, and does not fail"
a_run; on_main ci.yml "name: ci, changed"
for sha in "" 0123456789012345678901234567890123456789; do
  behind "$in_ci" GITHUB_WORKFLOW_SHA="$sha"
  expect_status 0
  expect_output "the commit this run's .github/workflows/ci.yml came from could not be read, so whether it is the one main holds is not known"
  expect_no_output "this run uses the workflow from before the install"
done

scenario "when the base cannot be read it prints no sentence, says why, and does not fail: its caller asks for a person"
a_run; on_main ci.yml "name: ci, changed"
git clone --quiet "$T/origin" "$T/work"
git config remote.origin.fetch "+refs/heads/gone:refs/remotes/origin/gone"
behind "$in_ci" GITHUB_BASE_REF=gone
expect_status 0
expect_output "gone could not be read, so whether this run's .github/workflows/ci.yml is the one gone holds is not known"
expect_no_output "this run uses the workflow from before the install"
only=$(env "$in_ci" GITHUB_WORKFLOW_SHA="$ran" GITHUB_BASE_REF=gone "$scripts/workflow-behind.sh" 2>/dev/null)
[ -z "$only" ] || fail "expected nothing on its standard output, which is all its caller reads"

# The review job's checkout keeps no token (decisions A541d); a local origin never asks for one, so only the words are checked.
scenario "git is given the caller's token when GitHub asks for one, as the review job's own fetch is"
# shellcheck disable=SC2016
helper='git -c credential.helper= -c credential.helper='"'"'!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'"'"' fetch --quiet origin'
grep -qF "$helper" "$scripts/workflow-behind.sh" || fail "expected workflow-behind.sh to fetch with a helper that answers with GH_TOKEN"
grep -qF "$helper" "$root/factory/workflows/ci.yml" || fail "expected the review job to fetch the pull request's commit the same way"

