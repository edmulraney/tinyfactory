#!/usr/bin/env bash
# Writes metrics.md on the `sessions` branch: nine delivery measures and the product's usage by week (decisions H613a).
# Usage: metrics.sh   (in a clone whose `origin` is the repo on GitHub; the history of `main` is fetched)
#        A week is an ISO week that has ended, UTC, and holds the pull requests merged in it.
#        With USAGE_ROWS, the file review-notes.yml read from production's database, the page ends with usage.sh's section.
#        Needs GH_TOKEN (contents: write; pull-requests and issues: read) and GITHUB_REPOSITORY.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
[ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] \
  || die "GH_TOKEN and GITHUB_REPOSITORY are not both set, so metrics.md is not written."

query='query($owner: String!, $name: String!, $endCursor: String) { repository(owner: $owner, name: $name) {
  pullRequests(states: MERGED, baseRefName: "main", first: 100, after: $endCursor) {
    nodes { number mergedAt
      closingIssuesReferences(first: 10) { nodes { number title
        timelineItems(itemTypes: LABELED_EVENT, first: 100) { nodes { ... on LabeledEvent { createdAt label { name } } } } } } }
    pageInfo { hasNextPage endCursor } } } }'
pulls=$(gh api graphql --paginate -F owner='{owner}' -F name='{repo}' -f query="$query" \
    --jq '.data.repository.pullRequests.nodes[] | tojson') \
  || die "Could not list the merged pull requests from GitHub, so metrics.md is not written."
# A bug is traced to a merge as measures.sh traces it (decisions H246e).
bugs=$(gh api "repos/{owner}/{repo}/issues?state=all&labels=bug&per_page=100" --paginate \
    --jq '.[] | select(.pull_request == null) | {number, names: [(.body // "") | scan("#([0-9]+)") | .[0] | tonumber] | unique} | tojson') \
  || die "Could not list the tickets labelled \`bug\` from GitHub, so which merges a bug followed is not known and metrics.md is not written."

# What GitHub and the history of main say of each pull request merged in a week that has ended (decisions H613b).
# shellcheck disable=SC2016
of_github='
  def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
  (now | strftime("%G-W%V")) as $running
  # revert.sh titles the ticket that takes a pull request back (decisions M19d).
  | [$pulls[].closingIssuesReferences.nodes[].title
     | capture("^Take back (the button merge of )?pull request #(?<pr>[0-9]+)$") | .pr | tonumber] as $reverted
  | ($rework | map({key: (.pr | tostring), value: .}) | from_entries) as $lines
  | $pulls | map(
      (.mergedAt | at) as $merged | .number as $pr | [.closingIssuesReferences.nodes[].number] as $tickets
      | {pr: $pr, week: ($merged | strftime("%G-W%V")),
         # From the first `ready` (decisions H221d) to the `deployed` this merge led to.
         lead: [.closingIssuesReferences.nodes[]
           | [.timelineItems.nodes[] | {name: .label.name?, at: (.createdAt | at)}] as $labels
           | ($labels | map(select(.name == "ready") | .at) | min) as $ready
           | ($labels | map(select(.name == "deployed" and .at >= $merged) | .at) | min) as $deployed
           | select($ready != null and $deployed != null and $deployed > $ready) | $deployed - $ready],
         failed: (($reverted | index($pr)) != null or any($bugs[];
           (.number > $pr and (.names | index($pr)) != null) or (. as $bug | any($tickets[]; . as $ticket | $bug.number > $ticket and ($bug.names | index($ticket)) != null)))),
         rework: ($lines[$pr | tostring] | if .reworked == null then null else . end)}
      | select(.week < $running))'
# quality.sh says for itself what it could not read.
rework=$("$script_dir/quality.sh" --json) || exit 1
# Read as files: a year's pull requests are longer than one argument may be.
merged=$(jq -cn --slurpfile pulls <(printf '%s\n' "$pulls") --slurpfile bugs <(printf '%s\n' "$bugs") \
    --slurpfile rework <(printf '%s\n' "$rework") "$of_github") \
  || die "The merged pull requests could not be read as GitHub and quality.sh returned them, so metrics.md is not written."
[ "$merged" != "[]" ] || { echo "No pull request merged in a week that has ended, so metrics.md is not written."; exit 0; }

# shellcheck disable=SC2016
page='
  def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
  def plural(word): "\(.) \(word)" + (if . == 1 then "" else "s" end);
  def tenth: (. * 10 | round) / 10;
  def hundredth: (. * 100 | round) / 100;
  def mean(f): (map(f) | add) / length;
  # each(f): a row for each week, from the entries of that week; f gives none for a week that does not hold the measure.
  def each(f): group_by(.week) | map(.[0].week as $week | f | {week: $week} + .);
  def of_recorded(f): each({value: f, over: (length | plural("recorded pull request"))});
  ($turns | split("\n") | map(select(. != "") | split("\t") | {folder: .[0], turns: (.[1] | tonumber)})) as $sessions
  | (now | strftime("%G-W%V")) as $running
  | ($record | map(. as $line | select(.merged_at != null)
      | .week = (.merged_at | at | strftime("%G-W%V")) | select(.week < $running)
      | .turns = ($sessions | map(select(.folder == "pr-\($line.pr)" or .folder == "issue-\($line.issue)") | .turns) | add // 0))) as $recorded
  | [
    {title: "Merges a day", unit: "Merges a day",
     what: "The pull requests merged into `main` in the week, divided by its seven days.",
     rows: ($merged[0] | each({value: (length / 7 | tenth), over: (length | plural("merge"))}))},
    {title: "Time from `ready` to deployed", unit: "Hours",
     what: "The mean time from the first `ready` label on a ticket to the `deployed` label its merge led to. A ticket that deployed nothing is left out.",
     rows: ($merged[0] | each(map(.lead[]) | select(length > 0) | {value: (mean(.) / 3600 | tenth), over: (length | plural("deployed ticket"))}))},
    {title: "Merges followed by a bug ticket or a revert", unit: "Percent of merges",
     what: "The share of the merges of the week that a later ticket labelled `bug` names, by the number of the pull request or of its ticket, or that a later pull request took back.",
     rows: ($merged[0] | each((map(select(.failed)) | length) as $failed
       | {value: ($failed * 100 / length | round), over: "\($failed) of \(length | plural("merge"))"}))},
    {title: "Rework", unit: "Percent of added lines",
     what: "The share of the lines added by the pull requests of product tickets merged in the week that the pull requests merged after each, ten at most, changed or deleted (`factory/scripts/quality.sh`).",
     rows: ($merged[0] | each((map(.rework.added) | add) as $added | (map(.rework.reworked) | add) as $reworked | select($added > 0)
       | {value: ($reworked * 100 / $added | round), over: "\($reworked) of \($added | plural("added line"))"}))},
    {title: "Fix rounds for each pull request", unit: "Fix rounds",
     what: "The mean number of fix rounds, those the owner asked for included.",
     rows: ($recorded | of_recorded(mean(.fix_rounds + .owner_rounds) | hundredth))},
    {title: "Agent sessions for each pull request", unit: "Sessions",
     what: "The mean number of agent sessions whose transcript gave a cost.",
     rows: ($recorded | of_recorded(mean(.sessions) | tenth))},
    {title: "Turns for each pull request", unit: "Turns",
     what: "The mean number of turns the agents took, over every transcript kept for the pull request and its ticket.",
     rows: ($recorded | of_recorded(mean(.turns) | round))},
    {title: "Actions minutes for each pull request", unit: "Minutes",
     what: "The mean number of Actions minutes billed for the runs of the pull request and its ticket.",
     rows: ($recorded | of_recorded(mean(.minutes) | tenth))},
    {title: "Claude cost for each pull request", unit: "Dollars",
     what: "The mean Claude usage at API prices.",
     rows: ($recorded | of_recorded(mean(.cost_usd) | hundredth))}
  ] as $measures
  | "# The factory\u0027s delivery numbers by week",
    "",
    "`factory/scripts/metrics.sh` writes this page from what GitHub and git hold. A week is an ISO week that has ended, UTC, and holds the pull requests merged in it. The first four measures are those of DORA. The last five are means over the pull requests whose measures `measures.jsonl` recorded at their merge.",
    ($measures[]
     | "", "## \(.title)", "", .what, "",
       if .rows == [] then "No week holds this measure yet."
       else
         "```mermaid", "xychart-beta",
         "  x-axis [\(.rows | map("\"\(.week)\"") | join(", "))]",
         "  y-axis \"\(.unit)\" 0 --> \(.rows | map(.value) | max | if . == 0 then 1 else . end)",
         "  bar [\(.rows | map(.value | tostring) | join(", "))]",
         "```", "",
         "| Week | \(.unit) | Counted over |", "|---|---|---|",
         (.rows[] | "| \(.week) | \(.value) | \(.over) |")
       end)'

usage=""
if [ -n "${USAGE_ROWS:-}" ]; then
  # A ticket two pull requests closed is shown once.
  tickets=$(jq -cs 'map(.closingIssuesReferences.nodes[]) | unique_by(.number)[]' <<<"$pulls") \
    || die "The tickets the merged pull requests closed could not be read as GitHub returned them, so metrics.md is not written."
  # usage.sh says for itself what it could not read.
  usage=$("$script_dir/usage.sh" "$USAGE_ROWS" <(printf '%s\n' "$tickets")) || exit 1
fi

# shellcheck source=factory/scripts/sessions-branch.sh
. "$script_dir/sessions-branch.sh"
problem=""
# write_page <clone>: what push_to_sessions runs in each fresh clone; a record it cannot read is said in $problem (decisions H613d).
write_page() {
  local clone="$1" record="" folders folder file count turns="" text
  [ ! -f "$clone/measures.jsonl" ] || record=$(cat "$clone/measures.jsonl")
  # A ticket built twice is recorded under two pull requests, and its folder is read once.
  if ! folders=$(jq -r '"pr-\(.pr)", "issue-\(.issue)"' <<<"$record" 2>/dev/null | sort -u); then
    problem="measures.jsonl on the sessions branch holds a line that could not be read, so metrics.md is not written."
    return 0
  fi
  # The record holds no turns, and the transcripts hold those of every week (decisions H613c).
  for folder in $folders; do
    for file in "$clone/$folder"/*.json; do
      [ -f "$file" ] || continue
      # A transcript nothing can read, or one that ended with no result, gave no turn to count, as run-facts.sh reads it.
      count=$(jq -rs '(.[0] // {}) | (if type == "array" then .[-1] // {} else . end) | .num_turns // 0' "$file" 2>/dev/null) || count=0
      turns+="$folder"$'\t'"$count"$'\n'
    done
  done
  if ! text=$(jq -rn --slurpfile merged <(printf '%s\n' "$merged") --slurpfile record <(printf '%s\n' "$record") \
      --rawfile turns <(printf '%s' "$turns") "$page"); then
    problem="The measures in measures.jsonl on the sessions branch could not be worked out by week, so metrics.md is not written."
    return 0
  fi
  printf '%s\n' "$text" > "$clone/metrics.md"
  [ -z "$usage" ] || printf '\n%s\n' "$usage" >> "$clone/metrics.md"
}
push_to_sessions "metrics: the weeks that have ended" write_page \
  || die "metrics.md could not be written to the sessions branch, so the page there is the one written before."
[ -z "$problem" ] || die "$problem"
echo "wrote ${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/blob/sessions/metrics.md"
