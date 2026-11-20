#!/usr/bin/env bash
# Tests for test-group.sh: a group of pull requests is tested with main once, and each alone when that fails.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/group-on-github.sh"

tree() { jq -r .tree "$T/result.json"; }
# shellcheck disable=SC2016
broken='[ ! -e apps/web/broken ] || { echo "lint: apps/web/broken is not allowed"; exit 1; }'

scenario "three pull requests that fit together are tested once, and the tree that passed is the one their merges make"
github_repo
pull 7 apps/web/seven.txt
pull 8 apps/web/eight.txt
pull 9 apps/web/nine.txt
test_group 7 8 9
expect_status 0
for number in 7 8 9; do expect_result "$number" passed; done
expect_calls 1 "pnpm lint"
[ "$(jq -r .main "$T/result.json")" = "$main" ] || fail "expected the result to name the commit of main it was tested with"
[ "$(jq -r '[.pulls[].number] | join(" ")' "$T/result.json")" = "7 8 9" ] || fail "expected the pull requests in the order they were added"
for number in 7 8 9; do merge_on_github "$number"; done
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree $(tree) to be the tree main holds after the three merges, $(tree_on_github)"

scenario "the checks are those of the checks job: an app change runs typecheck, the app's tests and its build, and no factory test"
github_repo
pull 7 apps/web/seven.txt
test_group 7
expect_status 0
for check in "pnpm install --frozen-lockfile" "pnpm lint" "pnpm typecheck" "pnpm -r test" "pnpm build"; do expect_call "$check"; done
expect_no_call "test-factory.sh"

scenario "a factory change runs the factory's tests, given the commit of main to compare with, and none of the app's checks but lint"
github_repo
pull 7 factory/scripts/new.sh
test_group 7
expect_status 0
expect_call "pnpm lint"
expect_call "test-factory.sh $main"
expect_no_call "pnpm typecheck"
expect_no_call "pnpm build"

scenario "one of three that conflicts is left out, with the files in conflict, and the other two are tested once"
github_repo
pull 7 apps/web/page.txt "seven's page"
pull 8 apps/web/page.txt "eight's page"
pull 9 apps/web/nine.txt
test_group 7 8 9
expect_status 0
expect_result 7 passed
expect_result 8 conflict
expect_result 9 passed
expect_calls 1 "pnpm lint"
[[ "$(jq -r '.pulls[1].detail' "$T/result.json")" == *"apps/web/page.txt"* ]] || fail "expected the detail to name the file in conflict"
merge_on_github 7; merge_on_github 9
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree to be the one the two merges make"

scenario "one of three breaks the checks of the group: each is tested alone, it fails with what failed, and the other two pass"
github_repo
echo "$broken" > "$T/lint"
pull 7 apps/web/seven.txt
pull 8 apps/web/broken
pull 9 apps/web/nine.txt
test_group 7 8 9
expect_status 0
expect_result 7 passed
expect_result 8 failed
expect_result 9 passed
# Once for the group, then once for each.
expect_calls 4 "pnpm lint"
[[ "$(jq -r '.pulls[1].detail' "$T/result.json")" == *"lint: apps/web/broken is not allowed"* ]] || fail "expected the detail to hold what the failed check printed"
merge_on_github 7; merge_on_github 9
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree to be the one the two merges make, without the one that failed"

scenario "what a failed check printed is cut to its end, so the comment that sends the pull request back fits"
github_repo
# shellcheck disable=SC2016
echo '[ ! -e apps/web/broken ] || { for _ in 1 2 3; do printf "%030000d\n" 0; done; echo "lint: the last line"; exit 1; }' > "$T/lint"
pull 7 apps/web/broken
test_group 7
expect_status 0
expect_result 7 failed
detail=$(jq -r '.pulls[0].detail' "$T/result.json")
[ "${#detail}" -le 20000 ] || fail "expected a detail of 20000 characters at most, got ${#detail}"
[[ "$detail" == *"lint: the last line" ]] || fail "expected the detail to end with the last line the failed check printed"

scenario "two that pass alone and fail together: the later one fails, on top of the one that passed"
github_repo
# shellcheck disable=SC2016
echo '[ ! -e apps/web/seven.txt ] || [ ! -e apps/web/nine.txt ] || { echo "lint: seven and nine do not go together"; exit 1; }' > "$T/lint"
pull 7 apps/web/seven.txt
pull 8 apps/web/eight.txt
pull 9 apps/web/nine.txt
test_group 7 8 9
expect_status 0
expect_result 7 passed
expect_result 8 passed
expect_result 9 failed
# The tree the three make failed as the group: it is not tested a second time.
expect_calls 3 "pnpm lint"
expect_output "pull request #9 makes the tree that failed"

scenario "a group of one that fails is not tested twice"
github_repo
echo "$broken" > "$T/lint"
pull 7 apps/web/broken
test_group 7
expect_status 0
expect_result 7 failed
expect_calls 1 "pnpm lint"
[ "$(tree)" = "$(git rev-parse "$main^{tree}")" ] || fail "expected the tree to be main's, as nothing passed"

scenario "one that conflicted with the one that failed fits once that one is out, and is tested"
github_repo
# shellcheck disable=SC2016
echo '! grep -qx "seven breaks it" apps/web/page.txt || { echo "lint: the page is broken"; exit 1; }' > "$T/lint"
pull 7 apps/web/page.txt "seven breaks it"
pull 8 apps/web/page.txt "eight's page"
test_group 7 8
expect_status 0
expect_result 7 failed
expect_result 8 passed
merge_on_github 8
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree to be the one the merge of #8 makes"

scenario "what a check leaves in the checkout does not reach the next test"
github_repo
# shellcheck disable=SC2016
echo 'echo junk > apps/web/left-behind; echo changed >> apps/web/page.txt; [ ! -e apps/web/broken ] || exit 1' > "$T/lint"
pull 7 apps/web/broken
pull 8 apps/web/page.txt "eight's page"
test_group 7 8
expect_status 0
expect_result 7 failed
expect_result 8 passed
merge_on_github 8
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree to hold nothing a check wrote"

scenario "two changes to different lines of one workflow source are tested together, as git joins them (decisions W281a)"
github_repo
pull 7 factory/workflows/ci.yml --first-line "name: ci, as seven has it"
pull 8 factory/workflows/ci.yml --last-line "  checks: as eight has it"
test_group 7 8
expect_status 0
expect_result 7 passed
expect_result 8 passed
expect_calls 1 "pnpm lint"
merge_on_github 7; merge_on_github 8
[ "$(tree)" = "$(tree_on_github)" ] || fail "expected the tested tree to be the one the two merges make"
[ "$(git --git-dir="$T/origin.git" show main:factory/workflows/ci.yml | sed -n '1p;$p' | xargs)" = "name: ci, as seven has it checks: as eight has it" ] \
  || fail "expected main's source to hold both changes"

scenario "a change to a workflow source main has changed since the pull request left it is tested, as git joins them"
github_repo
pull 7 factory/workflows/ci.yml --first-line "name: ci, as seven has it"
pull 8 factory/workflows/ci.yml --last-line "  checks: as eight has it"
merge_on_github 7
git pull --quiet origin main
main=$(git rev-parse HEAD)
test_group 8
expect_status 0
expect_result 8 passed

scenario "two changes to one line of a workflow source conflict, and the second is left out"
github_repo
pull 7 factory/workflows/ci.yml --first-line "name: ci, as seven has it"
pull 8 factory/workflows/ci.yml --first-line "name: ci, as eight has it"
test_group 7 8
expect_status 0
expect_result 7 passed
expect_result 8 conflict
[[ "$(jq -r '.pulls[1].detail' "$T/result.json")" == *"factory/workflows/ci.yml"* ]] || fail "expected the detail to name the workflow source"

scenario "two that each add a row at one place of a list main marks are tested together, and the tested tree holds both rows"
github_repo
pull 7 factory/list.md --add-after "| One | first |" "| Seven | by seven |"
pull 8 factory/list.md --add-after "| One | first |" "| Eight | by eight |"
test_group 7 8
expect_status 0
expect_result 7 passed
expect_result 8 passed
expect_calls 1 "pnpm lint"
[ "$(git show "$(tree):factory/list.md" | sed -n '5,7p')" = $'| One | first |\n| Seven | by seven |\n| Eight | by eight |' ] \
  || fail "expected the tested tree to hold both rows, got: $(git show "$(tree):factory/list.md")"

scenario "two that change one line of a list main marks conflict: the second is left out, and neither version of the line is kept beside the other"
github_repo
pull 7 factory/list.md --last-line "The end, as seven has it."
pull 8 factory/list.md --last-line "The end, as eight has it."
test_group 7 8
expect_status 0
expect_result 7 passed
expect_result 8 conflict
[[ "$(jq -r '.pulls[1].detail' "$T/result.json")" == *"factory/list.md"* ]] || fail "expected the detail to name the list"
[ "$(git show "$(tree):factory/list.md" | tail -n 1)" = "The end, as seven has it." ] || fail "expected the tested tree to end with the line as #7 has it"

scenario "fails, and writes no result, when settle-conflict.sh cannot say whether a pull request conflicts"
github_repo
pull 7 apps/web/seven.txt
cp -R "$scripts" "$T/scripts"
printf '#!/usr/bin/env bash\necho "git could not merge them" >&2\nexit 2\n' > "$T/scripts/settle-conflict.sh"
run "$T/scripts/test-group.sh" "$T/result.json" "7:$(head_of 7)"
expect_failure
expect_output "Pull request #7 could not be merged into the checkout, so the group was not tested."
[ ! -e "$T/result.json" ] || fail "expected no result file"
expect_no_call "pnpm"

scenario "a pull request pushed to since it was added is left to the group its new commit joins"
github_repo
pull 7 apps/web/seven.txt
pull 8 apps/web/eight.txt
added=$(head_of 8)
pull 8 apps/web/eight.txt "pushed again"
run "$scripts/test-group.sh" "$T/result.json" "7:$(head_of 7)" "8:$added"
expect_status 0
expect_result 7 passed
[ -z "$(result_of 8)" ] || fail "expected the result to say nothing of #8, got: $(result_of 8)"
expect_output "pull request #8 is no longer at ${added:0:7}"

scenario "fails, and writes no result, when a pull request's commits cannot be fetched"
github_repo
pull 7 apps/web/seven.txt
run "$scripts/test-group.sh" "$T/result.json" "7:$(head_of 7)" "8:$(head_of 7)"
expect_failure
expect_output "The commits of pull request #8 could not be fetched, so the group was not tested."
[ ! -e "$T/result.json" ] || fail "expected no result file"
expect_no_call "pnpm"

scenario "a check that cannot start is a failure of the pull request, not a pass"
github_repo
stub pnpm 'echo "pnpm: command failed"; exit 127'
pull 7 apps/web/seven.txt
test_group 7
expect_status 0
expect_result 7 failed
