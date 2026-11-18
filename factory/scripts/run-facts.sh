#!/usr/bin/env bash
# Prints the facts of one finished run as JSON, computed from what GitHub and the sessions branch hold (decisions A15).
# Usage: run-facts.sh <pr-number> [sessions-dir]
#        run-facts.sh --run <run-id> [sessions-dir]
#        run-facts.sh --first-run <pr-number> <run-id> [sessions-dir]
#        sessions-dir is a checkout of the sessions branch. Needs GH_TOKEN (actions: read to see jobs and logs).
#        --first-run adds `changed_steps`: each step the pull request's diff names in that workflow, and what it did.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
# Holds what gh says when a log does not come (decisions A370).
error_file=$(mktemp) || die "Could not make a temporary file, so the facts of the run were not read."
trap 'rm -f "$error_file"' EXIT

# The Actions log says only "is_error: true" for a session that died: the reason and the retries end its transcript.
session() {
  local file="$1" sessions="$2" role facts
  role=$(basename "$file" | sed -E 's/^[0-9TZ]+-(.*)-run[0-9a-z]+\.json$/\1/')
  # An empty file is no JSON to jq and no error either, so no output is read as unreadable too.
  facts=$(jq -c --arg role "$role" --arg file "${file#"$sessions"/}" '
    def lead(f): (map(f) | index(false)) // length;
    (if type == "array" then . else [.] end) as $all
    | ($all[-1] // {}) as $end
    | ($all | reverse) as $back
    # Behind the result sits the message the session ended on; the retries are behind that.
    | ($back | lead(.type == "result" or .type == "assistant")) as $skip
    | {role: $role, file: $file, model: (first($all[] | select(.type == "system" and .subtype == "init") | .model) // null),
       # A transcript that ends with no result has no cost to give: null, which is not a cost of nothing.
       cost_usd: $end.total_cost_usd, turns: ($end.num_turns // 0),
       seconds: ((($end.duration_ms // 0) / 1000) | round), error: ($end.is_error // false),
       terminal_reason: ($end.terminal_reason // null), api_error_status: ($end.api_error_status // null),
       api_retries: ($back[$skip:] | lead(.type == "system" and .subtype == "api_retry")),
       result: (if $end.is_error == true then ($end.result // "" | tostring | .[0:300]) else null end)}' "$file" 2>/dev/null) && [ -n "$facts" ] && echo "$facts" \
    || jq -nc --arg role "$role" --arg file "${file#"$sessions"/}" '{role: $role, file: $file, unreadable: true}'
}

sessions_of() {
  local sessions="$1" file; shift
  for file in "$@"; do
    [ -f "$file" ] || continue
    session "$file" "$sessions"
  done | jq -sc .
}

# Spliced into the jq programs below, where $agents is jq's.
# shellcheck disable=SC2016
totals='cost_usd: (($agents | map(.cost_usd // 0) | add // 0) * 100 | round / 100), turns: ($agents | map(.turns // 0) | add // 0)'

# GitHub serves a job's log some time after the job ends, so it is asked for up to a minute (decisions A19).
job_log() {  # job_log <job-id>: sets $log, empty when it never came
  local try
  for try in 1 2 3 4 5 6; do
    # gh refuses to print a log that holds a colour code unless asked (decisions A370).
    log=$(gh api "repos/{owner}/{repo}/actions/jobs/$1/logs" --allow-escape-sequences 2>"$error_file") && [ -n "$log" ] && return
    log=""; [ "$try" = 6 ] || sleep 10
  done
}

step_log() {  # step_log <started-at> <completed-at>: the last 60 lines $log holds of that step
  local from="$1" to="$2" part=""
  if [ -z "$log" ]; then
    if [ -s "$error_file" ]; then echo "(log not available after a minute: $(paste -sd ' ' "$error_file"))"
    else echo "(log not available after a minute: an empty log, with no error)"; fi
    return
  fi
  # Every line of a job's log has a timestamp, so the step's part is the lines between its start and end.
  if [[ "$from" =~ ^[0-9-]{10}T[0-9:]{8}(\.[0-9]+)?Z$ && "$to" =~ ^[0-9-]{10}T[0-9:]{8}(\.[0-9]+)?Z$ ]]; then
    part=$(awk -v from="${from:0:19}" -v to="${to:0:19}" '{ at = substr($0, 1, 19) } at >= from && at <= to' <<<"$log")
  fi
  sed -E -e 's/^[0-9T:.-]+Z //' -e $'s/\033\\[[0-9;?]*[A-Za-z]//g' <<<"${part:-$log}" | grep -v '^##\[group\]\|^##\[endgroup\]' | tail -n 60
}

# The first run of a workflow a pull request changed, whatever its conclusion (decisions A185a).
if [ "${1:-}" = --first-run ]; then
  usage="Usage: run-facts.sh --first-run <pr-number> <run-id> [sessions-dir]"
  pr="${2:?$usage}"; run="${3:?$usage}"; sessions="${4:-}"
  # Each mode says for itself what it could not read.
  of_run=$("$0" --run "$run" "$sessions") || exit 1
  of_pr=$("$0" "$pr" "$sessions") || exit 1
  workflow=$(jq -r .workflow <<<"$of_run")
  diff=$(gh pr diff "$pr") \
    || die "Could not read the diff of pull request #$pr, so which steps it changed is not known."
  jobs=$(gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" --paginate --jq '.jobs[]') \
    || die "Could not read the jobs of workflow run $run from GitHub, so what its changed steps did is not known."
  # A step is known by its name alone, so one the diff adds or renames in this run's workflow (decisions A334).
  names=$(awk -v workflow="factory/workflows/$workflow" '
    /^diff --git / { inside = 0 }
    /^\+\+\+ b\// { inside = ($0 == "+++ b/" workflow ".yml" || $0 == "+++ b/" workflow ".yaml") }
    inside && /^\+[ \t]*- name:/ {
      sub(/^\+[ \t]*- name:[ \t]*/, ""); sub(/[ \t\r]+$/, "")
      if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) $0 = substr($0, 2, length($0) - 2)
      print
    }' <<<"$diff")
  # A step no job of the run holds was never reached: it is listed with no job. Sorted so a job's log is read once.
  steps=$(jq -sc --arg names "$names" '
    . as $jobs
    | [$names | split("\n")[] | select(. != "")] | unique
    | map(. as $name
          | [$jobs[] | . as $job | (.steps // [])[] | select(.name == $name)
             | {id: $job.id, job: $job.name, step: $name, conclusion, from: (.started_at // ""), to: (.completed_at // "")}]
          | if length == 0 then [{id: null, job: null, step: $name, conclusion: null, from: "", to: ""}] else . end)
    | flatten | sort_by(.id)' <<<"$jobs")
  changed='[]'
  last=""
  while IFS=$'\x1f' read -r id job step conclusion from to; do
    [ -n "$step" ] || continue
    tail=null
    # A skipped step printed nothing, so the lines of its second would be another step's.
    if [ -n "$id" ] && [ "$conclusion" != skipped ]; then
      [ "$id" = "$last" ] || job_log "$id"
      last="$id"
      tail=$(step_log "$from" "$to" | jq -Rs 'rtrimstr("\n")')
    fi
    changed=$(jq -c --arg job "$job" --arg step "$step" --arg conclusion "$conclusion" --argjson log "$tail" \
      '. + [{job: $job, step: $step, conclusion: $conclusion} | map_values(if . == "" then null else . end) | .log = $log]' <<<"$changed")
  done < <(jq -r '.[] | [.id // "", .job // "", .step, .conclusion // "", .from, .to] | map(tostring) | join("\u001f")' <<<"$steps")
  # `pr` and `issue` stay the ones the run was for; the sessions are the run's own.
  jq -n --argjson run "$of_run" --argjson pr "$of_pr" --argjson changed "$changed" '
    $run + {changed_by: {pr: $pr.pr, issue: $pr.issue, title: $pr.title,
                         assumptions: ($pr.reviews | map_values(.assumptions))},
            changed_steps: $changed}'
  exit 0
fi

if [ "${1:-}" = --run ]; then
  run="${2:?Usage: run-facts.sh --run <run-id> [sessions-dir]}"; sessions="${3:-}"

  view=$(gh api "repos/{owner}/{repo}/actions/runs/$run") \
    || die "Could not read workflow run $run from GitHub, so its facts are not known."
  workflow=$(jq -r '.path // "" | capture("(?<name>[^/]+)\\.ya?ml") | .name' <<<"$view")
  jobs=$(gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" --paginate --jq '.jobs[]') \
    || die "Could not read the jobs of workflow run $run from GitHub, so what failed is not known."

  # A job still finishing has no conclusion yet, but its failed step already shows.
  # In `ci` a failed check or review is the pull request's: only `merge`, `start-fix` and `fix` count (decisions A20).
  failed=$(jq -sc --arg workflow "$workflow" '
    map(select(.conclusion == "failure" or .conclusion == "timed_out" or ((.steps // []) | any(.conclusion == "failure"))))
    | if $workflow == "ci" then map(select(.name == "merge" or .name == "start-fix" or .name == "fix")) else . end
    | map(((.steps // []) | map(select(.conclusion == "failure")) | .[0]) as $step
          | {id, job: .name, step: ($step.name // null), from: ($step.started_at // ""), to: ($step.completed_at // "")})' <<<"$jobs")

  logs=""
  out='[]'
  # Split on a character no name holds: an empty step would vanish between two tabs.
  while IFS=$'\x1f' read -r id job step from to; do
    [ -n "$id" ] || continue
    job_log "$id"
    [ -z "$log" ] || logs+="$log"$'\n'
    tail=$(step_log "$from" "$to")
    out=$(jq -c --arg job "$job" --arg step "$step" --arg log "$tail" \
      '. + [{job: $job, step: (if $step == "" then null else $step end), log: $log}]' <<<"$out")
  done < <(jq -r '.[] | [.id, .job, .step // "", .from, .to] | map(tostring) | join("\u001f")' <<<"$failed")

  agents='[]'
  folder=""
  if [ -n "$sessions" ]; then
    files=()
    for file in "$sessions"/*/*-run"$run".json; do
      case "$file" in "$sessions"/lessons/*) continue ;; esac
      [ -f "$file" ] && files+=("$file")
    done
    if [ "${#files[@]}" -gt 0 ]; then
      agents=$(sessions_of "$sessions" "${files[@]}")
      folder=$(basename "$(dirname "${files[0]}")")
    fi
  fi

  # Every step's log prints its environment, which holds ISSUE or PR; with no log, the transcript's folder names it.
  named=$(sed -E 's/^[0-9T:.-]+Z //' <<<"$logs" | grep -m 1 -oE '^ +(ISSUE|PR): [0-9]+$' || true)
  issue=""; pr=""
  case "$named" in
    *ISSUE:*) issue="${named##* }" ;;
    *PR:*) pr="${named##* }" ;;
    *) case "$folder" in issue-*) issue="${folder#issue-}" ;; pr-*) pr="${folder#pr-}" ;; esac ;;
  esac
  if [ -n "$pr" ]; then issue=$("$script_dir/linked-issue.sh" "$pr"); fi

  jq -n --argjson view "$view" --arg workflow "$workflow" --arg pr "$pr" --arg issue "$issue" \
    --argjson failed "$out" --argjson agents "$agents" '
    def number: if . == "" then null else tonumber end;
    {
      run: $view.id,
      workflow: $workflow,
      event: $view.event,
      attempt: $view.run_attempt,
      url: $view.html_url,
      conclusion: $view.conclusion,
      pr: ($pr | number),
      issue: ($issue | number),
      failed: $failed,
      # A ticket refused at validation ended as designed (decisions A21).
      factory_failure: (($failed | length) > 0
        and (($workflow == "implement" and $failed[0].step == "Validate the ticket against its template") | not)),
      agents: $agents,
      '"$totals"'
    }'
  exit 0
fi

pr="${1:?Usage: run-facts.sh <pr-number> [sessions-dir]}"; sessions="${2:-}"

view=$(gh pr view "$pr" --json number,title,headRefName,state,mergedAt,labels,comments,createdAt) \
  || die "Could not read pull request #$pr from GitHub, so its facts are not known."
branch=$(jq -r .headRefName <<<"$view")
issue=$("$script_dir/linked-issue.sh" "$pr")
rounds=$("$script_dir/fix-rounds.sh" "$pr") \
  || die "Could not count the fix rounds of pull request #$pr, so its facts are not known."
owner_rounds=$("$script_dir/fix-rounds.sh" "$pr" owner) \
  || die "Could not count the owner's fix rounds of pull request #$pr, so its facts are not known."

# Each read is on its own line, so that a failed read stops here and is not taken for "nothing failed" (decisions H7).
runs=$(gh run list --workflow ci.yml --branch "$branch" --limit 20 --json databaseId,conclusion \
    --jq '.[] | select(.conclusion == "failure") | .databaseId') \
  || die "Could not list the ci runs of $branch, so which jobs failed is not known."
names=""
for run in $runs; do
  more=$(gh run view "$run" --json jobs --jq '.jobs[] | select(.conclusion == "failure") | .name') \
    || die "Could not read the jobs of ci run $run, so which jobs failed is not known."
  names+="$more"$'\n'
done
failed=$(jq -Rnc '[inputs | select(. != "")] | group_by(.) | map({job: .[0], times: length})' <<<"$names")

agents='[]'
if [ -n "$sessions" ]; then
  files=()
  for dir in "$sessions/pr-$pr" ${issue:+"$sessions/issue-$issue"}; do
    for file in "$dir"/*.json; do [ -f "$file" ] && files+=("$file"); done
  done
  [ "${#files[@]}" -eq 0 ] || agents=$(sessions_of "$sessions" "${files[@]}")
fi

jq -n --argjson view "$view" --arg issue "$issue" --argjson rounds "$rounds" --argjson owner_rounds "$owner_rounds" --argjson failed "$failed" --argjson agents "$agents" '
  ($view.comments | map(.body)) as $bodies
  # The assumptions of a verdict: the hidden last line post-verdict.sh wrote (decisions A55b, A55c).
  # A verdict from before that line has none; one from before the install holds `unverified`
  # claims in three parts (decisions A224b).
  | def assumptions: [split("\n")[] | select(. != "")] | last
      | capture("^<!-- factory:(assumptions|unverified) (?<list>.*) -->$") | .list | fromjson | .[]
      | {assumes: (.assumes // .claim), if_wrong: (.if_wrong // .risk)};
    # A verdict is known by the first line of its comment: the rest may quote another (decisions
    # A137).
    def says(name; f): select((split("\n")[0] // "") | startswith("**" + name) and f);
    # A pass carry-review.sh posted again says so on its third line (decisions A160d): no
    # reviewer gave it, so it is counted apart.
    def carried: (split("\n")[2] // "") | sub("\r$"; "") | endswith(" <!-- factory:carried -->");
    def verdicts(name): {
      pass: ($bodies | map(says(name; contains(": PASS**")) | select(carried | not)) | length),
      carried: ($bodies | map(says(name; contains(": PASS**")) | select(carried)) | length),
      fail: ($bodies | map(says(name; contains(": FAIL**") or contains(": no verdict"))) | length),
      # From every round, each one once: one that outlived a fix round is worded the same.
      assumptions: ([$bodies[] | says(name; contains(": PASS**") or contains(": FAIL**")) | assumptions] | unique) };
  {
    pr: $view.number,
    issue: (if $issue == "" then null else ($issue | tonumber) end),
    title: $view.title,
    branch: $view.headRefName,
    outcome: (if $view.mergedAt then "merged"
              elif ($view.labels | map(.name) | index("needs-human")) then "needs-human"
              else ($view.state | ascii_downcase) end),
    merged_at: $view.mergedAt,
    fix_rounds: $rounds,
    owner_rounds: $owner_rounds,
    failed_jobs: $failed,
    reviews: { adam: verdicts("Adam"), ryan: verdicts("Ryan") },
    agents: $agents,
    '"$totals"'
  }' || die "A verdict on pull request #$pr holds a list of assumptions that could not be read, so its facts are not known."
