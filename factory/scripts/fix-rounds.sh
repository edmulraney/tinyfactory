#!/usr/bin/env bash
# Prints how many fix rounds a pull request has used, so that everything that needs the count counts it one way.
# Usage: fix-rounds.sh <pr-number> [owner [review-id] | conflict <head|all> | fresh-run <ci.yml-id> | start-checks <head> |
#        review-started <review-id>]
#        [review-id]  counts only the owner's rounds begun for that "Request changes" review.
#        <head|all>   counts the rounds for a conflict begun at that commit, or at every commit.
#        <head>       after start-checks, counts the times approve-merge.sh started the checks of that commit.
#        <review-id>  after review-started, counts the times missed-reviews.sh acted on that review of the owner's.
#        Needs GH_TOKEN (pull-requests: read).
set -euo pipefail

usage="Usage: fix-rounds.sh <pr-number> [owner [review-id] | conflict <head|all> | fresh-run <ci.yml-id> | start-checks <head> | review-started <review-id>]"
pr="${1:?$usage}"; whose="${2:-}"; head="${3:-}"
case "$whose" in
  # A round is a comment record-fix-round.sh posted, starting with the marker (decisions A89c, A28).
  "") marker="<!-- factory:fix-round -->" ;;
  # The owner's rounds are not among the three, and their own marker starts the retro (decisions A48d).
  owner)
    # The id goes into the filter below, so anything that is not one is refused.
    [[ "$head" =~ ^[0-9]*$ ]] || { echo "$usage" >&2; exit 2; }
    # A record names the review its round was begun for (decisions A396b), so the marker without one matches every record.
    marker="<!-- factory:owner-round ${head:+$head }" ;;
  # A round for only a conflict is in neither count above: one at a head refuses another there (decisions A124g).
  conflict)
    # The commit goes into the filter below, so anything that is not one is refused.
    [[ "$head" =~ ^([0-9a-f]{7,64}|all)$ ]] || { echo "$usage" >&2; exit 2; }
    # A record names the head its round began with, so the marker without one matches every record.
    marker="<!-- factory:conflict-round "; [ "$head" = all ] || marker+="$head -->" ;;
  # A round only for a ci run with that ci.yml is in no count above: one refuses another (decisions A142b).
  fresh-run)
    [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || { echo "$usage" >&2; exit 2; }
    marker="<!-- factory:fresh-run-round $head -->" ;;
  # A start of the checks is a comment approve-merge.sh posted, which names the commit (decisions M543b).
  start-checks)
    [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || { echo "$usage" >&2; exit 2; }
    marker="<!-- factory:checks-started $head -->" ;;
  # A review GitHub ran nothing for is acted on once, recorded by a comment naming it (decisions A675b).
  review-started)
    [[ "$head" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
    marker="<!-- factory:review-started $head -->" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
# An id per round and not a length, as gh runs the filter on each page; a failed read is not "no round" (decisions H7).
# The REST list names the account in full: `gh pr view` shortens it to a login a person could hold.
rounds=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
    --jq ".[] | select(.user.login == \"github-actions[bot]\" and ((.body // \"\") | startswith(\"$marker\"))) | .id") \
  || { echo "Could not read the comments of pull request #$pr from GitHub, so its fix rounds are not known." >&2; exit 1; }
grep -c . <<<"$rounds" || true
