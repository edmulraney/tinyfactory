#!/usr/bin/env bash
# Tests for begin-group.sh: which pull requests a group holds, with which main, and whether they need a test.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/group-on-github.sh"

export GITHUB_REPOSITORY=repo-owner/myapp

# GitHub around the repo github_repo made. $T/runs/<head> holds the ci runs of a commit, $T/artifacts/<run> those
# of a run, and $T/files-<n> the files a pull request changes; $T/sleep is run at each wait.
github() {
  github_repo
  echo '[]' > "$T/open.json"
  : > "$T/fail"
  mkdir -p "$T/runs" "$T/artifacts"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "workflow run merge-group.yml" | "workflow run merge-group.yml -f try="*) ;;
      "run list --workflow ci.yml --commit "*) json "$(cat "$T/runs/$6" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/"*"/artifacts "*) n=${2#*/runs/}; json "$(cat "$T/artifacts/${n%/artifacts}")" "$@" ;;
      *) queue_on_github "$@" ;;
    esac'
  echo ':' > "$T/sleep"
  stub sleep '. "$T/sleep"'
}
# waits <number>...: each is an open pull request that was added, in that order.
waits() {
  local number
  for number in "$@"; do
    jq --argjson n "$number" --arg head "$(head_of "$number")" '. + [{number: $n, headRefOid: $head, isDraft: false, reviews: []}]' "$T/open.json" > "$T/open.new"
    mv "$T/open.new" "$T/open.json"
    "$scripts/merge-queue.sh" add "$number" "$(head_of "$number")" > /dev/null || fail "pull request #$number could not be added"
  done
  : > "$T/calls"
}
# checks_passed_with <number> <commit of main>: its ci run left the record of that commit (decisions M19).
checks_passed_with() {
  echo '[{"databaseId":900,"status":"completed","conclusion":"success"}]' > "$T/runs/$(head_of "$1")"
  echo "{\"artifacts\":[{\"name\":\"playwright-x\"},{\"name\":\"tested-with-main-$2\"}]}" > "$T/artifacts/900"
}
begin() { run "$scripts/begin-group.sh" "$T/result.json"; }
# What it printed on stdout alone, as the workflow takes it.
written() { "$scripts/begin-group.sh" "$T/result.json" 2>/dev/null; }
expect_written() { grep -qxF -- "$1" <<<"$out" || fail "expected it to write: $1"; }

scenario "with nothing waiting to merge, the group is empty and nothing is tested"
github
begin
expect_status 0
expect_written "group="
expect_written "test=false"
[ ! -e "$T/result.json" ] || fail "expected no result file"

scenario "the group is every pull request that waits, in the order added, with main as it is, and it is tested"
github
pull 7 apps/web/seven.txt; pull 8 apps/web/eight.txt; pull 9 apps/web/nine.txt
waits 8 7 9
begin
expect_status 0
expect_written "main=$main"
expect_written "group=8:$(head_of 8) 7:$(head_of 7) 9:$(head_of 9)"
expect_written "test=true"
[ ! -e "$T/result.json" ] || fail "expected no result file: the test writes it"

scenario "only the three lines reach stdout, which the workflow takes as the job's outputs"
github
pull 7 apps/web/seven.txt
waits 7
[ "$(written | sed 's/=.*//' | tr '\n' ' ')" = "main group test " ] || fail "expected main, group and test alone, got: $(written)"

scenario "a group of one whose own checks passed with main as it is needs no second test: the result says it passed"
github
pull 7 apps/web/seven.txt
waits 7
checks_passed_with 7 "$main"
begin
expect_status 0
expect_written "test=false"
[ "$(jq -c . "$T/result.json")" = "{\"main\":\"$main\",\"tree\":\"\",\"pulls\":[{\"number\":7,\"head\":\"$(head_of 7)\",\"result\":\"passed\"}]}" ] \
  || fail "expected the result to say #7 passed with this main, got: $(cat "$T/result.json")"

scenario "a group of one whose checks passed with an earlier main is tested"
github
pull 7 apps/web/seven.txt
waits 7
checks_passed_with 7 0000000000000000000000000000000000000001
begin
expect_written "test=true"
[ ! -e "$T/result.json" ] || fail "expected no result file"

scenario "a record for a commit that only starts like main is not this main's"
github
pull 7 apps/web/seven.txt
waits 7
checks_passed_with 7 "${main}0"
begin
expect_written "test=true"

scenario "two pull requests are tested together, though the checks of each passed with main as it is"
github
pull 7 apps/web/seven.txt; pull 8 apps/web/eight.txt
waits 7 8
checks_passed_with 7 "$main"
cp "$T/runs/$(head_of 7)" "$T/runs/$(head_of 8)"
begin
expect_written "test=true"

for words in "run list --workflow ci.yml" "api repos/{owner}/{repo}/actions/runs/900/artifacts"; do
  scenario "unsure whether its checks passed with this main, the group of one is tested: gh $words fails"
  github
  pull 7 apps/web/seven.txt
  waits 7
  checks_passed_with 7 "$main"
  echo "$words" > "$T/fail"
  begin
  expect_status 0
  expect_written "test=true"
  [ ! -e "$T/result.json" ] || fail "expected no result file"
done

scenario "a group of one with no ci run for its commit is tested"
github
pull 7 apps/web/seven.txt
waits 7
begin
expect_written "test=true"

scenario "waits for a merged workflow change to be installed, and begins with main as the install left it"
github
pull 7 apps/web/seven.txt
waits 7
(cd "$T/scratch" && git fetch --quiet origin main && git checkout --quiet --detach origin/main && echo "name: ci, changed" > factory/workflows/ci.yml \
  && git commit --quiet -am "feat: change ci (#6)" && git push --quiet origin HEAD:main)
git pull --quiet origin main
# The installer's commit lands during the second wait.
# shellcheck disable=SC2016
echo 'n=$(cat "$T/waits" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/waits"; [ "$n" -ne 1 ] || (cd "$T/scratch" && cp factory/workflows/ci.yml .github/workflows/ci.yml && git commit --quiet -am "ci: install" && git push --quiet origin HEAD:main)' > "$T/sleep"
begin
expect_status 0
installed=$(git --git-dir="$T/origin.git" rev-parse main)
expect_written "main=$installed"
expect_written "test=true"
[ "$(cat "$T/waits")" = 2 ] || fail "expected two waits, got: $(cat "$T/waits")"

scenario "a workflow change still not installed after five minutes: the group is not tested, and the result says why"
github
pull 7 apps/web/seven.txt
waits 7
(cd "$T/scratch" && git fetch --quiet origin main && git checkout --quiet --detach origin/main && echo "name: ci, changed" > factory/workflows/ci.yml \
  && git commit --quiet -am "feat: change ci (#6)" && git push --quiet origin HEAD:main)
git pull --quiet origin main
begin
expect_status 0
expect_calls 30 "sleep 10"
expect_written "group=7:$(head_of 7)"
expect_written "test=false"
[[ "$(jq -r .not_tested "$T/result.json")" == *"holds a workflow change that was not installed five minutes after it merged"* ]] \
  || fail "expected the result to say why the group was not tested, got: $(cat "$T/result.json")"

scenario "fails and begins no group when main cannot be read again while it waits for an install: the merge job starts the run again"
github
(cd "$T/scratch" && git fetch --quiet origin main && git checkout --quiet --detach origin/main && echo "name: ci, changed" > factory/workflows/ci.yml \
  && git commit --quiet -am "feat: change ci (#6)" && git push --quiet origin HEAD:main)
git pull --quiet origin main
git remote set-url origin "$T/no-such-repo.git"
begin
expect_failure
expect_output "main could not be read again from GitHub"
expect_no_output "group="
expect_no_call "gh workflow run"

scenario "asks six times which pull requests wait, then fails and begins no group"
github
pull 7 apps/web/seven.txt
waits 7
: > "$T/calls"
echo "pr list" > "$T/fail"
begin
expect_failure
expect_calls 6 "gh pr list"
expect_output "No group was begun."
expect_no_output "group="
expect_no_call "gh workflow run"
expect_no_call "gh pr comment"
