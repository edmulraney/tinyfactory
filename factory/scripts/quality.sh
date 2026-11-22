#!/usr/bin/env bash
# Prints each merged pull request of a product ticket, in merge order, with its fix rounds and rework (decisions H573a).
# Usage: quality.sh          (in a clone whose `origin` is the repo on GitHub; the history of `main` is fetched)
#        quality.sh --json   a line of JSON for each such pull request, which metrics.sh reads: its number, the lines it
#                            added, and how many of them were reworked, null while no pull request has merged since
#        Rework is the share of the lines a pull request added that the next ten merged pull requests changed or deleted.
#        Needs GH_TOKEN (pull-requests, issues and contents: read).
set -euo pipefail

die() { echo "$1" >&2; exit 1; }
json=no
[ "${1:-}" != --json ] || json=yes

query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) {
  pullRequests(states: MERGED, baseRefName: "main", first: 100, after: $endCursor) {
    nodes { number title mergedAt mergeCommit { oid }
      closingIssuesReferences(first: 10) { nodes { labels(first: 100) { nodes { name } } } } }
    pageInfo { hasNextPage endCursor } } } }'
merged=$(gh api graphql --paginate -F owner='{owner}' -F name='{repo}' -f query="$query" \
    --jq '.data.repository.pullRequests.nodes[] | tojson') \
  || die "Could not list the merged pull requests from GitHub, so no pull request's fix rounds or rework are known."
# The ticket of a product engineer is the one labelled neither `factory` nor `research`, as begin-fix-round.sh tells them apart.
merged=$(jq -rs 'sort_by(.mergedAt) | to_entries[]
    | (.value.closingIssuesReferences.nodes | map([.labels.nodes[].name])) as $tickets
    | [.key, .value.number, (.value.mergeCommit.oid // ""),
       ($tickets != [] and all($tickets[]; index("factory") == null and index("research") == null)),
       (.value.title | gsub("[|\t\r\n]"; " "))] | @tsv' <<<"$merged") \
  || die "The merged pull requests could not be read as GitHub returned them, so no pull request's fix rounds or rework are known."
[ -n "$merged" ] || { [ "$json" = yes ] || echo "No pull request has merged."; exit 0; }

whole=()
[ "$(git rev-parse --is-shallow-repository)" = false ] || whole=(--unshallow)
git fetch --quiet "${whole[@]}" origin main \
  || die "Could not fetch the history of main, so no pull request's rework is known."

commits=()
while IFS=$'\t' read -r _ _ commit _; do
  [[ "$commit" =~ ^[0-9a-f]{40,64}$ ]] && git cat-file -e "$commit^{commit}" 2>/dev/null \
    || die "The history of main does not hold the commit a merged pull request left, \"$commit\", so no pull request's rework is known."
  commits+=("$commit")
done <<<"$merged"

# own_lines <commit> <at>: how many lines of the files at <at> git blame gives to <commit> (decisions H573b).
own_lines() {
  local files added path blamed lines=0
  files=$(git -c core.quotePath=false diff --numstat --no-renames --diff-filter=AM "$1^" "$2") \
    || die "Git could not list the files changed from ${1:0:7} to ${2:0:7}, so the rework is not known."
  while IFS=$'\t' read -r added _ path; do
    # Git counts no lines in a binary file.
    [ -n "$path" ] && [ "$added" != - ] || continue
    blamed=$(git blame --porcelain "$1^..$2" -- "$path") \
      || die "Git could not blame $path at ${2:0:7}, so the rework is not known."
    lines=$((lines + $(grep -c "^$1 " <<<"$blamed" || true)))
  done <<<"$files"
  echo "$lines"
}

[ "$json" = yes ] || printf '%s\n' "| Pull request | Fix rounds | Failed by | Rework |" "|---|---|---|---|"
while IFS=$'\t' read -r at pr commit product title; do
  [ "$product" = true ] || continue
  later=$((${#commits[@]} - 1 - at)); [ "$later" -le 10 ] || later=10
  added=$(own_lines "$commit" "$commit")
  reworked=null
  if [ "$later" -gt 0 ]; then
    kept=$(own_lines "$commit" "${commits[$((at + later))]}")
    reworked=$((added - kept))
  fi
  if [ "$json" = yes ]; then
    echo "{\"pr\":$pr,\"added\":$added,\"reworked\":$reworked}"
    continue
  fi
  if [ "$added" -eq 0 ]; then
    rework="it added no line"
  elif [ "$later" -eq 0 ]; then
    rework="not known: no pull request has merged since"
  else
    rework="$((reworked * 100 / added))% of $added added line"; [ "$added" -eq 1 ] || rework+=s
    [ "$later" -eq 10 ] || rework+=", after $later of the ten pull requests"
  fi

  # Only the factory's own account records a round or posts a verdict; REST names it in full (decisions A28).
  comments=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
      --jq '.[] | select(.user.login == "github-actions[bot]") | {body: (.body // "")}') \
    || die "Could not read the comments of pull request #$pr from GitHub, so its fix rounds are not known."
  # Decisions H573c.
  rounds=$(jq -rs 'reduce .[].body as $body ({rounds: [], failed: []};
      ($body | split("\n")[0] | rtrimstr("\r") | capture("^\\*\\*(?<who>[A-Za-z]+)[^*]*: FAIL\\*\\*$") // null) as $verdict
      | if $verdict then .failed |= (. + [$verdict.who] | unique)
        elif $body | startswith("<!-- factory:fix-round -->") then
          .rounds += [if .failed == [] then "no reviewer" else .failed | join(" and ") end] | .failed = []
        else . end)
    | "\(.rounds | length)\t\(.rounds | to_entries | map("round \(.key + 1): \(.value)") | join("; "))"' <<<"$comments") \
    || die "The comments of pull request #$pr could not be read as GitHub returned them, so its fix rounds are not known."
  printf '| #%s %s | %s | %s | %s |\n' "$pr" "$title" "${rounds%%$'\t'*}" "${rounds#*$'\t'}" "$rework"
done <<<"$merged"
