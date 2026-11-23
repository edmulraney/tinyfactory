#!/usr/bin/env bash
# Tests for missed-reviews.sh: the owner's review of a pull request in conflict starts what it asks for, once.
. "$(dirname "$0")/helpers.sh"

head=5555555555555555555555555555555555555555
other=6666666666666666666666666666666666666666

# $T/pulls holds the open pull requests, $T/reviews-<n> and $T/comments-<n> the reviews and comments of one,
# $T/runs the approve-merge.yml runs GitHub made for a review; $T/fail lists the gh calls, by their first words, that fail.
github() {
  : > "$T/fail"; echo '[]' > "$T/pulls"; echo 0 > "$T/runs"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --limit 100 --json number,author,isDraft,mergeable,headRefOid "*) json "$(cat "$T/pulls")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/"*"/reviews?per_page=100 --paginate --jq "*)
        n=${2#*/pulls/}; json "$(cat "$T/reviews-${n%/reviews*}" 2>/dev/null || echo "[]")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/approve-merge.yml/runs -f event=pull_request_review -f head_sha="*)
        json "{\"total_count\": $(cat "$T/runs")}" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*)
        n=${2#*/issues/}; json "$(cat "$T/comments-${n%/comments*}" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments -f body="*) : ;;
      "workflow run "*) echo "created workflow_dispatch event" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# open <pr> <author> <draft> <mergeable> [head]
open() {
  jq --argjson n "$1" --arg login "$2" --argjson draft "$3" --arg mergeable "$4" --arg head "${5:-$head}" \
    '. + [{number: $n, author: {login: $login}, isDraft: $draft, mergeable: $mergeable, headRefOid: $head}]' "$T/pulls" > "$T/pulls.new"
  mv "$T/pulls.new" "$T/pulls"
}
# reviewed <pr> <id> <login> <state> [commit]: adds a review, of the head unless another commit is given.
reviewed() {
  jq --argjson id "$2" --arg login "$3" --arg state "$4" --arg commit "${5:-$head}" \
    '. + [{id: $id, user: {login: $login}, state: $state, commit_id: $commit, submitted_at: "2026-11-23T03:14:54Z"}]' \
    <(cat "$T/reviews-$1" 2>/dev/null || echo "[]") > "$T/reviews.new"
  mv "$T/reviews.new" "$T/reviews-$1"
}
# commented <pr> <body>: adds a comment of the factory's.
commented() {
  jq --arg body "$2" '. + [{id: (length + 1), user: {login: "github-actions[bot]"}, body: $body}]' \
    <(cat "$T/comments-$1" 2>/dev/null || echo "[]") > "$T/comments.new"
  mv "$T/comments.new" "$T/comments-$1"
}
look() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=repo-owner/myapp "$scripts/missed-reviews.sh"; }

scenario "the owner's request for changes of a pull request in conflict, which GitHub ran nothing for, starts the owner's fix round"
github
open 753 app/claude false CONFLICTING
reviewed 753 41 repo-owner CHANGES_REQUESTED
look
expect_status 0
expect_call "gh api repos/{owner}/{repo}/issues/753/comments -f body=<!-- factory:review-started 41 -->Nothing to do: the factory is starting the owner's fix round"
expect_call "gh workflow run fix.yml -f pr=753"
expect_no_call "approve-merge.yml -f pr="
expect_output "started the owner's fix round for pull request #753, which the owner reviewed while it was in conflict"

scenario "the owner's approval of a pull request in conflict, which GitHub ran nothing for, starts its merge"
github
open 753 app/claude false CONFLICTING
reviewed 753 41 repo-owner CHANGES_REQUESTED
reviewed 753 42 repo-owner APPROVED
look
expect_status 0
expect_call "gh api repos/{owner}/{repo}/issues/753/comments -f body=<!-- factory:review-started 42 -->Nothing to do: the factory is starting its merge"
expect_call "gh workflow run approve-merge.yml -f pr=753"
expect_no_call "gh workflow run fix.yml"
expect_output "started its merge for pull request #753"

scenario "records the review before it starts anything, so that a start that failed is not made again"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
look
[ "$(grep -n -- '-f body=<!-- factory:review-started 42' "$T/calls" | cut -d: -f1)" -lt "$(grep -n '^gh workflow run' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the record before the start"

scenario "starts nothing for a review already acted on: by this look, or by an owner's round that ran for it"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
commented 753 "<!-- factory:review-started 42 -->Nothing to do: the factory is starting its merge."
open 754 app/claude false CONFLICTING
reviewed 754 43 repo-owner CHANGES_REQUESTED
commented 754 "<!-- factory:owner-round 43 -->The owner's fix round: the engineer's session ran."
look
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "-f body="
expect_output "nothing was started"

scenario "a record of another review, or one a person wrote, does not stop the latest review being acted on"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
commented 753 "<!-- factory:review-started 41 -->Nothing to do: the factory is starting the owner's fix round."
jq '. + [{id: 9, user: {login: "repo-owner"}, body: "<!-- factory:review-started 42 -->"}]' "$T/comments-753" > "$T/c" && mv "$T/c" "$T/comments-753"
look
expect_call "gh workflow run approve-merge.yml -f pr=753"

scenario "starts nothing when GitHub ran approve-merge.yml for the review, which came before the conflict"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
echo 1 > "$T/runs"
look
expect_status 0
expect_call "-f event=pull_request_review -f head_sha=$head -f created=>=2026-11-23T03:14:54Z"
expect_no_call "gh workflow run"

scenario "starts nothing for a pull request that does not conflict, or whose conflict GitHub has not yet worked out"
github
open 753 app/claude false MERGEABLE
reviewed 753 42 repo-owner APPROVED
open 754 app/claude false UNKNOWN
reviewed 754 43 repo-owner APPROVED
look
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "reviews"

scenario "starts nothing for a draft, a pull request a person opened, a review of an older commit, or a later comment-only review"
github
open 751 app/claude true CONFLICTING
reviewed 751 40 repo-owner APPROVED
open 752 repo-owner false CONFLICTING
reviewed 752 41 repo-owner APPROVED
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED "$other"
open 754 app/claude false CONFLICTING
reviewed 754 43 someone-else APPROVED
open 755 app/claude false CONFLICTING
reviewed 755 44 repo-owner APPROVED
reviewed 755 45 repo-owner COMMENTED
look
expect_status 0
expect_no_call "gh workflow run"

scenario "the latest verdict counts: an approval after a request for changes starts no round"
github
open 753 app/claude false CONFLICTING
reviewed 753 41 repo-owner APPROVED
reviewed 753 42 repo-owner CHANGES_REQUESTED
reviewed 753 43 repo-owner COMMENTED
look
expect_call "gh workflow run fix.yml -f pr=753"
expect_no_call "approve-merge.yml -f pr="

scenario "stops with a message when the pull requests cannot be read: that is not 'none in conflict'"
github
echo "pr list" > "$T/fail"
look
expect_status 1
expect_output "The open pull requests could not be read from GitHub, so no owner's review of one in conflict was acted on."
expect_no_output "nothing was started"

scenario "a read that fails for one pull request is no answer: it starts nothing there, goes on to the next, and fails naming it"
for call in "api repos/{owner}/{repo}/pulls/753/reviews" "api --method GET repos/{owner}/{repo}/actions/workflows/approve-merge.yml/runs" "api repos/{owner}/{repo}/issues/753/comments?per_page=100"; do
  github
  open 753 app/claude false CONFLICTING
  reviewed 753 42 repo-owner CHANGES_REQUESTED
  open 754 app/claude false CONFLICTING "$other"
  reviewed 754 43 repo-owner APPROVED "$other"
  echo "$call" > "$T/fail"
  look
  expect_status 1
  expect_no_call "gh workflow run fix.yml -f pr=753"
  expect_no_call "issues/753/comments -f body="
  expect_output "these pull requests in conflict could not be read or acted on: #753"
done

scenario "starts nothing when the record cannot be posted"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
echo "api repos/{owner}/{repo}/issues/753/comments -f body=<!--" > "$T/fail"
look
expect_status 1
expect_no_call "gh workflow run"
expect_output "the comment that records review 42 could not be posted, so its merge was not started"

scenario "a start GitHub refused is not asked again: the pull request is told the command, and the script fails"
github
open 753 app/claude false CONFLICTING
reviewed 753 42 repo-owner APPROVED
echo "workflow run approve-merge.yml" > "$T/fail"
look
expect_status 1
[ "$(grep -c '^gh workflow run' "$T/calls")" = 1 ] || fail "expected the start to be asked for once"
expect_call "gh api repos/{owner}/{repo}/issues/753/comments -f body=Start its merge: \`gh workflow run approve-merge.yml -f pr=753\`"$'\n\n'
expect_output "GitHub did not start approve-merge.yml for its merge"
