#!/usr/bin/env bash
# Has Adam and Ryan review each known case again with one model, and prints which known problems they found.
# Usage: benchmark.sh <model> <effort>   (from the repo root of a full clone, with the `claude` CLI signed in)
#        A case is factory/benchmark/<pull request>.json: {commit, ticket: {title, body}, problems: [{problem, files, pattern}]}.
#        Prints a Markdown table, a row for each known problem, then what a review cost and how long it took.
set -euo pipefail

die() { echo "$1" >&2; exit 1; }
[ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || die "Usage: benchmark.sh <model> <effort>"
model="$1"
effort="$2"

set -- factory/benchmark/*.json
[ -f "$1" ] || die "factory/benchmark/ holds no case, so there is nothing to review. Run benchmark.sh from the repo root."
# In the order of their pull requests, which the shell's order of names is not: 12 before 7.
# shellcheck disable=SC2046
set -- $(printf '%s\n' "$@" | sort -t / -k 3 -n)

# reviewer <name>: sets $schema, $opening, $turns and $tools to that reviewer's format and the first line of its prompt,
# and the turn limit and the tools less `gh` of the `review` job in ci.yml, read from there so the two cannot differ (decisions A345a).
reviewer() {
  local job
  job=$(awk '/^  [A-Za-z0-9_-]+:/ { at = $1; sub(/:.*/, "", at) } at == "review"' factory/workflows/ci.yml)
  schema=$(sed -n "s/^ *$1_SCHEMA: '\(.*\)'[^']*$/\1/p" <<<"$job" | head -n 1 | jq -ce 'select(type == "object")') \
    && opening=$(awk -v key="$1_PROMPT:" '$1 == key && $2 == "|" { getline; sub(/^ */, ""); print; exit }' <<<"$job") \
    && [[ "$opening" == *"$number"* ]] \
    && turns=$(grep -o -- '--max-turns [0-9][0-9]*' <<<"$job" | head -n 1 | cut -d ' ' -f 2) \
    && tools=$(grep -o -- '--allowedTools "[^"]*"' <<<"$job" | head -n 1 | cut -d '"' -f 2 | tr , '\n' | grep -v '^Bash(gh[ :]' | paste -s -d , -) \
    || die "The review job in factory/workflows/ci.yml does not hold $1_SCHEMA, $1_PROMPT for pull request #$number, --max-turns and --allowedTools, so what a review is given is not known."
}
# shellcheck disable=SC2016
number='${{ github.event.pull_request.number }}'
reviewer ADAM
reviewer RYAN

# Every case is read and fetched before the first review, so no review is paid for in a run that cannot finish.
bases=""
for case in "$@"; do
  pr=$(basename "$case" .json)
  [[ "$pr" =~ ^[0-9]+$ ]] || die "$case is not named after its pull request, as 285.json is."
  jq -e '
    (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.ticket | (.title | type == "string") and (.body | type == "string"))
    and (.problems | type == "array" and length > 0)
    and all(.problems[]; (.problem | type == "string") and (.files | type == "array" and length > 0)
      and (.pattern as $pattern | "" | test($pattern; "i") | type == "boolean"))' "$case" >/dev/null 2>&1 \
    || die "$case is not a case: it holds a commit of 40 characters, a ticket's title and body, and problems, each with its files and a pattern jq can match."
  commit=$(jq -r .commit "$case")
  git fetch --quiet origin "refs/pull/$pr/head" \
    || die "Could not fetch pull request #$pr from origin, so its case cannot be reviewed."
  git cat-file -e "$commit^{commit}" 2>/dev/null \
    || die "Pull request #$pr does not hold the commit $commit that $case names."
  base=$(git merge-base origin/main "$commit") \
    || die "The commit $commit of $case shares no history with origin/main here, so its diff is not known. Run benchmark.sh in a full clone."
  bases+="$pr $base"$'\n'
done

work=$(mktemp -d) || die "Could not make a folder for the checkouts with mktemp."
trap 'rm -rf "$work"' EXIT

# review <name> <NAME>: one review of the case checked out in $work/tree, its findings added to $work/findings.
review() {
  local answer prompt schema opening turns tools
  reviewer "$2"
  opening=${opening//$number/$pr}
  # What ci.yml tells the reviewer, then what stands in for the pull request on GitHub (decisions A345a).
  prompt="$opening

This pull request is a replay, so use no \`gh\`. For the diff, run \`git diff $base HEAD\`. The ticket's title and text follow.

# $(jq -r .ticket.title "$case")

$(jq -r .ticket.body "$case")"
  answer=$(cd "$work/tree" && claude -p "$prompt" --model "$model" --effort "$effort" --max-turns "$turns" \
    --allowedTools "$tools" --disallowedTools "Bash(gh:*)" \
    --setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --json-schema "$schema" --output-format json) || true
  # A review cut short found nothing and missed nothing (decisions A345c).
  jq -e '(.structured_output.findings | type == "array")
    and (.total_cost_usd | type == "number") and (.duration_ms | type == "number")' <<<"$answer" >/dev/null 2>&1 \
    || die "$1's review of pull request #$pr ended with no findings, so the benchmark stopped: its table holds only the cases before this one. claude printed: ${answer:-nothing}"
  jq -c '.structured_output.findings[]' <<<"$answer" >> "$work/findings"
  jq -c '{cost: .total_cost_usd, ms: .duration_ms}' <<<"$answer" >> "$work/reviews"
}

echo "| Pull request | Known problem | $model, effort $effort |"
echo "|---|---|---|"
for case in "$@"; do
  pr=$(basename "$case" .json)
  base=$(awk -v pr="$pr" '$1 == pr { print $2 }' <<<"$bases")
  # A repository that holds the case's commit and nothing later: main's history names the known problems (decisions A345a).
  git init --quiet --initial-branch=case "$work/tree" \
    && git -C "$work/tree" fetch --quiet "$PWD" "$(jq -r .commit "$case")" \
    && git -C "$work/tree" checkout --quiet --detach FETCH_HEAD \
    || die "Could not check out the commit of $case, so it cannot be reviewed."
  : > "$work/findings"
  review Adam ADAM
  review Ryan RYAN
  rm -rf "$work/tree"
  # Found by either reviewer, in a file of the problem and in the case's words (decisions A345b).
  jq -r --arg pr "$pr" --slurpfile findings "$work/findings" '
    .problems[] | . as $known
    | (if any($findings[]; (.file | ltrimstr("./")) as $file
          | ($known.files | index($file)) != null and ("\(.problem) \(.fix)" | gsub("\n"; " ") | test($known.pattern; "i")))
       then "found" else "missed" end) as $result
    | "| #\($pr) | \(.problem) | \($result) |"' "$case" | tee -a "$work/rows"
done

jq -rs --rawfile rows "$work/rows" '
  def dollars: (. * 100 | round) as $cents
    | "$\($cents / 100 | floor).\($cents % 100 | tostring | if length < 2 then "0" + . else . end)";
  ($rows | split("\n") | map(select(. != ""))) as $problems
  | "",
    "\($problems | map(select(endswith("| found |"))) | length) of \($problems | length) known problems found. \(length) reviews: \(map(.cost) | add / length | dollars) and \(map(.ms) | add / length / 1000 | round) s a review, \(map(.cost) | add | dollars) in all."' "$work/reviews"
