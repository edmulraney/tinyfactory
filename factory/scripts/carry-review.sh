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

# The head as git names it in full, to compare with the commit that passed.
full=$(git rev-parse --quiet --verify "$head^{commit}") || die "The head commit $head is not in this checkout"
head="$full"
git rev-parse --quiet --verify "$main^{commit}" >/dev/null || die "$main is not in this checkout"
git cat-file -e "$reviewed^{commit}" 2>/dev/null || not_carried "the commit it passed, ${reviewed:0:7}, is no longer in the repo"

# Along the branch's own line (first parents): a branch that was rewritten never reaches the commit that passed.
commit="$head"
while [ "$commit" != "$reviewed" ]; do
  line=$(git rev-list --parents -n 1 "$commit") || die "The parents of ${commit:0:7} could not be read"
  # shellcheck disable=SC2086
  set -- $line
  [ $# -eq 3 ] || not_carried "${commit:0:7}, pushed since it passed ${reviewed:0:7}, is not a merge of main"
  git merge-base --is-ancestor "$3" "$main" 2>/dev/null \
    || not_carried "${commit:0:7}, pushed since it passed ${reviewed:0:7}, merges a commit that is not on main"
  commit="$2"
done

# The diff a reviewer read, without the blob ids and line numbers a merge elsewhere moves (decisions A160b).
change() {
  local base
  base=$(git merge-base "$main" "$1") || return 1
  git diff --no-color --no-ext-diff --no-textconv --no-renames --binary --unified=3 "$base" "$1" \
    | sed -E -e '/^index [0-9a-f]+\.\.[0-9a-f]+( [0-7]+)?$/d' -e 's/^@@ -[0-9,]+ \+[0-9,]+ @@.*$/@@/'
}
before=$(change "$reviewed") || die "The change at ${reviewed:0:7} could not be read"
after=$(change "$head") || die "The change at ${head:0:7} could not be read"
[ "$before" = "$after" ] || not_carried "its change does not read the same at ${head:0:7} as at ${reviewed:0:7}, which it passed"

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
