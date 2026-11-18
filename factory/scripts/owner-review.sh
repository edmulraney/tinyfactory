#!/usr/bin/env bash
# Prints the id of the owner's "Request changes" review of a pull request's current commit, or nothing.
# Usage: owner-review.sh <pr-number> <owner-login> [file]
#        Given a file, appends what the owner asked for to it. Needs GH_TOKEN (pull-requests: read).
set -euo pipefail

usage="Usage: owner-review.sh <pr-number> <owner-login> [file]"
pr="${1:?$usage}"; owner="${2:?$usage}"; file="${3:-}"

die() { echo "$1" >&2; exit 1; }

# Both go into a filter and into calls, so anything that is not a number or a login is refused.
[[ "$pr" =~ ^[0-9]+$ ]] || die "\"$pr\" is not a pull request number."
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || die "\"$owner\" is not a GitHub login."

head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid) \
  || die "Could not read pull request #$pr from GitHub, so whether its owner sent it back is not known."
# The REST list is in the order the reviews were submitted. gh runs the filter on each page, so tail picks the last.
verdicts=$(gh api "repos/{owner}/{repo}/pulls/$pr/reviews?per_page=100" --paginate \
    --jq ".[] | select(.user.login == \"$owner\" and .state != \"COMMENTED\" and .state != \"PENDING\") | \"\(.id) \(.state) \(.commit_id)\"") \
  || die "Could not read the reviews of pull request #$pr from GitHub, so whether its owner sent it back is not known."
read -r id state commit <<<"$(tail -n 1 <<<"$verdicts")" || true
if [ "${state:-}" != CHANGES_REQUESTED ] || [ "${commit:-}" != "$head" ]; then exit 0; fi

if [ -n "$file" ]; then
  summary=$(gh api "repos/{owner}/{repo}/pulls/$pr/reviews/$id" --jq '.body // ""') \
    || die "Could not read review $id of pull request #$pr from GitHub, so what its owner asked for is not known."
  # Every comment on the pull request's lines, kept to this review's: only that list says which line each is on.
  comments=$(gh api "repos/{owner}/{repo}/pulls/$pr/comments?per_page=100" --paginate \
      --jq ".[] | select(.pull_request_review_id == $id) | \"--- \(.path)\(if (.line // .original_line) then \", line \(.line // .original_line)\" else \"\" end)\n\(.body)\n\"") \
    || die "Could not read the comments of review $id on pull request #$pr from GitHub, so what its owner asked for is not known."
  # Written in one go, once everything is read: a failed read leaves the file untouched.
  {
    echo "===== the owner asked for changes ====="
    echo "The repo's owner sent this pull request back with a \"Request changes\" review of the commit that is there now."
    echo "Make each change it asks for, or answer it in a comment on the pull request saying why not."
    echo
    if [ -n "$summary" ]; then printf '%s\n\n' "$summary"; fi
    if [ -n "$comments" ]; then printf '%s\n\n' "$comments"; fi
  } >> "$file"
fi
echo "$id"
