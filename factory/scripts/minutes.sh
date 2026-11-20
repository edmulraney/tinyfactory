#!/usr/bin/env bash
# Prints the Actions minutes billed for the runs created in a period, by workflow, by job and by ticket.
# Usage: minutes.sh <from> <to>   two dates as yyyy-mm-dd, both included, UTC
#        Needs GH_TOKEN (actions, contents and pull-requests: read).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=factory/scripts/shipping.sh
. "$script_dir/shipping.sh"
die() { echo "$1" >&2; exit 1; }
usage="Usage: minutes.sh <from> <to>   (two dates as yyyy-mm-dd, both included, UTC)"
from="${1:-}"; to="${2:-}"
date='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
[[ "$from" =~ $date && "$to" =~ $date ]] || die "$usage"
[[ ! "$from" > "$to" ]] || die "$from is after $to, so there is no period to read."

# list_runs <first second> <last second>: the runs created between them, halving a period GitHub cuts short (decisions H388b).
list_runs() {
  local first="$1" last="$2" window rows middle
  window=$(jq -rn --argjson first "$first" --argjson last "$last" '"\($first | todate)..\($last | todate)"')
  rows=$(retry gh api --method GET "repos/{owner}/{repo}/actions/runs" -f created="$window" -f per_page=100 --paginate \
      --jq '.total_count as $total | .workflow_runs[] | [$total, .id, .name, .head_branch // "", .conclusion // "", .run_attempt] | @tsv') \
    || die "Could not list the workflow runs created in $window, so the minutes they were billed are not known."
  [ -n "$rows" ] || return 0
  if [ "$(cut -f2 <<<"$rows" | sort -u | wc -l)" -ge "$(cut -f1 <<<"$rows" | sort -n | tail -1)" ]; then
    cut -f2- <<<"$rows"
    return 0
  fi
  [ "$first" -lt "$last" ] || die "GitHub lists fewer runs than it counts in $window, so the minutes they were billed are not known."
  middle=$(((first + last) / 2))
  list_runs "$first" "$middle" || exit 1
  list_runs "$((middle + 1))" "$last" || exit 1
}

first=$(jq -rn --arg day "$from" '$day + "T00:00:00Z" | fromdate')
last=$(jq -rn --arg day "$to" '$day + "T23:59:59Z" | fromdate')
runs=$(list_runs "$first" "$last") || exit 1
# A run skipped in its only attempt started no job (decisions H388c).
started=$(sort -u <<<"$runs" | awk -F '\t' '$1 != "" && !($4 == "skipped" && $5 == 1)')

# Eight runs at a time (decisions H388d). A read that still fails ends xargs with a status that is not 0.
jobs=""
if [ -n "$started" ]; then
  export -f retry
  # shellcheck disable=SC2016
  jobs=$(cut -f1 <<<"$started" | xargs -P 8 -I RUN bash -c 'retry gh api --method GET "repos/{owner}/{repo}/actions/runs/$1/jobs" \
      -f filter=all -f per_page=100 --paginate \
      --jq ".jobs[] | [.run_id, .name, .started_at // \"\", .completed_at // \"\", .conclusion // \"\", .runner_group_name // \"\"] | @tsv"' _ RUN) \
    || die "Could not read the jobs of every workflow run, so the minutes they were billed are not known."
fi

# A build or fix round runs for main, and its transcript names its run and its ticket or pull request (decisions H221c).
transcripts=$(retry gh api "repos/{owner}/{repo}/git/trees/sessions?recursive=1" \
    --jq 'if .truncated then error("truncated") else .tree[] | select(.type == "blob") | .path end') \
  || die "Could not list the transcripts on the sessions branch, so which ticket a build or fix round ran for is not known."
pulls=$(retry gh api "repos/{owner}/{repo}/pulls?state=all&per_page=100" --paginate --jq '.[] | [.number, .head.ref] | @tsv') \
  || die "Could not list the pull requests, so which ticket a review or fix round ran for is not known."

# Read as files: a month's jobs are longer than one argument may be.
jq -rn --arg from "$from" --arg to "$to" --rawfile runs <(printf '%s' "$started") --rawfile jobs <(printf '%s' "$jobs") \
  --rawfile transcripts <(printf '%s' "$transcripts") --rawfile pulls <(printf '%s' "$pulls") '
  def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
  def rows: split("\n") | map(select(. != "") | split("\t"));
  def ticket: (capture("^[a-z]+/(?<n>[0-9]+)-") | .n) // null;
  def table($head; key; name): group_by(key) | map({name: (.[0] | name), minutes: (map(.minutes) | add), runs: (map(.run) | unique | length)})
    | sort_by(-.minutes, .name) | "", "| \($head) | Minutes | Runs |", "|---|---|---|", (.[] | "| \(.name) | \(.minutes) | \(.runs) |");
  ($pulls | rows | map({key: .[0], value: (.[1] | ticket)}) | from_entries) as $of_pull
  | ($transcripts | split("\n") | map(capture("^(?<in>issue|pr)-(?<n>[0-9]+)/.*-run(?<run>[0-9]+)\\.json$")
      | {key: .run, value: (if .in == "issue" then .n else $of_pull[.n] end)}) | from_entries) as $of_transcript
  | ($runs | rows | map({key: .[0], value: {workflow: .[1], ticket: ((.[2] | ticket) // $of_transcript[.[0]])}}) | from_entries) as $run
  # A whole minute for each job, over every attempt, and one still running counted to now (decisions H221b).
  # A job no runner took has no runner group, and is billed nothing however long it waited (decisions H251a).
  | [$jobs | rows[] | select(.[4] != "skipped" and .[2] != "" and .[5] != "")
     | {run: .[0], job: .[1], from: (.[2] | at), to: ((if .[3] == "" then now | todate else .[3] end) | at),
        own: (.[5] != "GitHub Actions")}
     # A job on a runner the owner keeps is billed nothing, and its time is still shown (decisions H426).
     | select(.to > .from) | .seconds = .to - .from | .minutes = (if .own then 0 else .seconds / 60 | ceil end) | . + $run[.run]] as $billed
  | if ($billed | length) == 0 then "No run created from \($from) to \($to) (UTC) was billed a minute."
    else
      "Actions minutes billed for the runs created from \($from) to \($to) (UTC): \($billed | map(.minutes) | add), in \($billed | map(.run) | unique | length) runs.",
      ($billed | table("Workflow"; .workflow; .workflow)),
      "", "| Workflow | Job | Minutes | Jobs | Minutes it ran |", "|---|---|---|---|---|",
      ($billed | group_by([.workflow, .job]) | map({workflow: .[0].workflow, job: .[0].job, minutes: (map(.minutes) | add), jobs: length, ran: (map(.seconds) | add / 60 | round)})
        | sort_by(-.minutes, .workflow, .job)[] | "| \(.workflow) | \(.job) | \(.minutes) | \(.jobs) | \(.ran) |"),
      ($billed | table("Ticket"; .ticket; if .ticket == null then "No ticket" else "#" + .ticket end))
    end'
