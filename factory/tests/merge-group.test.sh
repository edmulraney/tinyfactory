#!/usr/bin/env bash
# Tests for a run of merge-group.yml: its three scripts in turn, on pull requests GitHub merges for real.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"
. "$(dirname "$0")/group-on-github.sh"

export GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/
workflow="$root/factory/workflows/merge-group.yml"

# GitHub as ready_to_ship has it around pull requests #7, #8 and #9, with the repo github_repo made: a merge is
# made there, main and its commits are read from there, and production runs what main holds.
github() {
  ready_to_ship
  also_ships 8 13
  also_ships 9 14
  github_repo
  echo '[]' > "$T/open.json"
  mv "$T/bin/gh" "$T/bin/gh-around-the-repo"
  stub gh '
    origin="$T/origin.git"
    case "$*" in
      "pr merge "*" --squash --delete-branch --match-head-commit "*)
        [ "$(head_of "$3")" = "$7" ] || { echo "gh: Head branch was modified. Review and try the merge again." >&2; exit 1; }
        # $T/refused holds the pull requests whose merge GitHub fails whatever they hold.
        ! grep -qx "$3" "$T/refused" 2>/dev/null || { echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; }
        merge_on_github "$3" || { echo "gh: Pull Request is not mergeable" >&2; exit 1; }
        jq --argjson n "$3" "map(select(.number != \$n))" "$T/open.json" > "$T/open.new" && mv "$T/open.new" "$T/open.json" ;;
      # $T/forks holds the pull requests whose branch is in another repository.
      "pr view "*" --json headRefName,isCrossRepository "*) echo "$(grep -qx "$3" "$T/forks" 2>/dev/null && echo true || echo false) pr-$3" ;;
      "pr view "*" --json mergeCommit "*) git --git-dir="$origin" log --format="%H %s" main | sed -n "s/ .* (#$3)\$//p" ;;
      "api repos/{owner}/{repo}/commits/main --jq .sha") git --git-dir="$origin" rev-parse main ;;
      "api repos/{owner}/{repo}/commits?sha=main&per_page=30 "*)
        commits=$(git --git-dir="$origin" log --format="%H %s" main | jq -R "{sha: .[0:40]} + {commit: {message: .[41:]}}" | jq -s .)
        json "$commits" "$@" ;;
      "api repos/{owner}/{repo}/commits/"*" --jq .commit.tree.sha") git --git-dir="$origin" rev-parse "${2##*/}^{tree}" ;;
      "pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews "*)
        # GitHub lists each at the commit its branch holds now.
        for n in $(jq -r ".[].number" "$T/open.json"); do
          jq --argjson n "$n" --arg head "$(head_of "$n")" "map(if .number == \$n then .headRefOid = \$head else . end)" "$T/open.json" > "$T/open.new" && mv "$T/open.new" "$T/open.json"
        done
        queue_on_github "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "* | "pr comment "*" --body "*) queue_on_github "$@" ;;
      # The stand-in it hands to records the call a second time.
      *) sed -i.last "\$d" "$T/calls" && rm "$T/calls.last"; exec "$T/bin/gh-around-the-repo" "$@" ;;
    esac'
  stub curl 'echo "{\"commit\":\"$(git --git-dir="$T/origin.git" rev-parse main)\"}"'
  export -f merge_on_github head_of
}
# approved <number>...: each passed its checks and reviews and was approved, in that order, so each waits to merge.
approved() {
  local number
  for number in "$@"; do
    jq --argjson n "$number" --arg head "$(head_of "$number")" '. + [{number: $n, headRefOid: $head, isDraft: false, reviews: []}]' "$T/open.json" > "$T/open.new"
    mv "$T/open.new" "$T/open.json"
    run "$scripts/merge-queue.sh" add "$number" "$(head_of "$number")"
    [ "$status" = 0 ] || fail "pull request #$number could not be added"
  done
}
# The three jobs of the workflow. Each makes its own checkout of main, and the first says what the others get.
checkout() { git fetch --quiet origin main && git checkout --quiet --detach FETCH_HEAD || fail "main could not be checked out"; }
begin() {
  checkout
  rm -f "$T/result.json"
  begun=$("$scripts/begin-group.sh" "$T/result.json" 2>/dev/null) || fail "begin-group.sh failed"
  group=$(sed -n 's/^group=//p' <<<"$begun")
  needs_test=$(sed -n 's/^test=//p' <<<"$begun")
}
# shellcheck disable=SC2086
test_it() { checkout; run "$scripts/test-group.sh" "$T/result.json" $group; }
# The merge job's checkout holds one commit of main, as actions/checkout leaves it.
ship_it() {
  rm -rf "$T/merge-job"
  git clone --quiet --depth 1 "file://$T/origin.git" "$T/merge-job" 2>/dev/null || fail "the merge job could not check main out"
  cd "$T/merge-job" || exit 1
  # shellcheck disable=SC2086
  run "$scripts/ship.sh" "$T/result.json" $group
  cd "$T/work" || exit 1
}
# on_main <file>: the file as main holds it on GitHub.
on_main() { git --git-dir="$T/origin.git" show "main:$1"; }
merges() { grep -o '^gh pr merge [0-9]*' "$T/calls" | sed 's/.* //' | tr '\n' ' '; }
# shellcheck disable=SC2016
broken='[ ! -e apps/web/broken ] || { echo "lint: apps/web/broken is not allowed"; exit 1; }'

scenario "three approved pull requests that fit together: the checks run once, they merge in the order approved, and main holds what was tested"
github
pull 7 apps/web/seven.txt; pull 8 apps/web/eight.txt; pull 9 apps/web/nine.txt
approved 8 7 9
begin
[ "$group" = "8:$(head_of 8) 7:$(head_of 7) 9:$(head_of 9)" ] || fail "expected the group in the order approved, got: $group"
[ "$needs_test" = true ] || fail "expected the group to be tested"
test_it
expect_status 0
ship_it
expect_status 0
expect_calls 1 "pnpm lint"
[ "$(merges)" = "8 7 9 " ] || fail "expected #8, #7, #9 to merge in that order, got: $(merges)"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree that was tested"
expect_call "gh api repos/{owner}/{repo}/commits/$(git --git-dir="$T/origin.git" rev-parse main) --jq .commit.tree.sha"
expect_no_call "does not hold what was tested"
for file in seven eight nine; do
  git --git-dir="$T/origin.git" cat-file -e "main:apps/web/$file.txt" 2>/dev/null || fail "expected main to hold apps/web/$file.txt"
done
# No pull request is tested with main a second time, or told that main moved.
expect_no_call "has moved"
expect_no_call "gh run rerun"
for ticket in 12 13 14; do expect_call "gh issue edit $ticket --add-label deployed"; done

scenario "one of three conflicts: it is left out and gets one fix round for the conflict, and the other two merge"
github
pull 7 apps/web/page.txt "seven's page"; pull 8 apps/web/page.txt "eight's page"; pull 9 apps/web/nine.txt
approved 7 8 9
begin
test_it
ship_it
expect_status 0
expect_calls 1 "pnpm lint"
[ "$(merges)" = "7 9 " ] || fail "expected #7 and #9 to merge, got: $(merges)"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree that was tested"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $(head_of 8) -->Not merged: it does not fit \`main\` with the pull requests merged before it."
expect_calls 1 "gh workflow run fix.yml -f pr=8"
# Its fix round is given the files in conflict.
run "$scripts/merge-queue.sh" removed 8 "$(head_of 8)"
expect_output "apps/web/page.txt"
# It waits no longer: the next group does not test it again as it is.
begin
[ -z "$group" ] || fail "expected nothing to wait to merge, got: $group"

scenario "two pull requests each add a row to one table of a marked file: both merge in one group, both rows are there, and no fix round starts"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
approved 7 8
before=$(head_of 8)
begin
test_it
expect_status 0
ship_it
expect_status 0
expect_calls 1 "pnpm lint"
[ "$(on_main factory/list.md | sed -n '3,7p')" = $'| Step | Why |\n|---|---|\n| One | first |\n| Seven | by seven |\n| Eight | by eight |' ] \
  || fail "expected the table on main to hold both rows, got: $(on_main factory/list.md)"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree that was tested"
# GitHub refuses #8 as it was approved, and merges the commit the script pushed to its branch (decisions M485a).
[ "$(merges)" = "7 8 8 " ] || fail "expected #7 to merge, then #8 at its second call, got: $(merges)"
expect_call "gh pr merge 8 --squash --delete-branch --match-head-commit $before"
[ "$(git --git-dir="$T/origin.git" rev-parse "refs/heads/pr-8^1")" = "$before" ] || fail "expected the branch of #8 to hold a merge on top of the commit that was approved"
expect_no_call "gh workflow run fix.yml"
expect_no_call "factory:merge-queue removed"
expect_no_call "gh workflow run merge-group.yml -f try="
for ticket in 12 13; do expect_call "gh issue edit $ticket --add-label deployed"; done

scenario "main moved on after the two left it: the merge job, whose checkout holds one commit, still makes the merge that keeps both rows"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
(cd "$T/scratch" && git fetch --quiet origin main && git checkout --quiet --detach origin/main && echo "pushed by a person" > README.md \
  && git add . && git commit --quiet -m "docs: a push to main" && git push --quiet origin HEAD:main)
approved 7 8
begin
test_it
ship_it
expect_status 0
[ "$(on_main factory/list.md | grep -c 'by seven\|by eight')" = 2 ] || fail "expected main to hold both rows"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree that was tested"
expect_no_call "gh workflow run fix.yml"
expect_no_call "gh workflow run merge-group.yml -f try="

scenario "two pull requests each add an item to one ordered list: both items are there, and the list is numbered in order when shown"
github
pull 7 factory/list.md --add-after "1. two" "1. by seven"
pull 8 factory/list.md --add-after "1. two" "1. by eight"
approved 7 8
begin
test_it
ship_it
expect_status 0
# Markdown numbers items written `1.` in order when they follow one another with no line between (decisions M485e).
[ "$(on_main factory/list.md | sed -n '6,12p')" = $'\n1. one\n1. two\n1. by seven\n1. by eight\n\nThe end.' ] \
  || fail "expected one list of four items, each written 1., got: $(on_main factory/list.md)"
expect_no_call "gh workflow run fix.yml"

scenario "two pull requests change the same line of a marked file: the second is left out and gets a fix round, as for any conflict"
github
pull 7 factory/list.md --last-line "The end, as seven has it."
pull 8 factory/list.md --last-line "The end, as eight has it."
approved 7 8
begin
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 " ] || fail "expected #7 alone to merge, got: $(merges)"
[ "$(on_main factory/list.md | tail -n 1)" = "The end, as seven has it." ] || fail "expected main to hold the line as #7 has it, and not both"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $(head_of 8) -->Not merged: it does not fit \`main\` with the pull requests merged before it."
expect_calls 1 "gh workflow run fix.yml -f pr=8"
run "$scripts/merge-queue.sh" removed 8 "$(head_of 8)"
expect_output "factory/list.md"

scenario "two pull requests each add a line at one place of a file no mark names: the second gets a fix round"
github
pull 7 apps/web/page.txt --add-after "the app" "seven's line"
pull 8 apps/web/page.txt --add-after "the app" "eight's line"
approved 7 8
begin
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 " ] || fail "expected #7 alone to merge, got: $(merges)"
expect_calls 1 "gh workflow run fix.yml -f pr=8"

scenario "the merge that keeps both rows cannot be pushed: the pull request goes back with what git answered, and gets a fix round"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
approved 7 8
begin
test_it
printf '#!/bin/sh\n[ "$1" != refs/heads/pr-8 ] || { echo "refusing to update the branch"; exit 1; }\n' > "$T/origin.git/hooks/update"
chmod +x "$T/origin.git/hooks/update"
before=$(head_of 8)
ship_it
expect_status 0
[ "$(merges)" = "7 8 " ] || fail "expected #8 to be asked for once and not merged, got: $(merges)"
[ "$(head_of 8)" = "$before" ] || fail "expected the branch of #8 to be as it was"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $before -->Not merged:"
expect_calls 1 "gh workflow run fix.yml -f pr=8"
run "$scripts/merge-queue.sh" removed 8 "$before"
expect_output "could not be pushed to the branch"
expect_output "refusing to update the branch"

scenario "the second of the two is from a fork: nothing is pushed to a branch of this repo, and it goes back as for any conflict"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
approved 7 8
echo 8 > "$T/forks"
before=$(head_of 8)
begin
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 8 " ] || fail "expected #8 to be asked for once and not merged, got: $(merges)"
[ "$(head_of 8)" = "$before" ] || fail "expected no branch of this repo to be written"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $before -->Not merged:"
run "$scripts/merge-queue.sh" removed 8 "$before"
expect_output "cannot be pushed to a branch of another repository"

scenario "the second of the two also changes what only the owner decides: nothing is pushed over the commit they approved, and it gets a fix round"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
(cd "$T/scratch" && echo "A new bar." > TASTE.md && git add . && git commit --quiet -m "docs: raise the bar" && git push --quiet origin HEAD:refs/heads/pr-8) \
  || fail "the second commit of pull request #8 could not be made"
approved 7 8
before=$(head_of 8)
begin
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 8 " ] || fail "expected #8 to be asked for once and not merged, got: $(merges)"
[ "$(head_of 8)" = "$before" ] || fail "expected the branch of #8 to hold the commit the owner approved"
expect_calls 1 "gh workflow run fix.yml -f pr=8"
run "$scripts/merge-queue.sh" removed 8 "$before"
expect_output "It changes what only the repo's owner may decide"

scenario "GitHub fails the merge of the commit the script pushed: the pull request waits to merge at that commit, and its group is tested again"
github
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
pull 9 apps/web/nine.txt
approved 7 8 9
echo 8 > "$T/refused"
before=$(head_of 8)
begin
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 8 8 8 8 " ] || fail "expected #8 to be asked for once as approved and three times as pushed, got: $(merges)"
pushed=$(head_of 8)
[ "$pushed" != "$before" ] || fail "expected the branch of #8 to hold the merge the script pushed"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue added $pushed -->"
expect_call "gh workflow run merge-group.yml -f try=2"
expect_no_call "gh workflow run fix.yml"
rm "$T/refused"
begin
[ "$group" = "9:$(head_of 9) 8:$pushed" ] || fail "expected #9 and #8 as pushed to be the next group, got: $group"
test_it
ship_it
expect_status 0
[ "$(on_main factory/list.md | grep -c 'by seven\|by eight')" = 2 ] || fail "expected main to hold both rows after the second test"
git --git-dir="$T/origin.git" cat-file -e main:apps/web/nine.txt 2>/dev/null || fail "expected the second test to merge #9"

scenario "one of three breaks the checks of the group: each is tested alone, it goes back with what failed, and the other two merge"
github
echo "$broken" > "$T/lint"
pull 7 apps/web/seven.txt; pull 8 apps/web/broken; pull 9 apps/web/nine.txt
approved 7 8 9
begin
test_it
ship_it
expect_status 0
expect_calls 4 "pnpm lint"
[ "$(merges)" = "7 9 " ] || fail "expected #7 and #9 to merge, got: $(merges)"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree that was tested"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $(head_of 8) -->Not merged: its checks failed when it was tested with \`main\` and the pull requests merged before it."
expect_calls 1 "gh workflow run fix.yml -f pr=8"
run "$scripts/merge-queue.sh" removed 8 "$(head_of 8)"
expect_output "lint: apps/web/broken is not allowed"

scenario "a pull request approved while a group is tested waits for the next group"
github
pull 7 apps/web/seven.txt; pull 8 apps/web/eight.txt; pull 9 apps/web/nine.txt
approved 7 8
begin
test_it
: > "$T/calls"
approved 9
# Its own run of the workflow is asked for, and waits its turn behind this one.
expect_calls 1 "gh workflow run merge-group.yml"
ship_it
expect_status 0
[ "$(merges)" = "7 8 " ] || fail "expected #7 and #8 alone to merge, got: $(merges)"
! git --git-dir="$T/origin.git" cat-file -e main:apps/web/nine.txt 2>/dev/null || fail "expected main not to hold #9"
begin
[ "$group" = "9:$(head_of 9)" ] || fail "expected #9 alone to be the next group, got: $group"
test_it
ship_it
expect_status 0
git --git-dir="$T/origin.git" cat-file -e main:apps/web/nine.txt 2>/dev/null || fail "expected the next group to merge #9"

scenario "merge-group.yml tests and merges one group at a time, and a run that is asked for meanwhile waits"
grep -A1 -x 'concurrency:' "$workflow" | grep -qxF '  group: merge-group' || fail "expected every run to be in the one group merge-group"
! grep -q 'cancel-in-progress: true' "$workflow" || fail "expected a group that is being tested not to be cancelled"
# Under one job the group would be free between the jobs of a run.
[ "$(grep -c '^concurrency:' "$workflow")" = 1 ] && ! grep -q '^    concurrency:' "$workflow" || fail "expected the group to hold the whole run, not one job of it"

scenario "main moves while a group is tested: nothing merges on that test, and the group is tested again"
github
pull 7 apps/web/seven.txt; pull 8 apps/web/eight.txt; pull 9 apps/web/nine.txt
approved 7 8 9
begin
test_it
(cd "$T/scratch" && git fetch --quiet origin main && git checkout --quiet --detach origin/main && echo "pushed by a person" > README.md \
  && git add . && git commit --quiet -m "docs: a push to main" && git push --quiet origin HEAD:main)
: > "$T/calls"
ship_it
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"
expect_calls 1 "gh workflow run merge-group.yml"
begin
[ "$group" = "7:$(head_of 7) 8:$(head_of 8) 9:$(head_of 9)" ] || fail "expected the same group to be tested again, got: $group"
test_it
ship_it
expect_status 0
[ "$(merges)" = "7 8 9 " ] || fail "expected the three to merge on the second test, got: $(merges)"
[ "$(jq -r .tree "$T/result.json")" = "$(tree_on_github)" ] || fail "expected main to hold the tree the second test passed"
git --git-dir="$T/origin.git" cat-file -e main:README.md 2>/dev/null || fail "expected main to keep the push that moved it"

scenario "the job that runs the pull requests' code may read the repo and nothing else, and is given no token or secret"
job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflow"; }
[ "$(job test | sed -n '/^    permissions:/,/^    steps:/p' | grep -c '^      ')" = 1 ] || fail "expected the test job to hold one permission"
job test | grep -qxF '      contents: read' || fail "expected the test job to read the repo and no more"
! job test | grep -qE 'secrets\.|github\.token|GH_TOKEN' || fail "expected the test job to be given no token and no secret"
job test | grep -qF 'cp -R factory/scripts "$RUNNER_TEMP/scripts"' || fail "expected the test to run main's copy of the scripts, set aside before a pull request is applied"
# The job that merges runs nothing of a pull request's: its checkout is main's.
job merge | grep -A3 -xF '      - uses: actions/checkout@v4' | grep -qxF '          ref: ${{ github.event.repository.default_branch }}' \
  || fail "expected the merge job to check out main"
! job merge | grep -q 'pnpm' || fail "expected the merge job to run no check"
