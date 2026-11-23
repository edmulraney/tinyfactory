#!/usr/bin/env bash
# Prints the facts of one finished run as JSON, computed from what GitHub and the sessions branch hold (decisions A15).
# Usage: run-facts.sh <pr-number> [sessions-dir]
#        run-facts.sh --run <run-id> [sessions-dir]
#        run-facts.sh --first-run <pr-number> <run-id> [sessions-dir]
#        sessions-dir is a checkout of the sessions branch. Needs GH_TOKEN (actions: read to see jobs and logs).
#        run-facts.sh --ask <run-id> <comment-link> <sessions-dir>
#        run-facts.sh --defect <issue-number> <sessions-dir>
#        --first-run adds `changed_steps`: each named step the pull request's diff adds a line to in that workflow, and what it did.
#        --ask adds `ask`: the comment that asked @claude for help. It copies the transcript of the `claude` run that
#        answered, an artifact of that run, into sessions-dir, where the facts list it.
#        --defect gives a ticket for a defect met in use: `defect` holds its link, state and labels, `fixed_by`
#        the pull requests that closed it, and `earlier_lesson` the lesson a retro of the defect saved, or null.
#        Its words are read through thread.sh, so the facts hold none of them (decisions A574f).
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
  # The workflow's file, then the number of each line the diff adds to it, as the pull request left it.
  added=$(awk -v workflow="factory/workflows/$workflow" '
    /^diff --git / { inside = 0 }
    /^\+\+\+ b\// {
      inside = ($0 == "+++ b/" workflow ".yml" || $0 == "+++ b/" workflow ".yaml")
      if (inside) print substr($0, 7)
      next
    }
    inside && /^@@ / { split($3, at, ","); line = substr(at[1], 2) + 0; next }
    inside && /^\+/ { print line++; next }
    inside && /^ / { line++ }' <<<"$diff")
  # A step is known by its name, so each added line is placed in the step that holds it: its name, a line of
  # its `run:`, its `if:` (decisions A334). GitHub keeps the pull request's last commit at refs/pull/<n>/head.
  # The line numbers reach awk through the environment (decisions H632a).
  names=""
  if [ "$(grep -c . <<<"$added")" -gt 1 ]; then
    file=$(sed -n 1p <<<"$added")
    source=$(gh api "repos/{owner}/{repo}/contents/$file?ref=refs/pull/$pr/head" -H "Accept: application/vnd.github.raw+json") \
      || die "Could not read $file as pull request #$pr left it, so which steps it changed is not known."
    names=$(ADDED="$(sed 1d <<<"$added")" awk '
      { sub(/\r$/, "") }
      /^[ \t]*steps:[ \t]*$/ { indent = -1; step = 0; next }
      /^[ \t]*(#|$)/ { next }
      indent == -1 { indent = ($0 ~ /^ *- /) ? index($0, "-") : 0 }
      # A line indented less than the steps ends them: the next job, or the end of the jobs.
      indent > 0 && match($0, /[^ ]/) < indent { indent = 0; step = 0 }
      indent > 0 && match($0, /[^ ]/) == indent { step = ++steps }
      step {
        in_step[FNR] = step
        key = substr($0, indent)
        if (key ~ /^(- |  )name:/) {
          sub(/^(- |  )name:[ \t]*/, "", key); sub(/[ \t]+$/, "", key)
          if (key ~ /^".*"$/ || key ~ /^\047.*\047$/) key = substr(key, 2, length(key) - 2)
          name[step] = key
        }
      }
      END {
        count = split(ENVIRON["ADDED"], lines, "\n")
        for (i = 1; i <= count; i++) if ((lines[i] in in_step) && name[in_step[lines[i]]] != "") print name[in_step[lines[i]]]
      }' <<<"$source")
  fi
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

# A comment that asked @claude for help, and the `claude` run that answered it (decisions A446a).
if [ "${1:-}" = --ask ]; then
  usage="Usage: run-facts.sh --ask <run-id> <comment-link> <sessions-dir>"
  run="${2:?$usage}"; link="${3:?$usage}"; sessions="${4:?$usage}"
  # A comment's link names the ticket or pull request it is on, then the comment's kind and id.
  [[ "$link" =~ ^https://[^[:space:]]+/(issues|pull)/([0-9]+)#(issuecomment-|discussion_r)([0-9]+)$ ]] \
    || die "$link is not the link to a comment on a ticket or a pull request, so the request for help was not read."
  case "${BASH_REMATCH[1]}" in pull) folder="pr-${BASH_REMATCH[2]}" ;; *) folder="issue-${BASH_REMATCH[2]}" ;; esac
  case "${BASH_REMATCH[3]}" in issuecomment-) kind=issues ;; *) kind=pulls ;; esac
  ask=$(gh api "repos/{owner}/{repo}/$kind/comments/${BASH_REMATCH[4]}" --jq '{comment: .body, url: .html_url}') \
    || die "Could not read the comment $link from GitHub, so the request for help is not known."
  attempt=$(gh api "repos/{owner}/{repo}/actions/runs/$run" --jq .run_attempt) \
    || die "Could not read workflow run $run from GitHub, so its transcript was not found."
  work=$(mktemp -d) || die "Could not make a temporary folder, so the transcript of workflow run $run was not read."
  kept="$sessions/$folder/$(date -u +%Y%m%dT%H%M%SZ)-claude-run$run.json"
  trap 'rm -rf "$error_file" "$work"' EXIT
  # The job that answered may not write the sessions branch, so its transcript is an artifact of its run (decisions A446b).
  gh run download "$run" --name "session-claude-$run-$attempt" --dir "$work" >&2 \
    || die "Could not download the transcript of workflow run $run, so the facts of the request for help are not known."
  transcript=$(find "$work" -type f -name '*.json' | head -n 1)
  [ -n "$transcript" ] || die "The artifact of workflow run $run holds no transcript, so the facts of the request for help are not known."
  mkdir -p "$sessions/$folder" && cp "$transcript" "$kept" \
    || die "Could not copy the transcript of workflow run $run into $sessions, so the facts of the request for help are not known."
  # The folder names the ticket or pull request to the run's facts, which say for themselves what they could not read.
  of_run=$("$0" --run "$run" "$sessions") || { rm -f "$kept"; exit 1; }
  jq -n --argjson run "$of_run" --argjson ask "$ask" '$run + {ask: $ask}'
  exit 0
fi

# A ticket for a defect the owner met in use, which no run names (decisions A574a).
if [ "${1:-}" = --defect ]; then
  usage="Usage: run-facts.sh --defect <issue-number> <sessions-dir>"
  issue="${2:?$usage}"; sessions="${3:?$usage}"
  [[ "$issue" =~ ^[0-9]+$ ]] || die "$issue is not the number of a ticket, so the defect was not read."
  ticket=$(gh issue view "$issue" --json url,state,labels,closedByPullRequestsReferences) \
    || die "Could not read ticket #$issue from GitHub, so the facts of the defect are not known."
  # A defect is learnt from once (decisions A574b): the lesson an earlier retro saved says that one ran.
  earlier=""
  for file in "$sessions"/lessons/*.json; do
    [ -f "$file" ] || continue
    if jq -e --argjson issue "$issue" '.issue == $issue and (.facts.defect | type) == "object"' "$file" >/dev/null 2>&1; then
      earlier=$(basename "$file")
      break
    fi
  done
  jq -n --argjson issue "$issue" --argjson ticket "$ticket" --arg earlier "$earlier" '
    {pr: null, issue: $issue,
     defect: {url: $ticket.url, state: $ticket.state, labels: [$ticket.labels[].name]},
     fixed_by: [$ticket.closedByPullRequestsReferences[].number],
     earlier_lesson: (if $earlier == "" then null else $earlier end)}'
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
  # A job stopped at its time limit ends cancelled with no failed step: that it asked for its retro tells it (decisions A434b).
  failed=$(jq -sc --arg workflow "$workflow" '
    map(select(.conclusion == "failure" or .conclusion == "timed_out" or ((.steps // []) | any(.conclusion == "failure"
      or (.name == "Start a retro when this job failed" and .conclusion == "success")))))
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

view=$(gh pr view "$pr" --json number,title,headRefName,state,mergedAt,labels,createdAt) \
  || die "Could not read pull request #$pr from GitHub, so its facts are not known."
branch=$(jq -r .headRefName <<<"$view")
issue=$("$script_dir/linked-issue.sh" "$pr")
rounds=$("$script_dir/fix-rounds.sh" "$pr") \
  || die "Could not count the fix rounds of pull request #$pr, so its facts are not known."
owner_rounds=$("$script_dir/fix-rounds.sh" "$pr" owner) \
  || die "Could not count the owner's fix rounds of pull request #$pr, so its facts are not known."
# A verdict is the factory's own comment, and the REST list names its account in full (decisions U563l).
bodies=$(gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
    --jq '.[] | select(.user.login == "github-actions[bot]") | {body: (.body // "")}' | jq -cs 'map(.body)') \
  || die "Could not read the comments of pull request #$pr from GitHub, so its reviewers' verdicts are not known."

# Each read is on its own line, so that a failed read stops here and is not taken for "nothing failed" (decisions H7).
# A run of a fork's pull request on a branch of the same name ran the fork's copy, and its log holds what the fork wrote.
runs=$(gh api --method GET "repos/{owner}/{repo}/actions/workflows/ci.yml/runs" -f branch="$branch" -f per_page=20 \
    --jq '.workflow_runs[] | select(.conclusion == "failure" and .head_repository.full_name == .repository.full_name) | .id') \
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

jq -n --argjson view "$view" --argjson bodies "$bodies" --arg issue "$issue" --argjson rounds "$rounds" --argjson owner_rounds "$owner_rounds" --argjson failed "$failed" --argjson agents "$agents" '
  # The assumptions of a verdict: the hidden last line post-verdict.sh wrote (decisions A55b, A55c).
  # A verdict from before that line has none; one from before the install holds `unverified`
  # claims in three parts (decisions A224b).
  def assumptions: [split("\n")[] | select(. != "")] | last
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
