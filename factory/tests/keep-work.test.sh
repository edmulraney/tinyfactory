#!/usr/bin/env bash
# Tests for keep-work.sh: what a cut-short session left is committed as work in progress and pushed to its branch.
. "$(dirname "$0")/helpers.sh"

# The address the script pushes to is rewritten to $T/github.git, so the real git reaches no network.
a_build() {
  export GH_TOKEN=token GITHUB_REPOSITORY=owner/repo
  git init -q --bare -b main "$T/github.git"
  git init -q -b main "$T/seed"
  echo "# myapp" > "$T/seed/README.md"
  echo "node_modules" > "$T/seed/.gitignore"
  git -C "$T/seed" add -A
  git -C "$T/seed" commit -q -m "chore: start"
  git -C "$T/seed" push -q "$T/github.git" main
  git clone -q "$T/github.git" .
  git config "url.$T/github.git.insteadOf" "https://x-access-token:token@github.com/owner/repo.git"
  git checkout -q -b feat/12-export-forecast-csv
}
on_github() { git -C "$T/github.git" "$@"; }

scenario "uncommitted work is committed as work in progress and pushed to the ticket's branch"
a_build
echo "export" > export.ts
echo "# myapp, with export" > README.md
run "$scripts/keep-work.sh" "issue #12"
expect_status 0
[ "$(tail -n 1 <<<"$out")" = feat/12-export-forecast-csv ] || fail "expected it to print the branch"
[ "$(on_github show feat/12-export-forecast-csv:export.ts 2>&1)" = export ] || fail "expected the new file on GitHub"
[ "$(on_github show feat/12-export-forecast-csv:README.md 2>&1)" = "# myapp, with export" ] || fail "expected the changed file on GitHub"
[ "$(on_github log -1 --format=%s feat/12-export-forecast-csv)" = "chore: keep the unfinished work on issue #12" ] || fail "expected the commit to say it is unfinished work"
[ "$(on_github log -1 --format=%an feat/12-export-forecast-csv)" = "github-actions[bot]" ] || fail "expected the commit to be the workflow's, not the engineer's"

scenario "prints the branch alone on its first stream, so a workflow can read it"
a_build
echo "export" > export.ts
branch=$("$scripts/keep-work.sh" "issue #12" 2>/dev/null); status=$?; out=$branch
expect_status 0
[ "$branch" = feat/12-export-forecast-csv ] || fail "expected exactly the branch"

scenario "commits the engineer made and never pushed are pushed as they are, with no commit added"
a_build
echo "export" > export.ts
git add -A && git commit -q -m "feat: export forecast as CSV"
run "$scripts/keep-work.sh" "issue #12"
expect_status 0
[ "$(tail -n 1 <<<"$out")" = feat/12-export-forecast-csv ] || fail "expected it to print the branch"
[ "$(on_github log -1 --format=%s feat/12-export-forecast-csv)" = "feat: export forecast as CSV" ] || fail "expected the engineer's own commit to be the last"

scenario "work on top of commits already pushed is kept too"
a_build
echo "export" > export.ts
git add -A && git commit -q -m "feat: export forecast as CSV"
git push -q origin feat/12-export-forecast-csv
echo "more" >> export.ts
run "$scripts/keep-work.sh" "issue #12"
expect_status 0
[ "$(on_github log --format=%s feat/12-export-forecast-csv | head -n 2 | tr '\n' '|')" = "chore: keep the unfinished work on issue #12|feat: export forecast as CSV|" ] \
  || fail "expected the work in progress on top of the pushed commit"

scenario "work the engineer had already pushed is named and left as it is: cut short between the push and the pull request"
a_build
echo "export" > export.ts
git add -A && git commit -q -m "feat: export forecast as CSV"
git push -q origin feat/12-export-forecast-csv
before=$(on_github rev-parse feat/12-export-forecast-csv)
branch=$("$scripts/keep-work.sh" "issue #12" 2>"$T/said"); status=$?; out="$branch$(cat "$T/said")"
expect_status 0
[ "$branch" = feat/12-export-forecast-csv ] || fail "expected it to print the branch that holds the work"
expect_output "everything the engineer had is already on GitHub"
[ "$(on_github rev-parse feat/12-export-forecast-csv)" = "$before" ] || fail "expected the branch on GitHub to be left alone"
[ "$(git rev-parse HEAD)" = "$before" ] || fail "expected no commit to be added"

scenario "keeps nothing when the engineer had only made the branch"
a_build
branch=$("$scripts/keep-work.sh" "issue #12" 2>"$T/said"); status=$?; out="$branch$(cat "$T/said")"
expect_status 0
[ -z "$branch" ] || fail "expected it to print no branch"
expect_output "nothing kept: the branch holds nothing that is not already on GitHub"
[ -z "$(on_github branch --list 'feat/*')" ] || fail "expected no branch on GitHub"

scenario "never commits to or pushes main: work done before a branch existed is left where it is"
a_build
git checkout -q main
echo "export" > export.ts
before=$(on_github rev-parse main)
branch=$("$scripts/keep-work.sh" "issue #12" 2>"$T/said"); status=$?; out="$branch$(cat "$T/said")"
expect_status 0
[ -z "$branch" ] || fail "expected it to print no branch"
expect_output "nothing kept: the engineer had not started a branch"
[ "$(on_github rev-parse main)" = "$before" ] || fail "expected main on GitHub to be left alone"
[ "$(git rev-parse HEAD)" = "$before" ] || fail "expected no commit on main in the checkout"
[ "$(on_github for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" = "main " ] || fail "expected GitHub to hold main and nothing else"

scenario "keeps nothing from a checkout that is on no branch, as a fix round's is before the engineer checks out"
a_build
git checkout -q --detach
echo "export" > export.ts
run "$scripts/keep-work.sh" "pull request #7"
expect_status 0
expect_output "nothing kept: the engineer had not started a branch"
[ "$(on_github for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" = "main " ] || fail "expected GitHub to hold main and nothing else"

scenario "pushes the one branch and no other"
a_build
git branch chore/99-something-else
echo "export" > export.ts
run "$scripts/keep-work.sh" "issue #12"
expect_status 0
[ "$(on_github for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" = "feat/12-export-forecast-csv main " ] || fail "expected GitHub to hold main and the ticket's branch only"

scenario "what git ignores is not kept"
a_build
mkdir node_modules && echo "x" > node_modules/x.js
echo "export" > export.ts
run "$scripts/keep-work.sh" "issue #12"
expect_status 0
[ "$(on_github ls-tree -r --name-only feat/12-export-forecast-csv | tr '\n' ' ')" = ".gitignore README.md export.ts " ] || fail "expected the ignored folder to be left out"

scenario "a push that fails stops it with a message, and the commit it made is taken back"
a_build
echo "export" > export.ts
git add export.ts
before=$(git rev-parse HEAD)
git config "url.$T/no-such-place.git.insteadOf" "https://x-access-token:token@github.com/owner/repo.git"
git config --unset "url.$T/github.git.insteadOf"
branch=$("$scripts/keep-work.sh" "issue #12" 2>"$T/said"); status=$?; out="$branch$(cat "$T/said")"
expect_status 1
[ -z "$branch" ] || fail "expected it to print no branch: a failed push must not read as kept"
expect_output "could not push feat/12-export-forecast-csv, so the unfinished work was not kept"
[ "$(git rev-parse HEAD)" = "$before" ] || fail "expected the work-in-progress commit to be taken back"
[ "$(cat export.ts)" = export ] || fail "expected the engineer's file to be left in the checkout"

scenario "a branch that moved on GitHub is not overwritten: the push is refused, never forced"
a_build
git -C "$T/seed" checkout -q -b feat/12-export-forecast-csv
echo "someone else" > "$T/seed/other.ts"
git -C "$T/seed" add -A && git -C "$T/seed" commit -q -m "feat: someone else's work"
git -C "$T/seed" push -q "$T/github.git" feat/12-export-forecast-csv
before=$(on_github rev-parse feat/12-export-forecast-csv)
echo "export" > export.ts
run "$scripts/keep-work.sh" "issue #12"
expect_status 1
expect_output "could not push feat/12-export-forecast-csv"
[ "$(on_github rev-parse feat/12-export-forecast-csv)" = "$before" ] || fail "expected the branch on GitHub to be left as it was"

scenario "a failed push of commits the engineer made takes none of them back"
a_build
echo "export" > export.ts
git add -A && git commit -q -m "feat: export forecast as CSV"
before=$(git rev-parse HEAD)
git config "url.$T/no-such-place.git.insteadOf" "https://x-access-token:token@github.com/owner/repo.git"
git config --unset "url.$T/github.git.insteadOf"
run "$scripts/keep-work.sh" "issue #12"
expect_status 1
[ "$(git rev-parse HEAD)" = "$before" ] || fail "expected the engineer's commit to be left alone"
