#!/usr/bin/env bash
# Tests for start-retests.sh: after a merge, a pull request labelled `waits-for-main` or sent back gets its fix round.
. "$(dirname "$0")/helpers.sh"

head=5555555555555555555555555555555555555555
other=6666666666666666666666666666666666666666

# $T/pulls holds the open pull requests and $T/reviews-<n> the reviews of one;
# $T/fail lists the gh calls, by their first words, that fail.
github() {
  : > "$T/fail"; echo '[]' > "$T/pulls"
  export head
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --limit 100 --json number,author,labels,isDraft "*) json "$(cat "$T/pulls")" "$@" ;;
      "pr view "*" --json headRefOid "*) json "{\"headRefOid\":\"$head\"}" "$@" ;;
      "api repos/{owner}/{repo}/pulls/"*"/reviews?per_page=100 --paginate --jq "*)
        n=${2#*/pulls/}; json "$(cat "$T/reviews-${n%/reviews*}" 2>/dev/null || echo "[]")" "$@" ;;
      "workflow run fix.yml -f pr="*) echo "created workflow_dispatch event" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# open <number> <who opened it> <draft> [label]...
open() {
  local number="$1" login="$2" draft="$3"; shift 3
  jq --argjson n "$number" --arg login "$login" --argjson draft "$draft" \
    '. + [{number: $n, author: {login: $login}, isDraft: $draft, labels: ($ARGS.positional | map({name: .}))}]' "$T/pulls" --args "$@" > "$T/pulls.new"
  mv "$T/pulls.new" "$T/pulls"
}
# reviewed <pr> <id> <login> <state> <submitted> [commit]: adds a review, of the head unless another commit is given.
reviewed() {
  jq --argjson id "$2" --arg login "$3" --arg state "$4" --arg at "$5" --arg commit "${6:-$head}" \
    '. + [{id: $id, user: {login: $login}, state: $state, commit_id: $commit, submitted_at: $at}]' \
    <(cat "$T/reviews-$1" 2>/dev/null || echo "[]") > "$T/reviews.new"
  mv "$T/reviews.new" "$T/reviews-$1"
}
retest() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=repo-owner/myapp "$scripts/start-retests.sh"; }

scenario "starts the fix round of a pull request labelled waits-for-main, and none for one without the label that nobody sent back"
github
open 7 app/claude false needs-human waits-for-main
open 8 app/claude false needs-human
open 9 app/claude false
retest
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_output "started the fix round that tests pull request #7 with main again"
[ "$(grep -c '^gh workflow run' "$T/calls")" = 1 ] || fail "expected one workflow to be started"
expect_no_call "gh pr view 7"
expect_no_call "gh api repos/{owner}/{repo}/pulls/7/"

scenario "starts one for each labelled pull request"
github
open 7 app/claude false waits-for-main
open 11 app/claude false waits-for-main needs-human
retest
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "starts nothing, and says so, when no pull request carries the label or was sent back"
github
open 8 app/claude false needs-human
retest
expect_status 0
expect_no_call "gh workflow run"
expect_output "no pull request is labelled waits-for-main, and none waits for its owner's fix round: no fix round is started"

scenario "leaves a labelled draft, which its engineer is still building, and a labelled pull request a person opened"
github
open 7 app/claude true waits-for-main
open 8 repo-owner false waits-for-main
retest
expect_status 0
expect_no_call "gh workflow run"

scenario "starts the owner's round of a pull request the owner sent back while it was in conflict, when GitHub ran nothing for the review"
github
open 7 app/claude false needs-human
open 8 app/claude false needs-human
reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
retest
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_output "started fix.yml for pull request #7, which its owner sent back: the owner's fix round begins unless that request has had one"
expect_no_call "issues/7/comments"
expect_no_output "no pull request is labelled"

scenario "starts none when the owner approved afterwards, when a push answered the request, or when the request is not the owner's"
github
open 7 app/claude false
reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
reviewed 7 42 repo-owner APPROVED 2026-11-18T10:00:00Z
open 8 app/claude false
reviewed 8 43 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z "$other"
open 9 app/claude false
reviewed 9 44 someone-else CHANGES_REQUESTED 2026-11-18T09:00:00Z
retest
expect_status 0
expect_no_call "gh workflow run"

scenario "leaves a draft the owner sent back, and a pull request a person opened"
github
open 7 app/claude true
reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
open 8 repo-owner false
reviewed 8 42 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
retest
expect_status 0
expect_no_call "gh workflow run"

scenario "a labelled pull request the owner sent back gets one round, which is the owner's as well"
github
open 7 app/claude false waits-for-main
reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
retest
expect_status 0
[ "$(grep -c '^gh workflow run fix.yml -f pr=7' "$T/calls")" = 1 ] || fail "expected one round to be started"

scenario "stops with a message when the pull requests cannot be read: that is not 'none waits'"
github
open 7 app/claude false waits-for-main
echo "pr list" > "$T/fail"
retest
expect_status 1
expect_no_call "gh workflow run"
expect_output "The open pull requests could not be read from GitHub, so after this merge none labelled waits-for-main is tested again, and no owner's fix round is started."
expect_no_output "no pull request is labelled"

scenario "a round that could not be started does not stop the next, and the script fails naming it"
github
open 7 app/claude false waits-for-main
open 11 app/claude false waits-for-main
echo "workflow run fix.yml -f pr=7" > "$T/fail"
retest
expect_status 1
expect_call "gh workflow run fix.yml -f pr=11"
expect_output "started the fix round that tests pull request #11 with main again"
expect_output "the round could not be started: #7. The next merge starts it."

for words in "pr view 7 --json headRefOid" "api repos/{owner}/{repo}/pulls/7/reviews?per_page=100"; do
  scenario "the owner's round: starts none for a pull request this could not be read for, starts the next, and fails naming it: gh $words"
  github
  open 7 app/claude false
  reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
  open 8 app/claude false
  reviewed 8 42 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
  echo "$words" > "$T/fail"
  retest
  expect_status 1
  expect_no_call "gh workflow run fix.yml -f pr=7"
  expect_call "gh workflow run fix.yml -f pr=8"
  expect_output "could not be read, or the round could not be started: #7. The next merge starts it."
done

scenario "the owner's round that could not be started fails the script, naming the pull request"
github
open 7 app/claude false
reviewed 7 41 repo-owner CHANGES_REQUESTED 2026-11-18T09:00:00Z
echo "workflow run fix.yml -f pr=7" > "$T/fail"
retest
expect_status 1
expect_output "the round could not be started: #7. The next merge starts it."
expect_no_output "started fix.yml"

scenario "refuses to run without GITHUB_REPOSITORY, which names the owner"
github
open 7 app/claude false
run env -u GITHUB_REPOSITORY GH_TOKEN=workflow-token "$scripts/start-retests.sh"
expect_status 1
expect_output "start-retests.sh needs GITHUB_REPOSITORY"
[ ! -s "$T/calls" ] || fail "expected GitHub not to be called"
