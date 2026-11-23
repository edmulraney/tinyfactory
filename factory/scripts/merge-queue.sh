#!/usr/bin/env bash
# Keeps the pull requests that wait to merge, which merge-group.yml tests together and merges (decisions M455a).
# Usage: merge-queue.sh add <pr-number> <head-sha>                 it waits to merge, and merge-group.yml is started
#        merge-queue.sh list                                       prints "<pr-number> <head-sha>" for each, in the order added
#        merge-queue.sh remove <pr-number> <head-sha> <comment>    posts the comment, and it waits no longer
#        merge-queue.sh removed <pr-number> <head-sha>             prints the comment that removed it at that commit, or nothing
#        Needs GH_TOKEN (pull-requests: read; to add or remove, write; to add, actions: write) and, to list,
#        GITHUB_REPOSITORY, whose owner is the repo's.
#        A call to GitHub that fails stops it with a message and exit 1; `add` then tells the pull request too.
set -euo pipefail

usage="Usage: merge-queue.sh add <pr> <head> | list | remove <pr> <head> <comment> | removed <pr> <head>"
action="${1:?$usage}"; pr="${2:-}"; head="${3:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

die() { echo "$1" >&2; exit 1; }

# The pull request's newest record decides, and names the commit it was written for (decisions M455b).
# The REST list names the account in full: `gh pr view` shortens it to a login a person could hold.
newest() {
  local records
  records=$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate --jq '
    .[] | select(.user.login == "github-actions[bot]") | (.body // "") as $body
    | ($body | capture("^<!-- factory:merge-queue (?<event>added|removed) (?<head>[0-9a-f]+) -->")?) as $record
    | select($record) | {id, event: $record.event, head: $record.head, body: $body} | tojson') || return 1
  tail -n 1 <<<"$records"
}

case "$action" in
  add | remove | removed)
    [[ "$pr" =~ ^[0-9]+$ ]] && [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || { echo "$usage" >&2; exit 2; } ;;
esac

case "$action" in
  add)
    record=$(retry newest "$pr") \
      || not_merged "GitHub did not return this pull request's comments, so whether it already waits to merge is not known"
    if [ "$(jq -r '"\(.event) \(.head)"' <<<"${record:-null}")" != "added $head" ]; then
      retry gh pr comment "$pr" --body "<!-- factory:merge-queue added $head -->This pull request waits to merge at ${head:0:7}. The factory tests it with \`main\` together with every other pull request that waits, then merges it." >/dev/null \
        || not_merged "GitHub did not take the comment that makes this pull request wait to merge"
    fi
    if ! start_merge_group; then
      group_page=$("$script_dir/workflow-page.sh" merge-group.yml)
      # It keeps its place. The first line says what a person must do (decisions A371a, M455j).
      body="Start the test of this pull request's group on $group_page. This pull request waits to merge, and that run tests and merges it.

\`merge-group.yml\` could not be started.$(run_log)"
      echo "$body" >&2
      retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and the pull request could not be told so" >&2
      retry gh pr edit "$pr" --add-label needs-human >/dev/null || echo "and needs-human could not be added to it" >&2
      exit 1
    fi
    echo "pull request #$pr waits to merge at ${head:0:7}, and merge-group.yml was started" ;;
  list)
    repository="${GITHUB_REPOSITORY:?merge-queue.sh needs GITHUB_REPOSITORY, to know who the owner is}"
    owner="${repository%%/*}"
    # A draft is still being built (decisions A50b), and one its owner sent back waits for them (decisions M48).
    open=$(gh pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews --jq "
      .[] | select(.isDraft | not)
      | select([.reviews[] | select(.author.login == \"$owner\" and .state != \"COMMENTED\" and .state != \"PENDING\")] | last | .state != \"CHANGES_REQUESTED\")
      | \"\(.number) \(.headRefOid)\"") \
      || die "The open pull requests could not be read from GitHub, so which of them wait to merge is not known."
    waiting=""
    while read -r pr head; do
      [ -n "$pr" ] || continue
      record=$(newest "$pr") \
        || die "The comments of pull request #$pr could not be read from GitHub, so whether it waits to merge is not known."
      # A push since it was added: the new commit is checked, and added when it passes.
      [ "$(jq -r '"\(.event) \(.head)"' <<<"${record:-null}")" = "added $head" ] || continue
      waiting+="$(jq -r .id <<<"$record") $pr $head"$'\n'
    done <<<"$open"
    # GitHub numbers comments in the order they were made.
    sort -n <<<"$waiting" | sed -n 's/^[0-9]* //p' ;;
  remove)
    comment="${4:?$usage}"
    gh pr comment "$pr" --body "<!-- factory:merge-queue removed $head -->$comment" >/dev/null \
      || die "The comment that tells pull request #$pr it no longer waits to merge could not be posted, so it still waits." ;;
  removed)
    record=$(newest "$pr") \
      || die "The comments of pull request #$pr could not be read from GitHub, so whether it was left out of a merge is not known."
    [ "$(jq -r '"\(.event) \(.head)"' <<<"${record:-null}")" = "removed $head" ] || exit 0
    jq -r '.body | sub("^<!--[^>]*-->"; "")' <<<"$record" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
