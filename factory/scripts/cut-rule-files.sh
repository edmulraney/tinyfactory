#!/usr/bin/env bash
# Files a ticket that cuts each rule file `main` holds over its word budget, labelled `ready` (decisions H476a).
# Usage: cut-rule-files.sh                   after a merge. A file with such a ticket open gets no second, and the third
#                                            for one file in a calendar month (UTC) is a proposal that waits for the owner
#        cut-rule-files.sh count <yyyy-mm>   prints "<tickets> <file>" for each file such a ticket was opened for that month
#        Needs GH_TOKEN (contents: read; issues: write). A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }

# opened <yyyy-mm>: the file of each such ticket opened in that month, one a line. The title is as decisions H476e says.
opened() {
  local titles
  titles=$(gh api --method GET "repos/{owner}/{repo}/issues" -f state=all -f labels=factory -f since="$1-01T00:00:00Z" -f per_page=100 --paginate \
    --jq ".[] | select(.pull_request == null and (.created_at | startswith(\"$1\"))) | .title") || return 1
  sed -n 's/^Cut `\(.*\)` to budget$/\1/p' <<<"$titles"
}

if [ "${1:-}" = count ]; then
  [[ "${2:-}" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "Usage: cut-rule-files.sh count <yyyy-mm>"
  files=$(opened "$2") || die "Could not list the tickets opened in $2, so the tickets that cut a rule file are not counted."
  [ -z "$files" ] || sort <<<"$files" | uniq -c | sed -E 's/^ *([0-9]+) /\1 /'
  exit 0
fi
[ $# -eq 0 ] || die "Usage: cut-rule-files.sh | cut-rule-files.sh count <yyyy-mm>"

# The checkout is main before the merge, so the merged files are downloaded, as apply-setup.sh does.
tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
gh api "repos/{owner}/{repo}/tarball/main" | tar -xz --strip-components=1 -C "$tree" \
  || die "Could not download main from GitHub, so whether a rule file is over its word budget is not known, and no ticket was filed."
over=$(cd "$tree" && "$script_dir/check-rule-files.sh" --over) \
  || die "The list of rule files on main could not be read, so no ticket was filed: $over"
[ -n "$over" ] || { echo "no rule file on main is over its word budget"; exit 0; }

# Listed: a search would miss a ticket seconds old.
open=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | "\(.number) \(.title)"') \
  || die "Could not list the open tickets, so whether one already cuts a rule file is not known, and no ticket was filed."
month=$(date -u +%Y-%m)
before=$(opened "$month") \
  || die "Could not list the tickets opened in $month, so whether a rule file needs a proposal is not known, and no ticket was filed."

while read -r words budget file; do
  title="Cut \`$file\` to budget"
  held=$(awk -v title="$title" 'substr($0, length($1) + 2) == title { print $1; exit }' <<<"$open")
  if [ -n "$held" ]; then
    echo "$file holds $words words and its budget is $budget; issue #$held is open to cut it, so no second ticket was filed"
    continue
  fi
  proves="## How we will know it works
\`pnpm lint\` passes, and prints no line saying that \`$file\` is over its budget."
  # Decisions H476d.
  if [ "$(grep -cxF -- "$file" <<<"$before" || true)" -ge 2 ]; then
    # The first line says what a person must do (decisions A371a).
    body="Choose one of the two below and edit \"Change\" to say which, then add the \`ready\` label: nothing is built until then.

## Change
\`$file\` holds $words words on \`main\`, and its budget in \`factory/rule-files.txt\` is $budget words. Two tickets opened in $month already cut it. A file cut this often has too small a budget, or too much is put into it. The owner chooses one:

- a larger budget, with its decision row;
- a split of the file, so that what only some tasks need is in a document those tasks read.

$proves"
    url=$(gh issue create --title "$title" --label factory --label proposal --body "$body") \
      || die "Could not file the proposal for $file, over its word budget for the third time in $month; the next merge files it."
    echo "$file holds $words words and its budget is $budget, for the third time in $month: a proposal waits for the owner, $url"
    continue
  fi
  body="## Change
\`$file\` holds $words words on \`main\`, and its budget in \`factory/rule-files.txt\` is $budget words. Cut the file to its budget: move what only some tasks need to the document those tasks read, and delete what no agent needs to do its work well, to avoid a mistake or to save tokens (\`TASTE.md\`, \"Writing\"). Do not raise the budget.

$proves"
  # ready at filing: start-waiting.sh, which ship.sh runs next, starts it in its turn (decisions H476c).
  url=$(gh issue create --title "$title" --label factory --label ready --body "$body") \
    || die "Could not file the ticket that cuts $file to its word budget; the next merge files it."
  echo "$file holds $words words and its budget is $budget: filed with ready, and its build starts when a place is free, $url"
done <<<"$over"
