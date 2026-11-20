#!/usr/bin/env bash
# Posts a reviewer's earlier pass again when it still stands for a pull request's head (decisions A160a).
# Usage: carry-review.sh "<reviewer name>" <pr-number> <head-sha> <main-ref>
#        Run in a checkout that holds the whole history of the head and of main. Needs GH_TOKEN (pull-requests: write).
#        Carried: writes `carried=true` to $GITHUB_OUTPUT and exits 0. Not carried: exits 0. Could not tell: exits 1.
set -euo pipefail

usage='Usage: carry-review.sh "<reviewer name>" <pr-number> <head-sha> <main-ref>'
reviewer="${1:?$usage}"; pr="${2:?$usage}"; head="${3:?$usage}"; main="${4:?$usage}"
not_carried() { echo "$reviewer reviews pull request #$pr again: $1."; exit 0; }
die() { echo "$1, so whether the earlier review still stands is not known and $reviewer reviews pull request #$pr again." >&2; exit 1; }

# A failed read stops here (decisions H7). Only the factory's own account posts a verdict; REST names it in full (A28).
comments=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
    --jq '.[] | select(.user.login == "github-actions[bot]") | {body: (.body // "")}') \
  || die "Could not read the comments of pull request #$pr from GitHub"
# Of any kind: a fail or an unfinished review after a pass means the pass no longer stands.
latest=$(jq -rs --arg start "**$reviewer: " '[.[].body | select(startswith($start))] | last // ""' <<<"$comments") \
  || die "The comments of pull request #$pr could not be read as GitHub returned them"
[ -n "$latest" ] || not_carried "it has no verdict there yet"
[ "$(head -n 1 <<<"$latest" | tr -d '\r')" = "**$reviewer: PASS**" ] || not_carried "its latest verdict there is not a pass"
# The last such line is the one post-verdict.sh wrote: everything a reviewer worded is above it.
reviewed=$(tr -d '\r' <<<"$latest" | sed -n 's/^<!-- factory:reviewed \([0-9a-f]\{40\}\) -->$/\1/p' | tail -n 1)
[ -n "$reviewed" ] || not_carried "its latest pass does not say which commit it was given for"

# The same test the owner's approval is carried by (decisions M456a).
status=0
why=$("$(dirname "$0")/only-merged-main.sh" "$reviewed" "$head" "$main" 2>&1) || status=$?
[ "$status" -le 1 ] || die "$why"
[ "$status" -eq 0 ] || not_carried "$why"

# Keeps the first line and the hidden list (decisions A160d). An earlier carried line goes, so one commit is named.
file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/carried-verdict.md"
{
  echo "**$reviewer: PASS**"
  echo
  echo "Carried forward from the review of ${reviewed:0:7}: every commit since is a merge of \`main\`, and this pull request's own change reads the same at ${head:0:7} as it did then. No review ran. <!-- factory:carried -->"
  tr -d '\r' <<<"$latest" | sed -e '1d' -e '/ <!-- factory:carried -->$/d' | cat -s
} > "$file"
gh pr comment "$pr" --body-file "$file" >/dev/null \
  || die "The earlier verdict could not be posted again on pull request #$pr"
echo "carried=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "$reviewer's pass of ${reviewed:0:7} is carried forward to ${head:0:7}: no review runs."
