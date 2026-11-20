#!/usr/bin/env bash
# Tests for check-inventory.sh: unowned files, and a workflow behind its install (decisions H106, W102a, W134a, W134b).
. "$(dirname "$0")/helpers.sh"

# $T/installer holds the install, ready to be pushed.
merged_not_installed() {
  git init -q --bare -b main "$T/origin"
  git clone -q "$T/origin" . 2>/dev/null
  git checkout -q -b main
  mkdir -p .claude/skills/bootstrap/templates factory/workflows .github/workflows
  : > .claude/skills/bootstrap/templates/.gitkeep
  echo factory/workflows > .claude/skills/bootstrap/manifest.txt
  echo old > factory/workflows/ci.yml
  echo old > .github/workflows/ci.yml
  git add . && git commit -q -m "installed"
  echo new > factory/workflows/ci.yml
  git commit -q -am "merge a workflow change"
  git push -q origin main
  git clone -q "$T/origin" "$T/installer"
  cp "$T/installer/factory/workflows/ci.yml" "$T/installer/.github/workflows/ci.yml"
  git -C "$T/installer" commit -q -am "install it"
}
change_the_workflow() {
  git checkout -q -b change
  echo newer > factory/workflows/ci.yml
  git commit -q -am "change the workflow again"
}
install_arrives='git -C "$T/installer" push -q origin main'
# GitHub's merge of the current branch with main as it is now, with no history, in $T/checkout.
checks_checkout() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  git checkout -q -b merged main
  git merge -q --no-ff -m "merge the pull request with main" "$branch"
  git push -q origin merged
  git clone -q --depth=1 --branch merged "file://$T/origin" "$T/checkout"
  cd "$T/checkout" || exit 1
}
change_something_else() {
  git checkout -q -b change
  echo ours > README.md
  git add . && git commit -q -m "change something else"
}
edited=".github/workflows/ci.yml was edited directly. Undo that and change factory/workflows/ci.yml: the installer copies it in once that merges."
behind="this checkout is one install behind main, where .github/workflows/ci.yml now matches its source: nothing was edited"
stale=".github/workflows/ci.yml is an install behind main, where it now matches its source. Nothing was edited, but this run uses the workflow from before the install. Merge main into the branch and push, which starts a run with the workflow main holds: git fetch origin main && git merge origin/main"
in_ci="GITHUB_WORKFLOW_REF=owner/myapp/.github/workflows/ci.yml@refs/pull/7/merge"
in_another="GITHUB_WORKFLOW_REF=owner/myapp/.github/workflows/deploy.yml@refs/pull/7/merge"
already_differs="factory/workflows/ci.yml on main already differs from .github/workflows/ci.yml, so a change on top of it could not be installed."
not_installed=".github/workflows/ci.yml is not what factory/workflows/ci.yml says, on main as well as here: a merged change was not installed."

# It has no remote, so a run that reads main fails.
all_owned() {
  git init -q -b main .
  mkdir -p .claude/skills/bootstrap/templates factory/scripts factory/workflows .github/workflows docs
  printf '# What new projects receive\n\nfactory/scripts\nfactory/workflows\n' > .claude/skills/bootstrap/manifest.txt
  echo seed > .claude/skills/bootstrap/templates/TASTE.md
  echo ours > TASTE.md
  echo ours > PURPOSE.md
  echo ours > README.md
  echo ours > LEARNINGS.md
  # A Markdown file below the root is not this check's business.
  echo ours > docs/guide.md
  echo ours > factory/scripts/ship.sh
  echo same > factory/workflows/ci.yml
  echo same > .github/workflows/ci.yml
  git add . && git commit -q -m "everything owned"
}

scenario "fails a file in factory/ that the manifest does not list, and names it"
all_owned
echo plan > factory/plan.md
# A folder whose name only starts like a listed one is not covered by it.
mkdir factory/scripts-old
echo old > factory/scripts-old/ship.sh
# A benchmark case is owned by name (decisions H345); a note beside it is not a case.
mkdir factory/benchmark
echo '{}' > factory/benchmark/7.json
echo note > factory/benchmark/notes.md
git add .
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "These files have no owner."
expect_output "factory/plan.md"
expect_output "factory/benchmark/notes.md"
expect_no_output "factory/benchmark/7.json"
expect_output "factory/scripts-old/ship.sh"
expect_no_output "factory/scripts/ship.sh"
expect_no_output "factory/workflows/ci.yml"
expect_no_output "inventory ok"

scenario "fails a Markdown file at the repo root that is not a seed, PURPOSE.md, README.md or LEARNINGS.md, and names it"
all_owned
echo notes > NOTES.md
git add .
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "These files have no owner."
expect_output "NOTES.md"
expect_no_output "TASTE.md"
expect_no_output "PURPOSE.md"
expect_no_output "README.md"
expect_no_output "LEARNINGS.md"
expect_no_output "docs/guide.md"
expect_no_output "inventory ok"

scenario "passes an installed workflow that matches its source without reading main"
all_owned
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "inventory ok"
expect_no_output "could not be read"
expect_no_output "installed once this change merges"
expect_no_call "sleep"

scenario "lets through a source new to the branch, with no installed copy yet, as waiting to be installed"
merged_not_installed
git -C "$T/installer" push -q origin main
git pull -q origin main
git checkout -q -b change
echo new > factory/workflows/deploy.yml
git add . && git commit -q -m "add a workflow"
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed once this change merges: factory/workflows/deploy.yml"
expect_output "inventory ok"
expect_no_output "ci.yml"
expect_no_call "sleep"

scenario "stops with a message outside a git repository: that is not a repo with no stray file"
mkdir -p .claude/skills/bootstrap/templates factory/scripts
echo factory/scripts > .claude/skills/bootstrap/manifest.txt
: > factory/plan.txt
: > STATUS.md
# The ceiling keeps git from finding a repository above the scenario, wherever TMPDIR points.
run env GIT_CEILING_DIRECTORIES="$T" "$scripts/check-inventory.sh"
expect_status 1
expect_output "check-inventory.sh must be run inside a git repository"
expect_output "nothing was checked"
expect_no_output "inventory ok"

scenario "passes a workflow change when main differs on the first read and matches on the second"
merged_not_installed
change_the_workflow
stub sleep "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed once this change merges: factory/workflows/ci.yml"
expect_output "inventory ok"
expect_no_output "already differs"
[ "$(grep -c '^sleep 10$' "$T/calls")" = 1 ] || fail "expected one wait of 10 seconds"

scenario "passes a checkout made between a merge and its install once main matches"
merged_not_installed
stub sleep "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed on main since this checkout was made: factory/workflows/ci.yml"
expect_output "inventory ok"
expect_no_output "was not installed"

scenario "passes when the install arrives on a later read"
merged_not_installed
change_the_workflow
stub sleep '[ "$(grep -c "^sleep" "$T/calls")" -lt 3 ] || '"$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "inventory ok"
[ "$(grep -c '^sleep 10$' "$T/calls")" = 3 ] || fail "expected three waits of 10 seconds"

scenario "passes in a pull request's checkout, which is shallow and holds no main, and fetches no history"
merged_not_installed
change_the_workflow
git push -q origin change
git clone -q --depth=1 --branch change "file://$T/origin" "$T/checkout"
cd "$T/checkout" || exit 1
stub sleep "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed once this change merges: factory/workflows/ci.yml"
expect_output "inventory ok"
[ "$(git rev-list --count FETCH_HEAD)" = 1 ] || fail "expected only main's last commit to be fetched"

scenario "fails a workflow change with the same message when main differs on every read, and says how long it waited"
merged_not_installed
change_the_workflow
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$already_differs"
expect_output "read main again every 10 seconds for 120 seconds"
expect_no_output "inventory ok"
[ "$(grep -c '^sleep 10$' "$T/calls")" = 12 ] || fail "expected twelve waits of 10 seconds, which is the 120 it says"

scenario "fails a change that was never installed after the same wait"
merged_not_installed
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$not_installed"
expect_output "read main again every 10 seconds for 120 seconds"
[ "$(grep -c '^sleep 10$' "$T/calls")" = 12 ] || fail "expected twelve waits of 10 seconds"

scenario "stops with a message when main cannot be read again"
merged_not_installed
change_the_workflow
stub sleep 'rm -rf "$T/origin"'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "main could not be read again to tell whether the install had arrived"
expect_output "ci.yml"
expect_no_output "already differs"
expect_no_output "inventory ok"
[ "$(grep -c '^sleep' "$T/calls")" = 1 ] || fail "expected it to stop at the first failed read"

scenario "does not wait for a workflow change whose source and installed copy match on main"
merged_not_installed
git -C "$T/installer" push -q origin main
git pull -q origin main
change_the_workflow
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed once this change merges: factory/workflows/ci.yml"
expect_no_call "sleep"

scenario "does not wait before failing an installed copy that was edited directly"
merged_not_installed
git -C "$T/installer" push -q origin main
git pull -q origin main
echo edited > .github/workflows/ci.yml
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output ".github/workflows/ci.yml was edited directly."
expect_no_call "sleep"

scenario "stops with a message, without waiting, when main cannot be read the first time"
merged_not_installed
change_the_workflow
git push -q origin change
git clone -q --depth=1 --branch change "file://$T/origin" "$T/checkout"
cd "$T/checkout" || exit 1
rm -rf "$T/origin"
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "main could not be read to tell whether the change waits to be installed"
expect_no_output "inventory ok"
expect_no_call "sleep"

scenario "passes a checkout made before an install that main holds by the time main is read, and says it is one install behind"
merged_not_installed
change_something_else
checks_checkout
eval "$install_arrives"
stub sleep 'exit 0'
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "$behind"
expect_output "inventory ok"
expect_no_output "was edited directly"
expect_no_output "installed once this change merges"
expect_no_call "sleep"

scenario "one install behind, a change to the same workflow is still one to install once it merges"
merged_not_installed
change_the_workflow
checks_checkout
eval "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "$behind"
expect_output "installed once this change merges: factory/workflows/ci.yml"
expect_output "inventory ok"

scenario "one install behind: still fails an installed copy that differs from both its source and main"
merged_not_installed
change_something_else
echo edited > .github/workflows/ci.yml
git commit -q -am "edit the installed copy"
checks_checkout
eval "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$edited"
expect_no_output "one install behind"
expect_no_output "inventory ok"

scenario "fails an installed copy put back to what it held before an install: the checkout was made with main as it is"
merged_not_installed
eval "$install_arrives"
git pull -q origin main
change_something_else
echo old > .github/workflows/ci.yml
git commit -q -am "undo the install"
checks_checkout
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$edited"
expect_no_output "one install behind"

scenario "fails an edit in a shallow checkout whose parent is not a commit of main"
merged_not_installed
eval "$install_arrives"
git pull -q origin main
change_something_else
echo old > .github/workflows/ci.yml
git commit -q -am "undo the install"
echo more > README.md
git commit -q -am "one more commit"
git push -q origin change
# Two commits deep, so that the parent can be read: it holds the edit, and is not main's.
git clone -q --depth=2 --branch change "file://$T/origin" "$T/checkout"
cd "$T/checkout" || exit 1
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$edited"
expect_no_output "one install behind"

scenario "fails as edited a checkout made with a main older than its last twenty commits"
merged_not_installed
change_something_else
checks_checkout
for n in $(seq 20); do git -C "$T/installer" commit -q --allow-empty -m "later commit $n"; done
eval "$install_arrives"
run "$scripts/check-inventory.sh"
expect_status 1
expect_output "$edited"
expect_no_output "one install behind"

scenario "stops with a message when main's last commits cannot be read to tell an install from an edit"
merged_not_installed
change_something_else
checks_checkout
eval "$install_arrives"
git=$(command -v git)
stub git 'case "$*" in *"--depth=20"*) exit 1 ;; esac; exec "'"$git"'" "$@"'
run "$scripts/check-inventory.sh"
expect_status 1
expect_output ".github/workflows/ci.yml differs from what main holds, and the last 20 commits of main could not be read to tell an install that landed after this checkout was made from an edit."
expect_no_output "was edited directly"
expect_no_output "one install behind"
expect_no_output "inventory ok"

scenario "fails a checkout one install behind in the workflow running the check: only a push starts a run with the workflow main holds"
merged_not_installed
change_something_else
checks_checkout
eval "$install_arrives"
stub sleep 'exit 0'
run env "$in_ci" "$scripts/check-inventory.sh"
expect_status 1
expect_output "$stale"
expect_no_output "this checkout is one install behind"
expect_no_output "was edited directly"
expect_no_output "inventory ok"
expect_no_call "sleep"

scenario "the same for a change to that workflow, and it is not said to wait to be installed"
merged_not_installed
change_the_workflow
checks_checkout
eval "$install_arrives"
run env "$in_ci" "$scripts/check-inventory.sh"
expect_status 1
expect_output "$stale"
expect_no_output "installed once this change merges"
expect_no_output "inventory ok"

scenario "passes a checkout one install behind in a workflow other than the one running the check"
merged_not_installed
change_something_else
checks_checkout
eval "$install_arrives"
run env "$in_another" "$scripts/check-inventory.sh"
expect_status 0
expect_output "$behind"
expect_output "inventory ok"

scenario "passes a checkout one install behind when main's commits are listed slower than they are read"
merged_not_installed
change_something_else
checks_checkout
eval "$install_arrives"
git=$(command -v git)
# A reader that stops at the commit it wanted closes the pipe on a list still being written (decisions W187).
stub git 'case "$1" in rev-list) "'"$git"'" "$@" | while IFS= read -r commit; do echo "$commit"; sleep 0.2; done; exit ;; esac; exec "'"$git"'" "$@"'
run "$scripts/check-inventory.sh"
expect_status 0
expect_output "$behind"
expect_output "inventory ok"

scenario "fails when the install that arrives during the wait is of the workflow running the check"
merged_not_installed
change_something_else
checks_checkout
stub sleep "$install_arrives"
run env "$in_ci" "$scripts/check-inventory.sh"
expect_status 1
expect_output "$stale"
expect_no_output "installed on main since this checkout was made"
expect_no_output "still differ"
expect_no_output "inventory ok"
[ "$(grep -c '^sleep 10$' "$T/calls")" = 1 ] || fail "expected one wait of 10 seconds"

scenario "passes when the install that arrives during the wait is of another workflow"
merged_not_installed
change_something_else
checks_checkout
stub sleep "$install_arrives"
run env "$in_another" "$scripts/check-inventory.sh"
expect_status 0
expect_output "installed on main since this checkout was made: factory/workflows/ci.yml"
expect_output "inventory ok"

scenario "in the workflow running the check, an edited copy is still called edited"
merged_not_installed
change_something_else
echo edited > .github/workflows/ci.yml
git commit -q -am "edit the installed copy"
checks_checkout
eval "$install_arrives"
run env "$in_ci" "$scripts/check-inventory.sh"
expect_status 1
expect_output "$edited"
expect_no_output "an install behind"

scenario "passes in the workflow running the check when main's source is put back during the wait: this run's copy is main's"
merged_not_installed
change_something_else
checks_checkout
git -C "$T/installer" reset -q --hard HEAD~1
echo old > "$T/installer/factory/workflows/ci.yml"
git -C "$T/installer" commit -q -am "put the source back"
stub sleep "$install_arrives"
run env "$in_ci" "$scripts/check-inventory.sh"
expect_status 0
expect_output "inventory ok"
expect_no_output "an install behind"
