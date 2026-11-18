#!/usr/bin/env bash
# Takes a shipped ticket back through a pull request: files the ticket that reverts it, and reopens it once that merged.
# Usage: revert.sh start <ticket-or-pr-number> <started-by> <owner-login>   files the ticket and starts its build
#        revert.sh shipped <ticket-number> <pr-number>   after a merge: reopens what the ticket took back, if it took any
#        Needs GH_TOKEN (start: issues and actions: write, pull-requests: read; shipped: issues and pull-requests: write).
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

usage="Usage: revert.sh start <ticket-or-pr-number> <started-by> <owner-login> | revert.sh shipped <ticket-number> <pr-number>"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"
# Both halves know the ticket by its title (decisions M19d).
titled="Take back pull request #"

case "${1:-}" in
  start)
    number="${2:?$usage}"; by="${3:?$usage}"; owner="${4:?$usage}"
    number="${number#\#}"
    die() { echo "Not started: $1. Nothing was changed." >&2; exit 1; }

    # Decisions M19a.
    [ "$by" = "$owner" ] || die "only the repo's owner, $owner, may take a ticket back, and $by started this run"
    [[ "$number" =~ ^[0-9]+$ ]] || die "\"$number\" is not the number of a ticket or a pull request"

    # One read says whether the number is a pull request or a ticket, and which pull requests closed a ticket.
    query='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) {
      issueOrPullRequest(number: $number) { __typename
        ... on PullRequest { number }
        ... on Issue { closedByPullRequestsReferences(first: 50, includeClosedPrs: true) { nodes { number merged mergedAt } } } } } }'
    # A ticket shipped, taken back and shipped again is closed by several: the newest is what production runs.
    pr=$(retry gh api graphql -F owner='{owner}' -F name='{repo}' -F number="$number" -f query="$query" --jq '
      .data.repository.issueOrPullRequest
      | if .__typename == "PullRequest" then .number
        else [.closedByPullRequestsReferences.nodes[] | select(.merged)] | sort_by(.mergedAt) | last | .number // empty end') \
      || die "GitHub did not say what #$number is, or it is neither a ticket nor a pull request"
    [ -n "$pr" ] || die "no merged pull request closes ticket #$number, so it shipped nothing to take back"

    view=$(retry gh pr view "$pr" --json state,mergeCommit,mergedAt,title) \
      || die "GitHub did not return pull request #$pr"
    commit=$(jq -r '.mergeCommit.oid // ""' <<<"$view"); title=$(jq -r .title <<<"$view")
    [ "$(jq -r .state <<<"$view")" = MERGED ] && [ -n "$commit" ] \
      || die "pull request #$pr is not merged, so it shipped nothing to take back"
    issue=$(retry "$script_dir/linked-issue.sh" "$pr") \
      || die "GitHub did not return the description of pull request #$pr, so the ticket it shipped is not known"

    # Listed, not searched: a search would miss a ticket seconds old. One closed as not planned took nothing back.
    earlier=$(retry gh api --method GET "repos/{owner}/{repo}/issues" -f state=all -f since="$(jq -r .mergedAt <<<"$view")" -f per_page=100 --paginate \
      --jq ".[] | select(.pull_request == null and .title == \"$titled$pr\" and (.state == \"open\" or .state_reason == \"completed\")) | .number") \
      || die "GitHub did not list the tickets, so whether pull request #$pr is already being taken back is not known"
    [ -z "$earlier" ] || die "ticket #$(head -n 1 <<<"$earlier") already takes back pull request #$pr"

    # A renamed file is listed under both its names. The type picks the engineer (decisions T19c).
    files=$(retry gh api "repos/{owner}/{repo}/pulls/$pr/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)') \
      || die "GitHub did not list the files pull request #$pr changed, so who takes it back is not known"
    if "$script_dir/protected-paths.sh" <<<"$files" >/dev/null; then type=chore; name=Esme; else type=factory; name=Fred; fi

    shipped="pull request #$pr (\`$title\`)"
    [ -z "$issue" ] || shipped+=", which shipped ticket #$issue"
    body="## Change
Take back $shipped: the owner asked for it. On your branch run \`git revert --no-edit $commit\`, and change nothing else. Where a later commit changed the same lines, resolve the conflict so that what later pull requests shipped stays and only what #$pr shipped goes. If that cannot be done, or the commit is already reverted, say so here and add \`needs-human\`.
"
    if [ "$type" = factory ]; then
      body+="
## How we will know it works
- \`pnpm lint\` and \`pnpm test\` pass.
- \`main\` holds nothing of what #$pr shipped, and all that later pull requests shipped."
    else
      body+="
## Docs to update
None but what the revert puts back."
    fi

    # Neither call is made twice: each may have happened (decisions M26). ready, as no build starts without it (decisions T269b).
    url=$(gh issue create --title "$titled$pr" --label "$type" --label ready --body "$body") \
      || die "the ticket that takes back pull request #$pr could not be filed"
    ticket=${url##*/}
    [[ "$ticket" =~ ^[0-9]+$ ]] \
      || { echo "Not started: GitHub did not say which ticket it filed to take back pull request #$pr. Find it, take the \`ready\` label off it and add it again." >&2; exit 1; }
    # Started by number: a label added with a workflow's own token starts no build (decisions A241c).
    if ! gh workflow run implement.yml -f issue="$ticket" >/dev/null; then
      retry gh issue close "$ticket" --reason "not planned" >/dev/null \
        || { echo "Not started: the build of ticket #$ticket, which takes back pull request #$pr, could not be started. Take the \`ready\` label off it and add it again." >&2; exit 1; }
      die "the build that takes back pull request #$pr could not be started, and the ticket filed for it, #$ticket, was closed"
    fi
    echo "ticket #$ticket takes back pull request #$pr: its build was started, and $name opens the pull request that reverts ${commit:0:7}"
    ;;

  shipped)
    ticket="${2:?$usage}"; by="${3:?$usage}"
    die() { echo "$1" >&2; exit 1; }
    title=$(retry gh issue view "$ticket" --json title --jq .title) \
      || die "GitHub did not return ticket #$ticket, so whether pull request #$by took a ticket back is not known."
    [[ "$title" =~ ^"$titled"([0-9]+)$ ]] || exit 0
    pr="${BASH_REMATCH[1]}"
    issue=$(retry "$script_dir/linked-issue.sh" "$pr") \
      || die "GitHub did not return the description of pull request #$pr, so the ticket that pull request #$by took back was not reopened."
    body="Taken back: pull request #$by reverted pull request #$pr, and \`main\` no longer holds its change."
    if [ -z "$issue" ]; then
      retry gh pr comment "$pr" --body "$body" >/dev/null || die "Pull request #$pr could not be told that pull request #$by took it back."
      echo "pull request #$pr, which closed no ticket, was told that pull request #$by took it back"
      exit 0
    fi
    # Every step is tried (decisions M30).
    failed=0
    retry gh issue reopen "$issue" >/dev/null || { echo "Ticket #$issue could not be reopened." >&2; failed=1; }
    # Decisions T19a.
    retry gh issue edit "$issue" --add-label reverted --remove-label deployed >/dev/null \
      || { echo "Ticket #$issue could not be labelled \`reverted\` in place of \`deployed\`." >&2; failed=1; }
    retry gh issue comment "$issue" --body "$body To build this ticket again, add \`ready\`." >/dev/null \
      || { echo "Ticket #$issue could not be told that pull request #$by took it back." >&2; failed=1; }
    [ "$failed" -eq 0 ] || exit 1
    echo "ticket #$issue was reopened as reverted: pull request #$by took back pull request #$pr"
    ;;

  *) echo "$usage" >&2; exit 1 ;;
esac
