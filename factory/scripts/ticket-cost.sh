#!/usr/bin/env bash
# Prints what a merged ticket cost: Claude usage, Actions minutes, fix rounds and the time from `ready` to merged.
# Usage: ticket-cost.sh <pr-number> [sessions-dir]          four lines, for a comment on the ticket
#        ticket-cost.sh --json <pr-number> [sessions-dir]   every figure as one line of JSON, which measures.sh records
#        ticket-cost.sh --comment                           the four lines, for the line of JSON given on stdin
#        ticket-cost.sh --month <yyyy-mm> [sessions-dir]    a table of the tickets whose pull request merged that month (UTC)
#        sessions-dir is a checkout of the sessions branch; without one each ticket's two folders are downloaded, and deleted at the end.
#        Needs GH_TOKEN (contents, pull-requests, issues and actions: read).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
usage="Usage: ticket-cost.sh <pr-number> [sessions-dir] | --json <pr-number> [sessions-dir] | --comment | --month <yyyy-mm> [sessions-dir]"

# tree <sha or branch> <type>: the SHA and path of each entry of that type. A listing GitHub cut short is a failure.
tree() {
  gh api "repos/{owner}/{repo}/git/trees/$1" \
    --jq "if .truncated then error(\"truncated\") else .tree[] | select(.type == \"$2\") | \"\(.sha) \(.path)\" end"
}

# fetch <folder>: downloads the transcripts of that folder of the sessions branch, if the branch holds it (decisions H221f).
fetch() {
  local folder="$1" sha files path
  sha=$(awk -v folder="$folder" '$2 == folder { print $1 }' <<<"$folders")
  [ -n "$sha" ] || return 0
  files=$(tree "$sha" blob) \
    || die "Could not list $folder/ on the sessions branch, so what the agents' sessions cost is not known."
  mkdir -p "$sessions/$folder"
  while read -r sha path; do
    # run-facts.sh reads nothing else.
    case "$path" in *.json) ;; *) continue ;; esac
    gh api "repos/{owner}/{repo}/git/blobs/$sha" -H "Accept: application/vnd.github.raw+json" > "$sessions/$folder/$path" \
      || die "Could not download $folder/$path from the sessions branch, so what the agents' sessions cost is not known."
  done <<<"$files"
}

# cost_of <pr> [issue]: one pull request's figures as JSON, from run-facts.sh and GitHub (decisions H221a).
#   issue is the ticket it closes, when the caller has read it.
cost_of() {
  local pr="$1" issue="${2:-}" facts branch listed named run more jobs="" events="" labels
  if [ "$fetched" = yes ]; then
    # linked-issue.sh says for itself what it could not read, and so does run-facts.sh.
    [ -n "$issue" ] || issue=$("$script_dir/linked-issue.sh" "$pr") || exit 1
    fetch "pr-$pr"
    [ -z "$issue" ] || fetch "issue-$issue"
  fi
  facts=$("$script_dir/run-facts.sh" "$pr" "$sessions") || exit 1
  [ "$(jq -r '.merged_at // ""' <<<"$facts")" != "" ] \
    || die "Pull request #$pr is not merged, so what its ticket cost is not known yet."
  branch=$(jq -r .branch <<<"$facts")
  issue=$(jq -r '.issue // ""' <<<"$facts")

  # The runs for the pull request's branch, and those its transcripts name (decisions H221c).
  listed=$(gh api --method GET "repos/{owner}/{repo}/actions/runs" -f branch="$branch" -f per_page=100 --paginate \
      --jq '.workflow_runs[].id') \
    || die "Could not list the workflow runs of $branch, so the Actions minutes of pull request #$pr are not known."
  named=$(jq -r '.agents[].file | capture("-run(?<id>[0-9]+)\\.json$") | .id' <<<"$facts")
  for run in $(printf '%s\n%s\n' "$listed" "$named" | sort -un); do
    more=$(gh api --method GET "repos/{owner}/{repo}/actions/runs/$run/jobs" -f filter=all -f per_page=100 --paginate \
        --jq '.jobs[] | [.run_id, .started_at // "", .completed_at // "", .conclusion // "", .workflow_name // "", .runner_id // 0, .runner_group_name // ""] | @tsv') \
      || die "Could not read the jobs of workflow run $run, so the Actions minutes of pull request #$pr are not known."
    jobs+="$more"$'\n'
  done

  # A stop can be flagged on the ticket, its pull request or both (decisions H246d).
  # shellcheck disable=SC2016
  labels='.[] | select((.event == "labeled" or .event == "unlabeled") and (.label.name == "ready" or .label.name == "needs-human"))
    | [$on, .event, .label.name, .created_at] | @tsv'
  if [ -n "$issue" ]; then
    events=$(gh api "repos/{owner}/{repo}/issues/$issue/events?per_page=100" --paginate --jq "\"ticket\" as \$on | $labels") \
      || die "Could not read the events of ticket #$issue, so when it was made \`ready\` is not known."
    more=$(gh api "repos/{owner}/{repo}/issues/$pr/events?per_page=100" --paginate --jq "\"pr\" as \$on | $labels") \
      || die "Could not read the events of pull request #$pr, so how often it stopped for a person is not known."
    events+=$'\n'"$more"
  fi

  jq -cn --argjson facts "$facts" --arg events "$events" --arg jobs "$jobs" '
    def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
    # Each second from $from to $to goes to one kind: the first of build, fix and review running then (decisions H246c).
    def split($from; $to):
      map(.from = ([.from, $from] | max) | .to = ([.to, $to] | min) | select(.to > .from)) as $in
      | ([$from, $to] + ($in | map(.from, .to)) | unique) as $at
      | reduce range(0; ($at | length) - 1) as $i ({build: 0, review: 0, fix: 0, waiting: 0};
          ([$in[] | select(.from <= $at[$i] and .to >= $at[$i + 1]) | .kind]) as $kinds
          | (["build", "fix", "review"] | map(select(. as $kind | $kinds | index($kind))) | .[0] // "waiting") as $kind
          | .[$kind] += $at[$i + 1] - $at[$i]);
    {implement: "build", fix: "fix", ci: "review", "approve-merge": "review"} as $kinds
    | [$events | split("\n")[] | select(. != "") | split("\t") | {on: .[0], event: .[1], label: .[2], at: (.[3] | at)}] as $labels
    # Decisions H221d.
    | ($labels | map(select(.on == "ticket" and .event == "labeled" and .label == "ready") | .at) | min) as $ready
    | ($facts.merged_at | at) as $merged
    # Unreadable, or ended with no result: run-facts.sh gives neither a cost.
    | ($facts.agents | map(select(.cost_usd != null))) as $read
    # A whole minute for each job, and one still running counted to now (decisions H221b).
    # A job cancelled while it waited for a runner has a start and an end, and no runner: it is billed nothing.
    # So is a job on a runner the owner keeps, which stays here for the time it ran (decisions H426).
    | [$jobs | split("\n")[] | select(. != "") | split("\t") | select(.[3] != "skipped" and .[1] != "" and .[5] != "0")
       | {run: .[0], kind: $kinds[.[4]], from: (.[1] | at), to: ((if .[2] == "" then now | todate else .[2] end) | at),
          own: (.[6] != "" and .[6] != "GitHub Actions")}
       | select(.to > .from) | .minutes = (if .own then 0 else (.to - .from) / 60 | ceil end)] as $billed
    | {
      pr: $facts.pr, issue: $facts.issue, title: $facts.title, merged_at: $facts.merged_at,
      cost_usd: ($read | map(.cost_usd) | add // 0),
      sessions: ($read | length),
      unread: (($facts.agents | length) - ($read | length)),
      models: ($read | map(.model // empty) | unique),
      minutes: ($billed | map(.minutes) | add // 0),
      runs: ($billed | map(.run) | unique | length),
      fix_rounds: $facts.fix_rounds, owner_rounds: $facts.owner_rounds,
      seconds: (if $ready == null then null else $merged - $ready end),
      split: (if $ready == null then null else $billed | map(select(.kind != null)) | split($ready; $merged) end),
      # The label put on the ticket or the pull request while it was on neither (decisions H246d).
      stops: (if $facts.issue == null then null else $labels | map(select(.label == "needs-human")) | sort_by(.at)
        | reduce .[] as $e ({on: [], stops: 0};
            if $e.event == "unlabeled" then .on -= [$e.on]
            else (if .on == [] then .stops += 1 else . end) | .on = (.on + [$e.on] | unique) end)
        | .stops end)
    }'
}

# Spliced in front of the two jq programs that print, so a comment and a table row word a figure alike.
# shellcheck disable=SC2016
words='
  def plural(word): "\(.) \(word)" + (if . == 1 then "" else "s" end);
  def dollars: (.cost_usd * 100 | round) as $cents
    | "$\($cents / 100 | floor).\($cents % 100 | tostring | if length < 2 then "0" + . else . end)";
  def unread: if .unread == 0 then ""
    else "; \(.unread | plural("more transcript")) gave no cost" end;
  def models: if (.models | length) == 0 then "not known" else .models | join(", ") end;
  def rounds: "\(.fix_rounds)" + (if .owner_rounds > 0 then ", and \(.owner_rounds) the owner asked for" else "" end);
  def took: if .seconds == null then (if .issue == null then "not known: the pull request closes no ticket" else "not known: the ticket was never labelled `ready`" end)
    else (.seconds / 60 | round) as $m
      | if $m < 60 then "\($m) min" elif $m < 1440 then "\($m / 60 | floor) h \($m % 60) min"
        else "\($m / 1440 | floor) d \($m % 1440 / 60 | floor) h" end end;'

# Decisions H246h.
lines() {
  jq -r "$words"'
    "- **Claude usage:** \(dollars) at API prices, in \(.sessions | plural("session")) on \(models)\(unread)",
    "- **Actions minutes:** \(.minutes), in \(.runs | plural("run"))",
    "- **Fix rounds:** \(rounds)",
    "- **Ready to merged:** \(took)"'
}

case "${1:-}" in
  --month)
    month="${2:-}"
    [[ "$month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "$usage"
    sessions="${3:-}" ;;
  --json)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || die "$usage"
    sessions="${3:-}" ;;
  --comment)
    lines 2>/dev/null | grep . || die "The figures on stdin are not a line ticket-cost.sh --json printed, so there is nothing to say of them."
    exit 0 ;;
  "" | -*) die "$usage" ;;
  *)
    [[ "$1" =~ ^[0-9]+$ ]] || die "$usage"
    sessions="${2:-}" ;;
esac

# Decisions H221f.
fetched=no
if [ -z "$sessions" ]; then
  fetched=yes
  sessions=$(mktemp -d)
  trap 'rm -rf "$sessions"' EXIT
  folders=$(tree sessions tree) \
    || die "Could not list the folders of the sessions branch, so what the agents' sessions cost is not known."
fi

case "$1" in
  --json) cost_of "$2"; exit ;;
  --month) ;;
  *)
    cost=$(cost_of "$1") || exit 1
    lines <<<"$cost"
    exit 0 ;;
esac

# Decisions H221e.
merged=$(gh api "repos/{owner}/{repo}/pulls?state=closed&per_page=100" --paginate \
    --jq ".[] | select((.merged_at // \"\") | startswith(\"$month\")) | .number") \
  || die "Could not list the pull requests merged in $month, so what its tickets cost is not known."
rows=""
for pr in $(sort -n <<<"$merged"); do
  # linked-issue.sh says for itself what it could not read.
  issue=$("$script_dir/linked-issue.sh" "$pr") || exit 1
  [ -n "$issue" ] || continue
  cost=$(cost_of "$pr" "$issue") || exit 1
  rows+="$cost"$'\n'
done
jq -rn --arg rows "$rows" --arg month "$month" "$words"'
  [$rows | split("\n")[] | select(. != "") | fromjson]
  | if length == 0 then "No ticket had its pull request merged in \($month)."
    else "| Ticket | Claude usage | Sessions | Model | Actions minutes | Runs | Fix rounds | Ready to merged |",
         "|---|---|---|---|---|---|---|---|",
         (.[] | "| #\(.issue) \(.title | gsub("\\|"; "\\|")) | \(dollars)\(unread) | \(.sessions) | \(models) | \(.minutes) | \(.runs) | \(rounds) | \(took) |") end'
