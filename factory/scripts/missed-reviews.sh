#!/usr/bin/env bash
# Starts what the owner's latest review asks of each factory pull request in conflict, when GitHub ran nothing for it.
# Usage: missed-reviews.sh   (by flag-idle.yml, on its schedule)
#        Needs GH_TOKEN (pull-requests: read; issues and actions: write) and GITHUB_REPOSITORY, whose owner is the repo's.
#        A call to GitHub that fails ends in a message and exit 1, once every other pull request has been looked at.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository="${GITHUB_REPOSITORY:?missed-reviews.sh needs GITHUB_REPOSITORY, to know who the owner is}"
owner="${repository%%/*}"

die() { echo "$1" >&2; exit 1; }

# GitHub runs no workflow for a review of a pull request in conflict, so only those are looked at (decisions A675a).
# `app/claude` is how gh writes the app that opens the factory's pull requests. A draft is still being built (decisions A50b).
open=$(gh pr list --state open --limit 100 --json number,author,isDraft,mergeable,headRefOid \
    --jq '.[] | select(.author.login == "app/claude" and (.isDraft | not) and .mergeable == "CONFLICTING") | "\(.number) \(.headRefOid)"') \
  || die "The open pull requests could not be read from GitHub, so no owner's review of one in conflict was acted on."

failed=""; started=0
# missed <pr> <what was not read or done>: notes it and moves on to the next pull request.
missed() { echo "Pull request #$1: $2." >&2; failed+=" #$1"; }

while read -r pr head; do
  [ -n "$pr" ] || continue
  # The REST list is in the order the reviews were submitted. gh runs the filter on each page, so tail picks the last.
  reviews=$(gh api "repos/{owner}/{repo}/pulls/$pr/reviews?per_page=100" --paginate \
      --jq ".[] | select(.user.login == \"$owner\" and .state != \"PENDING\") | \"\(.id) \(.state) \(.commit_id) \(.submitted_at)\"") \
    || { missed "$pr" "its reviews could not be read"; continue; }
  read -r id state commit submitted <<<"$(grep -v ' COMMENTED ' <<<"$reviews" | tail -n 1)" || true
  # approve-merge.sh and the owner's round each act only on a verdict on the commit that is there now.
  [ "${commit:-}" = "$head" ] || continue
  # approve-merge.sh takes the owner's last review of any state, so a later comment-only review stops it too.
  [ "$state" != APPROVED ] || [ "$(tail -n 1 <<<"$reviews" | cut -d' ' -f2)" = APPROVED ] || continue
  case "$state" in
    APPROVED) workflow=approve-merge.yml; what="its merge" ;;
    CHANGES_REQUESTED) workflow=fix.yml; what="the owner's fix round" ;;
    *) continue ;;
  esac

  # A review GitHub did run approve-merge.yml for was acted on when it came, before the conflict.
  ran=$(gh api --method GET "repos/{owner}/{repo}/actions/workflows/approve-merge.yml/runs" \
      -f event=pull_request_review -f head_sha="$head" -f "created=>=$submitted" --jq '.total_count') \
    || { missed "$pr" "whether GitHub ran approve-merge.yml for review $id could not be read"; continue; }
  [ "$ran" = 0 ] || continue
  # Acted on once: by this look, which records it first, or, for a request, by a round that ran for it (decisions A675b, A396b).
  started_before=$("$script_dir/fix-rounds.sh" "$pr" review-started "$id") \
    || { missed "$pr" "whether review $id was acted on before could not be read"; continue; }
  [ "$started_before" -eq 0 ] || continue
  if [ "$state" = CHANGES_REQUESTED ]; then
    rounds=$("$script_dir/fix-rounds.sh" "$pr" owner "$id") \
      || { missed "$pr" "whether the owner's fix round ran for review $id could not be read"; continue; }
    [ "$rounds" -eq 0 ] || continue
  fi

  gh api "repos/{owner}/{repo}/issues/$pr/comments" -f body="<!-- factory:review-started $id -->Nothing to do: the factory is starting $what, which the owner's review asked for.

GitHub runs no workflow for a review of a pull request in conflict with \`main\`, so the review started nothing when it was sent." >/dev/null \
    || { missed "$pr" "the comment that records review $id could not be posted, so $what was not started"; continue; }
  # Started once and never retried: a start that failed may have happened (decisions M26).
  if gh workflow run "$workflow" -f pr="$pr" >/dev/null; then
    echo "started $what for pull request #$pr, which the owner reviewed while it was in conflict"
    started=$((started + 1))
  else
    page=$("$script_dir/workflow-page.sh" "$workflow" pr="$pr")
    # The first line says what a person must do (decisions A371a).
    gh api "repos/{owner}/{repo}/issues/$pr/comments" -f body="Start $what on $page.

GitHub did not start it, though the comment before this one says the factory was starting it." >/dev/null \
      || echo "Could not say on pull request #$pr that $what was not started." >&2
    missed "$pr" "GitHub did not start $workflow for $what"
  fi
done <<<"$open"
[ -z "$failed" ] || die "The owner's review of these pull requests in conflict could not be read or acted on:$failed."
[ "$started" -ne 0 ] || echo "no factory pull request in conflict holds an owner's review that GitHub ran nothing for: nothing was started"
