#!/usr/bin/env bash
# Tests for carry-review.sh: a pass is posted again, with no review, only after merges of main (decisions A160a, A160b).
. "$(dirname "$0")/helpers.sh"

adam="Adam (architecture and taste)"
ryan="Ryan (correctness)"

# $passed is the commit the reviewers read; $T/fail holds one line per gh call, by its first words, that should fail.
a_pull_request() {
  : > "$T/fail"
  : > "$T/outputs"
  echo '[]' > "$T/comments"
  echo 'github-actions[bot]' > "$T/author"
  mkdir -p "$T/runner"
  export GITHUB_OUTPUT="$T/outputs" RUNNER_TEMP="$T/runner"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    add() { jq --arg login "$(cat "$T/author")" --arg body "$1" ". + [{user: {login: \$login}, body: \$body}]" "$T/comments" > "$T/comments.new" && mv "$T/comments.new" "$T/comments"; }
    case "$*" in
      "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq "*) json "$(cat "$T/comments")" "$@" ;;
      "pr comment 7 --body-file "*) add "$(cat "$5")" ;;
      "pr comment 7 --body "*) add "$5" ;;
      "pr edit 7 --add-label needs-human") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  git init -q -b main .
  seq 1 20 > app.txt
  echo one > other.txt
  git add . && git commit -q -m "start"
  git checkout -q -b feature
  sed 's/^10$/ten/' app.txt > app.new && mv app.new app.txt
  git commit -q -am "feat: spell ten"
  passed=$(git rev-parse HEAD)
}
on_main() {
  git checkout -q main
  eval "$2"
  git add . && git commit -q -m "$1"
  git checkout -q feature
}
verdict() {
  OUTPUT="$3" HEAD_SHA="$2" "$scripts/post-verdict.sh" "$1" 7 >/dev/null 2>&1 || true
}
pass='{"verdict":"pass","findings":[],"assumptions":[{"assumes":"GitHub accepts `queue: max`.","if_wrong":"Every merge stops."}]}'
fail_json='{"findings":[{"file":"app.txt","line":10,"kind":"misbehaves","problem":"Wrong.","fix":"Right it."}],"assumptions":[]}'
carry() {
  before=$(jq length "$T/comments")
  run "$scripts/carry-review.sh" "${1:-$ryan}" 7 "${2:-$(git rev-parse HEAD)}" "${3:-main}"
}
last_comment() { jq -r '.[-1].body' "$T/comments"; }
expect_carried() {
  expect_status 0
  grep -qxF "carried=true" "$T/outputs" || fail "expected carried=true in the step's outputs"
  expect_call "gh pr comment 7 --body-file"
}
expect_reviewed() {
  ! grep -q carried "$T/outputs" || fail "expected nothing about carried in the step's outputs"
  [ "$(jq length "$T/comments")" = "$before" ] || fail "expected no comment to be posted"
  expect_output "$1"
}

scenario "a merge of main that leaves the change as it was carries a pass, in the form the gate and the facts read"
a_pull_request
verdict "$ryan" "$passed" "$pass"
given=$(last_comment)
on_main "docs: other" 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
carry
expect_carried
expect_output "Ryan (correctness)'s pass of ${passed:0:7} is carried forward to $(git rev-parse --short=7 HEAD): no review runs."
[ "$(last_comment | sed -n 1p)" = "**Ryan (correctness): PASS**" ] || fail "expected the verdict's first line, got: $(last_comment | sed -n 1p)"
[ "$(last_comment | sed -n 3p)" = "Carried forward from the review of ${passed:0:7}: every commit since is a merge of \`main\`, and this pull request's own change reads the same at $(git rev-parse --short=7 HEAD) as it did then. No review ran. <!-- factory:carried -->" ] \
  || fail "expected the third line to say which commit the review was of, got: $(last_comment | sed -n 3p)"
[ "$(last_comment | sed -n '5,$p')" = "$(sed -n '3,$p' <<<"$given")" ] || fail "expected the rest to be the verdict as it was given, got: $(last_comment)"
[ "$(last_comment | tail -n 1)" = "$(tail -n 1 <<<"$given")" ] || fail "expected the hidden list of assumptions to stay the last line"
[[ "$(last_comment | tail -n 1)" == '<!-- factory:assumptions [{"assumes":"GitHub accepts `queue: max`."'* ]] || fail "expected the last line to be the hidden list"
[ "$(jq length "$T/comments")" = 2 ] || fail "expected one comment more"

scenario "a merge of main that changed the same file far from the change still carries: only positions moved"
a_pull_request
verdict "$adam" "$passed" "$pass"
on_main "feat: a heading" '{ echo heading; echo; cat app.txt; } > app.new && mv app.new app.txt'
git merge -q --no-edit main >/dev/null
carry "$adam"
expect_carried

scenario "a second merge of main carries the carried pass, and still names the commit a reviewer read"
a_pull_request
verdict "$ryan" "$passed" "$pass"
on_main "docs: other" 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
carry
between=$(git rev-parse --short=7 HEAD)
on_main "docs: other again" 'echo three > other.txt'
git merge -q --no-edit main >/dev/null
carry
expect_carried
[ "$(jq length "$T/comments")" = 3 ] || fail "expected a comment for each carry"
[ "$(last_comment | grep -c 'factory:carried')" = 1 ] || fail "expected one line saying it was carried, got: $(last_comment)"
[[ "$(last_comment)" == *"Carried forward from the review of ${passed:0:7}:"* ]] || fail "expected it to name the commit that was reviewed"
[[ "$(last_comment)" != *"review of $between"* ]] || fail "expected it not to name the merge in between"
[ "$(last_comment | grep -c "^<!-- factory:reviewed $passed -->$")" = 1 ] || fail "expected it to keep the line naming the reviewed commit"

scenario "the job run again for the commit that passed carries too"
a_pull_request
verdict "$ryan" "$passed" "$pass"
carry
expect_carried

scenario "a merge of main that needed a hand in the changed file is reviewed again"
a_pull_request
verdict "$ryan" "$passed" "$pass"
on_main "feat: ten in capitals" 'sed "s/^10$/TEN/" app.txt > app.new && mv app.new app.txt'
git merge -q --no-edit main >/dev/null 2>&1 || true
sed -e '/^<<<<<<<\|^=======\|^>>>>>>>/d' -e '/^TEN$/d' app.txt > app.new && mv app.new app.txt
git commit -q -am "Merge main"
grep -qx ten app.txt || fail "the scenario did not resolve the conflict in favour of the branch"
carry
expect_status 0
expect_reviewed "its change does not read the same at $(git rev-parse --short=7 HEAD) as at ${passed:0:7}"

scenario "a merge of main that changed a line beside the change is reviewed again"
a_pull_request
verdict "$ryan" "$passed" "$pass"
on_main "feat: twelve" 'sed "s/^12$/twelve/" app.txt > app.new && mv app.new app.txt'
git merge -q --no-edit main >/dev/null
carry
expect_status 0
expect_reviewed "its change does not read the same"

scenario "a merge of main that also edits a file by hand is reviewed again"
a_pull_request
verdict "$ryan" "$passed" "$pass"
on_main "docs: other" 'echo two > other.txt'
git merge -q --no-commit main >/dev/null 2>&1
echo smuggled >> other.txt
git commit -q -am "Merge main"
carry
expect_status 0
expect_reviewed "its change does not read the same"

scenario "a commit that is not a merge is reviewed again, even one that changes nothing"
a_pull_request
verdict "$ryan" "$passed" "$pass"
git commit -q --allow-empty -m "chore: nothing"
carry
expect_status 0
expect_reviewed "$(git rev-parse --short=7 HEAD), pushed since ${passed:0:7}, is not a merge of main"

scenario "a merge of a branch that is not main is reviewed again, even one that changes nothing"
a_pull_request
verdict "$ryan" "$passed" "$pass"
git checkout -q -b side main
git commit -q --allow-empty -m "chore: on the side"
git checkout -q feature
git merge -q --no-edit side >/dev/null
carry
expect_status 0
expect_reviewed "merges a commit that is not on main"

scenario "a merge of main under a commit that is not one is reviewed again"
a_pull_request
verdict "$ryan" "$passed" "$pass"
git commit -q --allow-empty -m "chore: nothing"
on_main "docs: other" 'echo two > other.txt'
git merge -q --no-edit main >/dev/null
carry
expect_status 0
expect_reviewed "is not a merge of main"

scenario "a branch rewritten since the pass is reviewed again"
a_pull_request
verdict "$ryan" "$passed" "$pass"
git commit -q --amend -m "feat: spell ten, reworded"
carry
expect_status 0
expect_reviewed "is not a merge of main"

scenario "a latest verdict that is a fail carries nothing, though an earlier one passed"
a_pull_request
verdict "$ryan" "$passed" "$pass"
verdict "$ryan" "$passed" "$fail_json"
carry
expect_status 0
expect_reviewed "its latest verdict there is not a pass"

scenario "a latest review that was not finished carries nothing, though an earlier one passed"
a_pull_request
verdict "$ryan" "$passed" "$pass"
verdict "$ryan" "$passed" ""
[[ "$(last_comment)" == "**Ryan (correctness): review not finished.**"* ]] || fail "the scenario did not post an unfinished review"
carry
expect_status 0
expect_reviewed "its latest verdict there is not a pass"

scenario "the other reviewer's pass carries nothing for this one"
a_pull_request
verdict "$adam" "$passed" "$pass"
carry "$ryan"
expect_status 0
expect_reviewed "it has no verdict there yet"

scenario "a pass that does not say which commit it was given for, as one from before the line, carries nothing"
a_pull_request
verdict "$ryan" "" "$pass"
carry
expect_status 0
expect_reviewed "its latest pass does not say which commit it was given for"

scenario "a pass written by anyone but the factory's own account carries nothing"
a_pull_request
for author in 'claude[bot]' github-actions repo-owner; do
  echo "$author" > "$T/author"
  verdict "$ryan" "$passed" "$pass"
done
carry
expect_status 0
expect_reviewed "it has no verdict there yet"

scenario "a pass of a commit the repo no longer holds carries nothing"
a_pull_request
verdict "$ryan" 1234567890123456789012345678901234567890 "$pass"
carry
expect_status 0
expect_reviewed "the earlier commit, 1234567, is no longer in the repo"

scenario "comments GitHub does not return stop it with a message, and nothing is carried"
a_pull_request
verdict "$ryan" "$passed" "$pass"
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
carry
expect_failure
expect_reviewed "Could not read the comments of pull request #7 from GitHub, so whether the earlier review still stands is not known and Ryan (correctness) reviews pull request #7 again."

scenario "a verdict that cannot be posted again stops it with a message, and nothing is carried"
a_pull_request
verdict "$ryan" "$passed" "$pass"
echo "pr comment 7" > "$T/fail"
carry
expect_failure
expect_reviewed "The earlier verdict could not be posted again on pull request #7"

scenario "a head, or a main, the checkout does not hold stops it with a message"
a_pull_request
verdict "$ryan" "$passed" "$pass"
carry "$ryan" 9999999999999999999999999999999999999999
expect_failure
expect_reviewed "The head commit 9999999999999999999999999999999999999999 is not in this checkout"
carry "$ryan" "$passed" origin/main
expect_failure
expect_reviewed "origin/main is not in this checkout"
