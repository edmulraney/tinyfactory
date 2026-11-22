#!/usr/bin/env bash
# Tests for factory/scripts/run-facts.sh, which prints the facts of a run as JSON for the retro.
. "$(dirname "$0")/helpers.sh"

# $T/fail lists the gh calls that fail by their first words, $T/fail-exactly those that fail only word for word,
# $T/fail-again those that fail word for word from the second time they are made.
github() {
  : > "$T/fail"; : > "$T/fail-exactly"; : > "$T/fail-again"
  mkdir -p "$T/sessions/lessons"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    if grep -qxF -- "$*" "$T/fail-exactly"; then echo "gh: failed: $*" >&2; exit 1; fi
    if grep -qxF -- "$*" "$T/fail-again" && [ "$(grep -cxF -- "gh $*" "$T/calls")" -ge 2 ]; then echo "gh: failed: $*" >&2; exit 1; fi
    case "$*" in
      "api repos/{owner}/{repo}/actions/runs/900/jobs --paginate "*) json "$(cat "$T/jobs")" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/900") cat "$T/run" ;;
      "api repos/{owner}/{repo}/actions/runs/900 --jq .run_attempt") json "$(cat "$T/run")" "$@" ;;
      "api repos/{owner}/{repo}/issues/comments/5 --jq "* | "api repos/{owner}/{repo}/pulls/comments/8 --jq "*) json "$(cat "$T/comment")" "$@" ;;
      "run download 900 --name session-claude-900-1 --dir "*) [ ! -e "$T/artifact.json" ] || cp "$T/artifact.json" "${*: -1}/claude-execution-output.json" ;;
      "api repos/{owner}/{repo}/actions/jobs/"*"/logs" | "api repos/{owner}/{repo}/actions/jobs/"*"/logs --allow-escape-sequences")
        id=${2#*/jobs/}; id=${id%/logs}
        if [ -f "$T/log-$id.later" ] && [ "$(grep -c "jobs/$id/logs" "$T/calls")" -ge 3 ]; then cat "$T/log-$id.later"
        elif [ -f "$T/log-$id" ] && [ $# -eq 2 ] && grep -q "$(printf "\\033")" "$T/log-$id"; then
          echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2; exit 1
        elif [ -f "$T/log-$id" ]; then cat "$T/log-$id"
        else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
      "issue view 574 --json url,state,labels,closedByPullRequestsReferences") cat "$T/ticket" ;;
      "pr view 66 --json body "*) json "{\"body\":\"Closes #63\"}" "$@" ;;
      "pr view 72 --json body "*) json "{\"body\":\"Closes #57\"}" "$@" ;;
      "pr view 72 --json number,"*) json "$(cat "$T/pr")" "$@" ;;
      "pr diff 72") cat "$T/diff" ;;
      "api repos/{owner}/{repo}/contents/factory/workflows/"*"?ref=refs/pull/72/head -H Accept: application/vnd.github.raw+json")
        name=${2#*/workflows/}; cat "$T/source-${name%%\?*}" ;;
      "pr comment 72 --body-file "*) ;;
      # One list on GitHub, asked for twice: $T/comments answers the read of the verdicts, and $T/rounds fix-rounds.sh.
      "api repos/{owner}/{repo}/issues/72/comments?per_page=100 --paginate --jq "*"{body: "*) json "$(cat "$T/comments")" "$@" ;;
      "api repos/{owner}/{repo}/issues/72/comments?per_page=100 "*) json "$(cat "$T/rounds")" "$@" ;;
      "run list --workflow ci.yml --branch feat/57-test-with-current-main "*) json "$(cat "$T/ci-runs")" "$@" ;;
      "run view 801 --json jobs "*) json "{\"jobs\":[{\"name\":\"checks\",\"conclusion\":\"success\"},{\"name\":\"review\",\"conclusion\":\"failure\"}]}" "$@" ;;
      "run view 802 --json jobs "*) json "{\"jobs\":[{\"name\":\"review\",\"conclusion\":\"failure\"},{\"name\":\"e2e\",\"conclusion\":\"failure\"}]}" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
}

a_run() {  # a_run <workflow> <event> <conclusion>
  echo "{\"id\":900,\"path\":\".github/workflows/$1.yml\",\"event\":\"$2\",\"run_attempt\":1,\"conclusion\":\"$3\",\"html_url\":\"https://github.example/runs/900\"}" > "$T/run"
}
step() {  # step <name> <conclusion> <started hh:mm:ss> <completed hh:mm:ss>
  echo "{\"name\":\"$1\",\"conclusion\":\"$2\",\"started_at\":\"2026-11-16T$3.000Z\",\"completed_at\":\"2026-11-16T$4.000Z\"}"
}
a_job() {  # a_job <id> <name> <conclusion or null> <step>...
  local id="$1" name="$2" conclusion="$3" steps
  shift 3
  steps=$(printf '%s\n' "$@" | jq -sc .)
  [ "$conclusion" = null ] || conclusion="\"$conclusion\""
  echo "{\"id\":$id,\"name\":\"$name\",\"conclusion\":$conclusion,\"steps\":$steps}"
}
jobs_are() { printf '%s\n' "$@" | jq -sc '{jobs: .}' > "$T/jobs"; }

# The shape of a real session cut short by an overloaded API: issue-57, run 43822853321.
a_session_cut_short() {  # a_session_cut_short <folder> <role>
  mkdir -p "$T/sessions/$1"
  {
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Committing."}]}}'
    echo '{"type":"system","subtype":"api_retry","attempt":1,"error_status":529,"error":"overloaded"}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result"}]}}'
    for attempt in 1 2 3 4 5 6 7; do
      echo "{\"type\":\"system\",\"subtype\":\"api_retry\",\"attempt\":$attempt,\"max_retries\":7,\"error_status\":529,\"error\":\"overloaded\"}"
    done
    echo '{"type":"assistant","error":"server_error","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 529 Overloaded."}]}}'
    echo '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"result":"API Error: 529 Overloaded. This is a server-side issue.","total_cost_usd":5.4384607,"num_turns":41,"duration_ms":979154}'
  } | jq -sc . > "$T/sessions/$1/20261116T073527Z-$2-run900.json"
}
a_session_that_finished() {  # a_session_that_finished <folder> <role> <run> <cost>
  mkdir -p "$T/sessions/$1"
  echo "[{\"type\":\"assistant\"},{\"type\":\"result\",\"is_error\":false,\"terminal_reason\":\"completed\",\"api_error_status\":null,\"result\":\"Pull request opened.\",\"total_cost_usd\":$4,\"num_turns\":20,\"duration_ms\":60400}]" \
    > "$T/sessions/$1/20261116T080000Z-$2-run$3.json"
}

a_build_cut_short() {
  a_run implement issues failure
  jobs_are "$(a_job 31 implement failure \
    "$(step "Validate the ticket against its template" success 07:19:00 07:19:02)" \
    "$(step "The engineer builds the ticket" failure 07:19:10 07:35:20)" \
    "$(step "Save the session transcript" success 07:35:21 07:35:27)")"
  cat > "$T/log-31" <<'LOG'
2026-11-16T07:19:00.1000000Z ##[group]Run if ! problems=$(factory/scripts/check-ticket.sh "$ISSUE"); then
2026-11-16T07:19:00.2000000Z env:
2026-11-16T07:19:00.3000000Z   ISSUE: 57
2026-11-16T07:19:00.4000000Z   GH_TOKEN: ***
2026-11-16T07:19:00.5000000Z ##[endgroup]
2026-11-16T07:19:10.1000000Z ##[group]Run anthropics/claude-code-action@v1
2026-11-16T07:19:10.2000000Z ##[endgroup]
2026-11-16T07:35:19.1000000Z   "is_error": true,
2026-11-16T07:35:20.1000000Z ##[error]Process completed with exit code 1.
2026-11-16T07:35:21.1000000Z saved fred session as issue-57/20261116T073527Z-fred-run900.json
LOG
  a_session_cut_short issue-57 fred
}

a_merge_github_refused() {
  a_run approve-merge pull_request_review failure
  jobs_are "$(a_job 41 ship failure \
    "$(step "Run actions/checkout@v4" success 06:55:00 06:55:02)" \
    "$(step "Ship it, if the owner approved this exact commit and its checks passed" failure 06:55:03 06:55:09)")"
  cat > "$T/log-41" <<'LOG'
2026-11-16T06:55:03.1000000Z ##[group]Run view=$(gh pr view "$PR" --json state,headRefOid,reviews)
2026-11-16T06:55:03.2000000Z env:
2026-11-16T06:55:03.3000000Z   GH_TOKEN: ***
2026-11-16T06:55:03.4000000Z   PR: 66
2026-11-16T06:55:03.5000000Z ##[endgroup]
2026-11-16T06:55:08.1000000Z GraphQL: 502 Bad Gateway (mergePullRequest)
2026-11-16T06:55:09.1000000Z ##[error]Process completed with exit code 1.
LOG
}

fact() { jq -r "$1" <<<"$out" 2>/dev/null; }
expect_fact() {  # expect_fact <jq filter> <value>
  local actual
  actual=$(fact "$1") || actual="(the output is not JSON)"
  [ "$actual" = "$2" ] || fail "expected $1 to be $2, got: $actual"
}

scenario "a failed run: names the job and step that failed, and the workflow"
github; a_build_cut_short
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact .run 900
expect_fact .workflow implement
expect_fact .event issues
expect_fact .url https://github.example/runs/900
expect_fact .conclusion failure
expect_fact '.failed | length' 1
expect_fact '.failed[0].job' implement
expect_fact '.failed[0].step' "The engineer builds the ticket"
expect_fact .factory_failure true

scenario "a failed run: gives the end of the failed step's log, and not the steps around it"
github; a_build_cut_short
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact '.failed[0].log | contains("\"is_error\": true")' true
expect_fact '.failed[0].log | contains("Process completed with exit code 1")' true
expect_fact '.failed[0].log | contains("saved fred session")' false
expect_fact '.failed[0].log | contains("ISSUE: 57")' false
expect_fact '.failed[0].log | contains("##[group]")' false
expect_fact '.failed[0].log | contains("2026-11-16T")' false

scenario "a failed run: gives no more than the last 60 lines of a long step"
github; a_build_cut_short
for line in $(seq 1 200); do echo "2026-11-16T07:20:00.0000000Z line $line"; done >> "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact '.failed[0].log | split("\n") | length' 60
expect_fact '.failed[0].log | split("\n") | last' "line 200"

scenario "an agent session that ended on an API error: says how it ended, the retries before it, and its cost"
github; a_build_cut_short
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.agents | length' 1
expect_fact '.agents[0].role' fred
expect_fact '.agents[0].file' issue-57/20261116T073527Z-fred-run900.json
expect_fact '.agents[0].error' true
expect_fact '.agents[0].terminal_reason' api_error
expect_fact '.agents[0].api_error_status' 529
expect_fact '.agents[0].api_retries' 7
expect_fact '.agents[0].result' "API Error: 529 Overloaded. This is a server-side issue."
expect_fact '.agents[0].turns' 41
expect_fact '.agents[0].seconds' 979
expect_fact .cost_usd 5.44
expect_fact .turns 41

scenario "a failed run: the ticket is the issue its log names"
github; a_build_cut_short
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact .issue 57
expect_fact .pr null
expect_no_call "gh pr view"

scenario "a failed run: counts only the sessions of that run"
github; a_build_cut_short
a_session_that_finished issue-57 fred 901 6.82
a_session_that_finished lessons lesson 900 0.94
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact '.agents | length' 1
expect_fact .cost_usd 5.44

scenario "a session that finished: no error, no reason given, no retries"
github; a_build_cut_short
rm "$T/sessions/issue-57/"*
a_session_that_finished issue-57 fred 900 6.82
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact '.agents[0].error' false
expect_fact '.agents[0].terminal_reason' completed
expect_fact '.agents[0].api_error_status' null
expect_fact '.agents[0].api_retries' 0
expect_fact '.agents[0].result' null
expect_fact '.agents[0].seconds' 60

scenario "a step that failed on a GitHub error: the log's end holds the error, and the ticket is the one the pull request closes"
github; a_merge_github_refused
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact .workflow approve-merge
expect_fact '.failed[0].job' ship
expect_fact '.failed[0].step' "Ship it, if the owner approved this exact commit and its checks passed"
expect_fact '.failed[0].log | contains("502 Bad Gateway")' true
expect_fact .pr 66
expect_fact .issue 63
expect_fact .factory_failure true

scenario "a run with no agent session: no agents and no cost"
github; a_merge_github_refused
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.agents | length' 0
expect_fact .cost_usd 0
expect_fact .turns 0

scenario "a run with no agent session: the same without a sessions folder"
github; a_merge_github_refused
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900
expect_status 0
expect_fact '.agents | length' 0
expect_fact .pr 66

scenario "a ci run: a failed check or review is not the factory's failure"
github
a_run ci pull_request failure
jobs_are "$(a_job 51 checks success "$(step "Lint" success 08:00:00 08:00:30)")" \
         "$(a_job 52 review failure "$(step "Adam reviews architecture and taste, and Ryan correctness, at the same time" failure 08:02:00 08:02:01)")" \
         "$(a_job 53 start-fix success "$(step "Start a fix round, unless three have been used" success 08:03:00 08:03:05)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed | length' 0
expect_fact .factory_failure false
expect_no_call "/logs"

scenario "a ci run that began before fix.yml: a failed fix job is the factory's failure, and the failed review beside it is not listed"
github
a_run ci pull_request failure
jobs_are "$(a_job 52 review failure "$(step "Adam reviews architecture and taste, and Ryan correctness, at the same time" failure 08:02:00 08:02:01)")" \
         "$(a_job 53 fix failure "$(step "The engineer fixes the pull request" failure 08:03:00 08:09:00)")"
printf '2026-11-16T08:03:00.1000000Z   PR: 72\n2026-11-16T08:09:00.0000000Z ##[error]Process completed with exit code 1.\n' > "$T/log-53"
a_session_cut_short pr-72 fred-fix
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed | map(.job) | join(",")' fix
expect_fact .factory_failure true
expect_fact .pr 72
expect_fact .issue 57
expect_fact '.agents[0].role' fred-fix
expect_no_call "jobs/52/logs"

scenario "a ci run: a failed start-fix job is the factory's failure too"
github
a_run ci pull_request failure
jobs_are "$(a_job 51 checks failure "$(step "Lint" failure 08:00:00 08:00:30)")" \
         "$(a_job 54 start-fix failure "$(step "Start a fix round, unless three have been used" failure 08:03:00 08:03:05)")"
printf '2026-11-16T08:03:00.1000000Z   PR: 72\n2026-11-16T08:03:05.0000000Z The fix round for pull request #72 could not be started\n' > "$T/log-54"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed | map(.job) | join(",")' start-fix
expect_fact .factory_failure true
expect_fact .pr 72

scenario "a fix run: any failed job is the factory's failure, and its pull request is known"
github
a_run fix workflow_dispatch failure
jobs_are "$(a_job 55 fix failure "$(step "Count the round, or fail if the engineer's session never began" failure 08:03:00 08:03:05)")"
printf '2026-11-16T08:03:00.1000000Z   PR: 72\n2026-11-16T08:03:05.0000000Z The fix round did not run\n' > "$T/log-55"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact .workflow fix
expect_fact '.failed[0].step' "Count the round, or fail if the engineer's session never began"
expect_fact .factory_failure true
expect_fact .pr 72
expect_fact .issue 57

scenario "a job still finishing: its failed step already counts"
github; a_build_cut_short
jobs_are "$(a_job 31 implement null \
  "$(step "The engineer builds the ticket" failure 07:19:10 07:35:20)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact '.failed[0].step' "The engineer builds the ticket"
expect_fact .factory_failure true

scenario "a job that ran out of time: it counts, with no step named"
github; a_build_cut_short
jobs_are "$(a_job 31 implement timed_out \
  "$(step "The engineer builds the ticket" cancelled 07:19:10 08:19:10)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].job' implement
expect_fact '.failed[0].step' null
expect_fact '.failed[0].log | contains("ISSUE: 57")' true
expect_fact .issue 57
expect_fact .factory_failure true

scenario "a job stopped at its time limit that asked for its retro: it counts, with no step named"
github; a_build_cut_short
jobs_are "$(a_job 31 implement cancelled \
  "$(step "The engineer builds the ticket" cancelled 07:19:10 08:19:10)" \
  "$(step "Start a retro when this job failed" success 08:19:12 08:19:13)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].job' implement
expect_fact '.failed[0].step' null
expect_fact .factory_failure true

scenario "a job a person cancelled, which asked for no retro: not the factory's failure"
github; a_build_cut_short
jobs_are "$(a_job 31 implement cancelled \
  "$(step "The engineer builds the ticket" cancelled 07:19:10 07:25:00)" \
  "$(step "Start a retro when this job failed" skipped 07:25:02 07:25:02)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed | length' 0
expect_fact .factory_failure false

scenario "a ticket refused at validation: failed as designed, so not the factory's failure"
github
a_run implement issues failure
jobs_are "$(a_job 31 implement failure \
  "$(step "Validate the ticket against its template" failure 07:19:00 07:19:02)")"
printf '2026-11-16T07:19:00.3000000Z   ISSUE: 57\n' > "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].step' "Validate the ticket against its template"
expect_fact .factory_failure false

scenario "a build that could not find out whether it had a place is the factory's failure"
github
a_run implement issues failure
jobs_are "$(a_job 31 implement failure \
  "$(step "Take a place among the tickets in flight" failure 07:19:00 07:19:02)")"
printf '2026-11-16T07:19:00.3000000Z   ISSUE: 57\n' > "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact .factory_failure true

scenario "the same step name in another workflow is a failure like any other"
github
a_run approve-merge workflow_dispatch failure
jobs_are "$(a_job 31 ship failure \
  "$(step "Validate the ticket against its template" failure 07:19:00 07:19:02)")"
printf '2026-11-16T07:19:00.3000000Z   PR: 66\n' > "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_fact .factory_failure true

scenario "a run in which nothing failed: not the factory's failure"
github
a_run implement issues success
jobs_are "$(a_job 31 implement success "$(step "The engineer builds the ticket" success 07:19:10 07:35:20)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed | length' 0
expect_fact .factory_failure false

scenario "a log GitHub is slow to serve: asked for again until it comes"
github; a_build_cut_short
mv "$T/log-31" "$T/log-31.later"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].log | contains("Process completed with exit code 1")' true
[ "$(grep -c 'jobs/31/logs' "$T/calls")" = 3 ] || fail "expected three askings, got $(grep -c 'jobs/31/logs' "$T/calls")"

scenario "a log that never comes: says so, and the ticket is known by where the transcript was saved"
github; a_build_cut_short
rm "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].log' "(log not available after a minute: gh: Not Found (HTTP 404))"
expect_fact '.failed[0].step' "The engineer builds the ticket"
expect_fact .issue 57
expect_fact '.agents[0].terminal_reason' api_error
[ "$(grep -c 'jobs/31/logs' "$T/calls")" = 6 ] || fail "expected six askings, got $(grep -c 'jobs/31/logs' "$T/calls")"

scenario "an empty log with no error: says that is why no log came"
github; a_build_cut_short
: > "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].log' "(log not available after a minute: an empty log, with no error)"

scenario "a failed step's log that holds colour codes, which gh refuses unless asked: read, and the codes stripped (A370)"
github; a_build_cut_short
printf '2026-11-16T07:35:19.1000000Z \033[36;1mpnpm lint\033[0m\n2026-11-16T07:35:20.1000000Z \033[31msrc/page.tsx: unused variable\033[0m\n' > "$T/log-31"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].log' "pnpm lint"$'\n'"src/page.tsx: unused variable"
[ "$(grep -c 'jobs/31/logs' "$T/calls")" = 1 ] || fail "expected one asking, got $(grep -c 'jobs/31/logs' "$T/calls")"

scenario "no temporary file to hold gh's error: stops and says so"
github; a_build_cut_short
stub mktemp 'exit 1'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 1
expect_output "Could not make a temporary file, so the facts of the run were not read."

scenario "no log and no transcript: the ticket is not known, and the facts say so"
github; a_merge_github_refused
rm "$T/log-41"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact .pr null
expect_fact .issue null
expect_fact .factory_failure true

scenario "step times in a form it does not know: the end of the whole job's log"
github; a_build_cut_short
jq -c '.jobs[0].steps[1].started_at = "2026-11-16T07:19:10.000-08:00"' "$T/jobs" > "$T/jobs.new" && mv "$T/jobs.new" "$T/jobs"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.failed[0].log | contains("Process completed with exit code 1")' true
expect_fact '.failed[0].log | contains("saved fred session")' true

scenario "a transcript that cannot be read: listed as unreadable, not left out"
github; a_build_cut_short
echo 'not json' > "$T/sessions/issue-57/20261116T073527Z-fred-run900.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.agents[0].unreadable' true
expect_fact '.agents[0].role' fred
expect_fact .cost_usd 0

scenario "a transcript that is an empty file: listed as unreadable, not left out"
github; a_build_cut_short
: > "$T/sessions/issue-57/20261116T073527Z-fred-run900.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.agents | length' 1
expect_fact '.agents[0].unreadable' true

scenario "a transcript that ends with no result: its cost is null, not nothing"
github; a_build_cut_short
echo '[{"type":"system","subtype":"init","model":"claude-fable-5-2"},{"type":"assistant"}]' > "$T/sessions/issue-57/20261116T073527Z-fred-run900.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_status 0
expect_fact '.agents[0].cost_usd' null
expect_fact '.agents[0].model' claude-fable-5-2
expect_fact .cost_usd 0

scenario "a failed run: stops with a message, and prints no facts, when the run cannot be read"
github; a_build_cut_short
echo "api repos/{owner}/{repo}/actions/runs/900" > "$T/fail-exactly"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_failure
expect_output "gh: failed: api repos/{owner}/{repo}/actions/runs/900"
expect_output "Could not read workflow run 900 from GitHub"
expect_no_output '"factory_failure"'
expect_no_call "runs/900/jobs"

scenario "a failed run: stops with a message, and prints no facts, when its jobs cannot be read"
github; a_build_cut_short
echo "api repos/{owner}/{repo}/actions/runs/900/jobs" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_failure
expect_output "gh: failed: api repos/{owner}/{repo}/actions/runs/900/jobs"
expect_output "Could not read the jobs of workflow run 900 from GitHub"
expect_no_output '"factory_failure"'
expect_no_call "/logs"

scenario "a failed run: stops with a message when the pull request's ticket cannot be read"
github; a_merge_github_refused
echo "pr view 66" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
expect_failure
expect_output "Could not read pull request #66 from GitHub"
expect_no_output '"factory_failure"'

comment() {
  jq --arg body "$1" --arg login "${2:-github-actions[bot]}" '. + [{user: {login: $login}, body: $body}]' "$T/comments" > "$T/comments.new" \
    && mv "$T/comments.new" "$T/comments"
}
# Ryan's review and the engineer's reply both quote the fix-round marker, as they did on the real pull request.
a_pull_request() {
  jq -n '[{id: 1, user: {login: "github-actions[bot]"}, body: "**Ryan (code): FAIL**\nIt counts any comment holding <!-- factory:fix-round -->"},
          {id: 2, user: {login: "github-actions[bot]"}, body: "<!-- factory:fix-round -->Fix round 1 of 3"},
          {id: 3, user: {login: "claude[bot]"}, body: "<!-- factory:fix-round --> is now counted once."}]' > "$T/rounds"
  jq -n '{number: 72, title: "feat: test with main", headRefName: "feat/57-test-with-current-main", state: "MERGED",
          mergedAt: "2026-11-16T08:30:00Z", labels: [], createdAt: "2026-11-16T08:00:00Z"}' > "$T/pr"
  echo '[]' > "$T/comments"
  comment "**Adam (architecture): PASS**"
  comment "**Ryan (code): FAIL**"$'\n'"findings"
  comment "<!-- factory:fix-round -->Fix round 1 of 3"
  comment "**Ryan (code): PASS**"
  comment "**Adam (architecture): PASS**"
  echo '[{"databaseId":801,"conclusion":"failure"},{"databaseId":802,"conclusion":"failure"},{"databaseId":803,"conclusion":"success"}]' > "$T/ci-runs"
  a_session_that_finished issue-57 fred 800 6.82
  a_session_that_finished pr-72 ryan 801 1.84
  a_session_that_finished pr-72 fred-fix 801 1.55
}

scenario "a pull request the owner sent back: the owner's rounds are told apart from the three"
github; a_pull_request
jq '. + [{id: 4, user: {login: "github-actions[bot]"}, body: "<!-- factory:owner-round -->The owner'"'"'s fix round: the engineer'"'"'s session ran."}]' "$T/rounds" > "$T/rounds.new"
mv "$T/rounds.new" "$T/rounds"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact .fix_rounds 1
expect_fact .owner_rounds 1

scenario "a pull request: fix rounds, verdicts, outcome, and each failed job with how often it failed"
github; a_pull_request
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact .pr 72
expect_fact .issue 57
expect_fact .outcome merged
expect_fact .fix_rounds 1
expect_fact .owner_rounds 0
expect_fact '.reviews | "\(.adam.pass) \(.adam.fail) \(.ryan.pass) \(.ryan.fail)"' "2 0 1 1"
expect_fact '.failed_jobs | map("\(.job) \(.times)") | join(", ")' "e2e 1, review 2"
expect_no_call "gh run view 803"

scenario "a pull request: a pass carried forward is counted apart from the passes a reviewer gave"
github; a_pull_request
carried='Carried forward from the review of abc1234: every commit since is a merge of `main`. No review ran. <!-- factory:carried -->'
comment "**Adam (architecture): PASS**"$'\n\n'"$carried"$'\n\n'"Fits."$'\n\n'"<!-- factory:assumptions [] -->"
comment "**Ryan (code): PASS**"$'\n\n'"It marks one with"$'\n'"$carried"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.adam | "pass \(.pass), carried \(.carried), fail \(.fail)"' "pass 2, carried 1, fail 0"
# Ryan's pass only quotes the line, below where the script writes it.
expect_fact '.reviews.ryan | "pass \(.pass), carried \(.carried), fail \(.fail)"' "pass 2, carried 0, fail 1"

# A verdict is its comment's first line (decisions A137).
a_lone_verdict() {
  echo '[]' > "$T/comments"
  comment "$1"
}

scenario "a pull request: a verdict headed PASS that quotes a failing one is one pass and no failure"
github; a_pull_request
a_lone_verdict '**Ryan (code): PASS**'$'\n\n''It reads `**<name>: PASS**` or `**<name>: FAIL**`, or "<name>: no verdict".'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.ryan | "pass \(.pass), fail \(.fail)"' "pass 1, fail 0"

scenario "a pull request: a verdict headed FAIL that quotes a passing one is one failure and no pass"
github; a_pull_request
a_lone_verdict '**Ryan (code): FAIL**'$'\n\n''It reads `**Ryan: PASS**` as a pass.'$'\n\n''<!-- factory:assumptions [{"assumes":"c","if_wrong":"r"}] -->'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.ryan | "pass \(.pass), fail \(.fail)"' "pass 0, fail 1"
expect_fact '.reviews.ryan.assumptions | length' 1

scenario "a pull request: a comment that only quotes a verdict below its first line is no verdict"
github; a_pull_request
a_lone_verdict '**Ryan** said this last time:'$'\n''**Ryan (code): FAIL**'$'\n\n''<!-- factory:assumptions [{"assumes":"c","if_wrong":"r"}] -->'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.ryan | "pass \(.pass), fail \(.fail)"' "pass 0, fail 0"
expect_fact '.reviews.ryan.assumptions | length' 0

# verdict <reviewer> <json> [login]: posted by the real post-verdict.sh, so a change to what that script writes fails here.
verdict() {
  OUTPUT="$2" RUNNER_TEMP="$T/tmp" "$scripts/post-verdict.sh" "$1" 72 > /dev/null || true
  comment "$(cat "$T/tmp/verdict.md")" "${3:-}"
  rm "$T/tmp/verdict.md"
  : > "$T/calls"
}
queue='{"assumes":"GitHub accepts `queue: max` on a job.","if_wrong":"Every merge stops."}'
token='{"assumes":"The action takes `client-id`.","if_wrong":"No token is made."}'

scenario "a pull request: each review's assumptions are among the facts, each one once"
github; a_pull_request
verdict "Ryan (correctness)" "{\"findings\":[{\"file\":\"a.sh\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"}],\"assumptions\":[$queue,$token]}"
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[]}'
verdict "Ryan (correctness)" "{\"verdict\":\"pass\",\"findings\":[],\"assumptions\":[$queue]}"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.ryan.assumptions | tojson' "$(jq -c . <<<"[$queue,$token]")"
expect_fact '.reviews.adam.assumptions | tojson' "[]"
expect_fact '.reviews | "\(.adam.pass) \(.adam.fail) \(.ryan.pass) \(.ryan.fail)"' "3 0 2 2"

scenario "a pull request: a verdict posted before the install, with unverified claims in three parts, is read as assumptions"
github; a_pull_request
a_lone_verdict '**Ryan (code): PASS**'$'\n\n''**Not verified**'$'\n\n''1. An old claim.'$'\n\n''<!-- factory:unverified [{"claim":"An old claim.","why":"No page.","risk":"Something."},{"claim":"A second.","why":"Not run.","risk":"Something else."}] -->'
verdict "Ryan (correctness)" "{\"findings\":[],\"assumptions\":[$queue]}"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
old='{"assumes":"A second.","if_wrong":"Something else."},{"assumes":"An old claim.","if_wrong":"Something."}'
expect_fact '.reviews.ryan.assumptions | tojson' "$(jq -c . <<<"[$old,$queue]")"

scenario "a pull request reviewed before there was a list: no assumptions, and the verdicts still counted"
github; a_pull_request
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews | "\(.adam.assumptions | length) \(.ryan.assumptions | length)"' "0 0"
expect_fact '.reviews | "\(.adam.pass) \(.adam.fail) \(.ryan.pass) \(.ryan.fail)"' "2 0 1 1"

scenario "a pull request: a list quoted in a comment that is no verdict is not a fact"
github; a_pull_request
quoted="The retro reads this:"$'\n'"<!-- factory:assumptions [$queue] -->"
comment "$quoted"
comment "**Ryan (code): PASS**"$'\n'"$quoted"$'\n'"as its last line."
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews | "\(.adam.assumptions | length) \(.ryan.assumptions | length)"' "0 0"

scenario "a pull request: stops with a message, and prints no facts, when a verdict's list cannot be read"
github; a_pull_request
comment "**Ryan (code): PASS**"$'\n'"Fine."$'\n\n''<!-- factory:assumptions [{"claim": -->'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_failure
expect_output "A verdict on pull request #72 holds a list of assumptions that could not be read"
expect_no_output '"fix_rounds"'

scenario "a pull request: a verdict, and a list of assumptions, in another account's comment is no fact, and the factory's own still is"
github; a_pull_request
verdict "Ryan (correctness)" "{\"verdict\":\"pass\",\"findings\":[],\"assumptions\":[$queue]}"
verdict "Ryan (correctness)" "{\"findings\":[{\"file\":\"a.sh\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"}],\"assumptions\":[$token]}" stranger
verdict "Adam (architecture and taste)" "{\"verdict\":\"pass\",\"findings\":[],\"assumptions\":[$token]}" github-actions
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_status 0
expect_fact '.reviews.ryan.assumptions | tojson' "$(jq -c . <<<"[$queue]")"
expect_fact '.reviews.adam.assumptions | tojson' "[]"
expect_fact '.reviews | "\(.adam.pass) \(.adam.fail) \(.ryan.pass) \(.ryan.fail)"' "2 0 2 1"

scenario "a pull request: stops with a message, and prints no facts, when its comments cannot be read"
github; a_pull_request
echo 'api repos/{owner}/{repo}/issues/72/comments?per_page=100 --paginate --jq .[] | select(.user.login == "github-actions[bot]") | {body: (.body // "")}' > "$T/fail-exactly"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_failure
expect_output "Could not read the comments of pull request #72 from GitHub, so its reviewers' verdicts are not known."
expect_no_output '"fix_rounds"'

scenario "a pull request: the sessions saved for it and for its ticket, and what they cost together"
github; a_pull_request
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_fact '.agents | map(.role) | sort | join(",")' "fred,fred-fix,ryan"
expect_fact .cost_usd 10.21
expect_fact .turns 60
expect_fact '.agents | map(.terminal_reason) | unique | join(",")' completed

scenario "a pull request: when it merged, and the model each session began on, or none when its transcript does not say"
github; a_pull_request
echo '[{"type":"system","subtype":"init","model":"claude-fable-5-2"},{"type":"result","total_cost_usd":1.84,"num_turns":20}]' \
  > "$T/sessions/pr-72/20261116T080000Z-ryan-run801.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_fact .merged_at 2026-11-16T08:30:00Z
expect_fact '.agents | map(select(.role == "ryan"))[0].model' claude-fable-5-2
expect_fact '.agents | map(select(.role == "fred"))[0].model' null

scenario "a pull request with no failed run and no sessions folder"
github; a_pull_request
echo '[]' > "$T/ci-runs"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72
expect_status 0
expect_fact '.failed_jobs | length' 0
expect_fact '.agents | length' 0
expect_fact .cost_usd 0

scenario "a pull request stopped for a person"
github; a_pull_request
jq -c '.mergedAt = null | .state = "OPEN" | .labels = [{name: "needs-human"}]' "$T/pr" > "$T/pr.new" && mv "$T/pr.new" "$T/pr"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
expect_fact .outcome needs-human

while IFS='|' read -r words message; do
  scenario "a pull request: stops with a message, and prints no facts, when this fails: gh $words"
  github; a_pull_request
  echo "$words" > "$T/fail"
  run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" 72 "$T/sessions"
  expect_failure
  expect_output "gh: failed: $words"
  expect_output "$message"
  expect_no_output '"fix_rounds"'
done <<'READS'
pr view 72 --json number|Could not read pull request #72 from GitHub, so its facts are not known.
pr view 72 --json body|Could not read pull request #72 from GitHub, so the issue it closes is not known.
api repos/{owner}/{repo}/issues/72/comments|Could not count the fix rounds of pull request #72, so its facts are not known.
run list|Could not list the ci runs of feat/57-test-with-current-main
run view 802|Could not read the jobs of ci run 802
READS

# The diff adds one step to ci.yml and renames another, beside a context line, a removed line and another workflow's.
# $T/source-ci.yml is ci.yml as the pull request left it: the diff's added lines are its lines 7 to 10.
a_first_run() {
  a_pull_request
  a_run ci pull_request success
  jobs_are "$(a_job 51 checks success \
      "$(step "Run pnpm lint" success 09:00:00 09:01:00)" \
      "$(step "Trust the preview's address" success 09:01:01 09:01:05)" \
      "$(step "Run the unit tests" success 09:01:06 09:02:00)")" \
    "$(a_job 52 e2e success \
      "$(step "Wait for the preview" success 09:00:00 09:03:00)" \
      "$(step "Delete the preview's branch" skipped 09:03:00 09:03:00)")"
  cat > "$T/log-51" <<'LOG'
2026-11-16T09:00:59.1000000Z lint ok
2026-11-16T09:01:01.1000000Z ##[group]Run factory/scripts/trust-preview.sh
2026-11-16T09:01:01.2000000Z ##[endgroup]
2026-11-16T09:01:04.1000000Z trusted https://myapp-abc.vercel.app
2026-11-16T09:01:06.1000000Z 212 tests passed
LOG
  cat > "$T/log-52" <<'LOG'
2026-11-16T09:02:59.1000000Z the preview is up
2026-11-16T09:03:00.1000000Z Post job cleanup.
LOG
  cat > "$T/diff" <<'DIFF'
diff --git a/factory/workflows/ci.yml b/factory/workflows/ci.yml
index 1111111..2222222 100644
--- a/factory/workflows/ci.yml
+++ b/factory/workflows/ci.yml
@@ -5,3 +5,6 @@ jobs:
       - name: Run pnpm lint
         run: pnpm lint
+      - name: "Trust the preview's address"
+        run: factory/scripts/trust-preview.sh
-      - name: Run the unit tests
+      - name: Delete the preview's branch
+        if: always()
diff --git a/factory/workflows/retro.yml b/factory/workflows/retro.yml
index 3333333..4444444 100644
--- a/factory/workflows/retro.yml
+++ b/factory/workflows/retro.yml
@@ -4,0 +5,1 @@ jobs:
+      - name: Wait for the preview
diff --git a/apps/web/notes.yml b/apps/web/notes.yml
index 5555555..6666666 100644
--- a/apps/web/notes.yml
+++ b/apps/web/notes.yml
@@ -1,1 +1,2 @@
+      - name: Run pnpm lint
DIFF
  cat > "$T/source-ci.yml" <<'SOURCE'
name: ci
jobs:
  checks:
    steps:
      - name: Run pnpm lint
        run: pnpm lint
      - name: "Trust the preview's address"
        run: factory/scripts/trust-preview.sh
      - name: Delete the preview's branch
        if: always()
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
      - id: wait
        name: Wait for the preview
        run: |
          factory/scripts/wait-for-preview.sh
          - name: Run pnpm lint
SOURCE
  printf 'name: retro\njobs:\n  retro:\n    steps:\n      - name: Wait for the preview\n' > "$T/source-retro.yml"
}
# adds <line>...: the diff adds those lines of ci.yml, and no other.
adds() {
  local line
  printf 'diff --git a/factory/workflows/ci.yml b/factory/workflows/ci.yml\n--- a/factory/workflows/ci.yml\n+++ b/factory/workflows/ci.yml\n' > "$T/diff"
  for line in "$@"; do printf '@@ -%s,0 +%s,1 @@\n+%s\n' "$line" "$line" "$(sed -n "${line}p" "$T/source-ci.yml")"; done >> "$T/diff"
}

scenario "the first run of a changed workflow: the run's facts though nothing failed, and the pull request that changed it with its reviewers' assumptions"
github; a_first_run
verdict "Ryan (correctness)" "{\"verdict\":\"pass\",\"findings\":[],\"assumptions\":[$queue]}"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '"\(.run) \(.workflow) \(.conclusion) \(.url)"' "900 ci success https://github.example/runs/900"
expect_fact '.changed_by | "\(.pr) \(.issue)"' "72 57"
expect_fact '.changed_by.assumptions.ryan | tojson' "$(jq -c . <<<"[$queue]")"
expect_fact '.changed_by.assumptions.adam | tojson' "[]"

scenario "the first run of a changed workflow: stops with a message, and prints no facts, when the run cannot be read"
github; a_first_run
echo "api repos/{owner}/{repo}/actions/runs/900" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_failure
expect_output "Could not read workflow run 900 from GitHub"
expect_no_output '"changed_by"'

scenario "the first run of a changed workflow: stops with a message, and prints no facts, when the pull request cannot be read"
github; a_first_run
echo "pr view 72 --json number" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_failure
expect_output "Could not read pull request #72 from GitHub, so its facts are not known."
expect_no_output '"changed_by"'

scenario "the first run of a changed workflow: each step the diff adds to that workflow, with its job, its conclusion and its own part of the log"
github; a_first_run
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | map(.step) | sort | join(", ")' "Delete the preview's branch, Trust the preview's address"
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | "\(.job) \(.conclusion)"' "checks success"
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log' "trusted https://myapp-abc.vercel.app"
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log | contains("##[group]") or contains("2026-11-16T")' false

scenario "the first run of a changed workflow: a changed step that was skipped has its conclusion and no log"
github; a_first_run
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_fact '.changed_steps[] | select(.step | startswith("Delete")) | "\(.job) \(.conclusion) \(.log)"' "e2e skipped null"
expect_no_call "jobs/52/logs"

scenario "the first run of a changed workflow: a changed step the run never reached is listed with no job, conclusion or log"
github; a_first_run
jobs_are "$(a_job 51 checks success "$(step "Run pnpm lint" success 09:00:00 09:01:00)")"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | length' 2
expect_fact '.changed_steps | map("\(.job) \(.conclusion) \(.log)") | unique | join(", ")' "null null null"
expect_no_call "/logs"

scenario "the first run of a changed workflow: a changed step that failed is listed as failed, with its error"
github; a_first_run
jq -c '.jobs[0].conclusion = "failure" | .jobs[0].steps[1].conclusion = "failure"' "$T/jobs" > "$T/jobs.new" && mv "$T/jobs.new" "$T/jobs"
echo "2026-11-16T09:01:05.1000000Z ##[error]Process completed with exit code 1." >> "$T/log-51"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .conclusion' failure
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log | contains("exit code 1")' true

scenario "the first run of a changed workflow: no more than the last 60 lines of a long changed step"
github; a_first_run
for line in $(seq 1 200); do echo "2026-11-16T09:01:03.0000000Z line $line"; done >> "$T/log-51"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log | split("\n") | length' 60
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log | contains("line 200")' true

scenario "the first run of a changed workflow: two changed steps of one job read its log once"
github; a_first_run
sed -i.bak 's/^-      - name: Run the unit tests$/+      - name: Run the unit tests/' "$T/diff" && rm "$T/diff.bak"
awk 'NR == 9 { print "      - name: Run the unit tests" } { print }' "$T/source-ci.yml" > "$T/source-ci.new" && mv "$T/source-ci.new" "$T/source-ci.yml"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_fact '.changed_steps[] | select(.step == "Run the unit tests") | .log' "212 tests passed"
[ "$(grep -c 'jobs/51/logs' "$T/calls")" = 1 ] || fail "expected one asking, got $(grep -c 'jobs/51/logs' "$T/calls")"

scenario "the first run of a changed workflow: a changed step's log that never comes says so"
github; a_first_run
rm "$T/log-51"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | "\(.conclusion): \(.log)"' "success: (log not available after a minute: gh: Not Found (HTTP 404))"

scenario "the first run of a changed workflow: a changed step's log that holds colour codes is read, and the codes stripped (A370)"
github; a_first_run
printf '2026-11-16T09:01:04.1000000Z \033[32mtrusted https://myapp-abc.vercel.app\033[0m\n' > "$T/log-51"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps[] | select(.step | startswith("Trust")) | .log' "trusted https://myapp-abc.vercel.app"

scenario "the first run of a changed workflow: a pull request that names no step of it has no changed steps"
github; a_first_run
a_run retro workflow_dispatch success
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | map(.step) | join(", ")' "Wait for the preview"
grep -v '^+      - name: Wait for the preview$' "$T/diff" > "$T/diff.new" && mv "$T/diff.new" "$T/diff"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | tojson' "[]"
[ "$(grep -c 'contents/factory/workflows' "$T/calls")" = 1 ] || fail "expected the workflow to be read only when the diff adds a line to it"

scenario "the first run of a changed workflow: a step whose command or condition changed is listed, though its name did not"
github; a_first_run
adds 6 10
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | map(.step) | sort | join(", ")' "Delete the preview's branch, Run pnpm lint"
expect_fact '.changed_steps[] | select(.step == "Run pnpm lint") | "\(.job) \(.conclusion)"' "checks success"

scenario "the first run of a changed workflow: a step whose name is not its first line is found from any line of it"
github; a_first_run
for line in 17 21; do
  adds "$line"
  run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
  expect_status 0
  expect_fact '.changed_steps | map("\(.step) in \(.job)") | join(", ")' "Wait for the preview in e2e"
done

scenario "the first run of a changed workflow: a line of a step with no name, of a job outside its steps or above the jobs is no step's"
github; a_first_run
adds 1 11 12 16
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_status 0
expect_fact '.changed_steps | tojson' "[]"

scenario "the first run of a changed workflow: stops with a message, and prints no facts, when the workflow cannot be read as the pull request left it"
github; a_first_run
echo "api repos/{owner}/{repo}/contents/factory/workflows/ci.yml" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_failure
expect_output "Could not read factory/workflows/ci.yml as pull request #72 left it, so which steps it changed is not known."
expect_no_output '"changed_by"'

scenario "the first run of a changed workflow: stops with a message, and prints no facts, when the diff cannot be read"
github; a_first_run
echo "pr diff 72" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_failure
expect_output "Could not read the diff of pull request #72, so which steps it changed is not known."
expect_no_output '"changed_by"'

scenario "the first run of a changed workflow: stops with a message, and prints no facts, when the jobs cannot be read for the changed steps"
github; a_first_run
echo "api repos/{owner}/{repo}/actions/runs/900/jobs --paginate --jq .jobs[]" > "$T/fail-again"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --first-run 72 900 "$T/sessions"
expect_failure
expect_output "Could not read the jobs of workflow run 900 from GitHub, so what its changed steps did is not known."
expect_no_output '"changed_by"'

# A `claude` run that answered the owner's comment on ticket #12, and left its transcript on the run.
a_request_answered() {
  a_run claude issue_comment success
  jobs_are "$(a_job 51 claude success "$(step "The agent does what the owner asked" success 08:00:00 08:03:00)")"
  echo '{"id":5,"body":"@claude start #12, which has waited since Monday","html_url":"https://github.example/owner/myapp/issues/12#issuecomment-5","user":{"login":"owner"}}' > "$T/comment"
  echo '[{"type":"assistant"},{"type":"result","is_error":false,"terminal_reason":"completed","total_cost_usd":0.42,"num_turns":9,"duration_ms":180000}]' > "$T/artifact.json"
}
ask="https://github.example/owner/myapp/issues/12#issuecomment-5"

scenario "a request for help: the comment's text and link, the ticket it is on, and the transcript of the run that answered"
github; a_request_answered
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_status 0
expect_fact .ask.comment "@claude start #12, which has waited since Monday"
expect_fact .ask.url "$ask"
expect_fact .workflow claude
expect_fact .url "https://github.example/runs/900"
expect_fact .issue 12
expect_fact .pr null
expect_fact '.agents | length' 1
expect_fact '.agents[0].role' claude
expect_fact .cost_usd 0.42
[ -f "$T/sessions/$(jq -r '.agents[0].file' <<<"$out")" ] || fail "expected the transcript to be where the facts list it"
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"

scenario "a request for help in a review comment: read as a pull request's comment, with that pull request and its ticket"
github; a_request_answered
echo '{"id":8,"body":"@claude why is this red?","html_url":"https://github.example/owner/myapp/pull/72#discussion_r8"}' > "$T/comment"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "https://github.example/owner/myapp/pull/72#discussion_r8" "$T/sessions"
expect_status 0
expect_call "gh api repos/{owner}/{repo}/pulls/comments/8 --jq"
expect_fact .ask.comment "@claude why is this red?"
expect_fact .pr 72
expect_fact .issue 57
expect_fact '.agents[0].file | startswith("pr-72/")' true

scenario "a request for help: what is no link to a comment is refused before GitHub is asked"
github; a_request_answered
for link in "https://github.example/owner/myapp/issues/12" "issues/12#issuecomment-5" "$ask"$'\n'"go=true" "go=true"$'\n'"$ask" "https://github.example/owner/myapp/commit/abc#issuecomment-5"; do
  run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$link" "$T/sessions"
  expect_failure
  expect_output "is not the link to a comment on a ticket or a pull request, so the request for help was not read."
done
expect_no_call "gh"

scenario "a request for help: stops with a message, and leaves nothing, when the comment, the run or the transcript cannot be read"
github; a_request_answered
left() { find "$T/sessions" "$T/work" "$T/tmp" -mindepth 1 ! -path "$T/sessions/lessons"; }
echo "api repos/{owner}/{repo}/issues/comments/5" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_failure
expect_output "Could not read the comment $ask from GitHub, so the request for help is not known."
expect_no_call "run download"
echo "api repos/{owner}/{repo}/actions/runs/900 --jq" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_failure
expect_output "Could not read workflow run 900 from GitHub, so its transcript was not found."
expect_no_call "run download"
echo "run download" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_failure
expect_output "Could not download the transcript of workflow run 900, so the facts of the request for help are not known."
expect_no_output '"ask"'
[ -z "$(left)" ] || fail "expected nothing left behind, found: $(left)"

scenario "a request for help: stops with a message when the run kept no transcript"
github; a_request_answered
rm "$T/artifact.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_failure
expect_output "The artifact of workflow run 900 holds no transcript, so the facts of the request for help are not known."
expect_no_output '"ask"'

scenario "a request for help: stops with the run's own message, and takes the transcript back, when the run's jobs cannot be read"
github; a_request_answered
echo "api repos/{owner}/{repo}/actions/runs/900/jobs" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --ask 900 "$ask" "$T/sessions"
expect_failure
expect_output "Could not read the jobs of workflow run 900 from GitHub, so what failed is not known."
expect_no_output '"ask"'
[ -z "$(find "$T/sessions" -name '*-run900.json')" ] || fail "expected the copied transcript to be taken back"

# Ticket #574, a defect the owner met in use, which pull request #577 closed.
a_defect() {
  echo '{"url":"https://github.example/owner/myapp/issues/574","state":"CLOSED","labels":[{"name":"bug"}],"closedByPullRequestsReferences":[{"number":577}]}' > "$T/ticket"
}
a_lesson() { echo "$2" > "$T/sessions/lessons/$1"; }

scenario "a defect met in use: the ticket, the pull requests that closed it, and no earlier lesson"
github; a_defect
a_lesson 20261120T080000Z-lesson-run800.json '{"pr":null,"issue":574,"facts":{"run":800,"workflow":"implement"},"lesson":{}}'
a_lesson 20261120T090000Z-lesson-run801.json '{"pr":null,"issue":12,"facts":{"defect":{"title":"Another"}},"lesson":{}}'
: > "$T/sessions/lessons/20261120T100000Z-lesson-run802.json"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --defect 574 "$T/sessions"
expect_status 0
expect_fact .issue 574
expect_fact .pr null
expect_fact '.defect | keys | join(" ")' "labels state url"
expect_fact .defect.url "https://github.example/owner/myapp/issues/574"
expect_fact .defect.state CLOSED
expect_fact '.defect.labels | join(" ")' bug
expect_fact '.fixed_by | join(" ")' 577
expect_fact .earlier_lesson null

scenario "a defect met in use that a retro has looked at: names the lesson it saved"
github; a_defect
a_lesson 20261121T080000Z-lesson-run850.json '{"pr":null,"issue":574,"facts":{"issue":574,"defect":{"title":"Let a runner keep more than one race"}},"lesson":{}}'
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --defect 574 "$T/sessions"
expect_status 0
expect_fact .earlier_lesson 20261121T080000Z-lesson-run850.json

scenario "a defect met in use with no pull request yet: none is listed"
github; a_defect
jq -c '.state = "OPEN" | .closedByPullRequestsReferences = []' "$T/ticket" > "$T/open" && mv "$T/open" "$T/ticket"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --defect 574 "$T/sessions"
expect_status 0
expect_fact '.fixed_by | length' 0
expect_fact .defect.state OPEN

scenario "a defect met in use: stops with a message, and prints no facts, when the ticket cannot be read"
github; a_defect
echo "issue view 574" > "$T/fail"
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --defect 574 "$T/sessions"
expect_failure
expect_output "Could not read ticket #574 from GitHub, so the facts of the defect are not known."
expect_no_output '"defect"'

scenario "a defect met in use: what is no ticket's number is refused before GitHub is asked"
github; a_defect
for number in "574; go=true" "#574" "five"; do
  run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --defect "$number" "$T/sessions"
  expect_failure
  expect_output "is not the number of a ticket, so the defect was not read."
done
expect_no_call "gh"

scenario "leaves nothing behind"
github; a_build_cut_short
run env GH_TOKEN=workflow-token "$scripts/run-facts.sh" --run 900 "$T/sessions"
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"

# A rename in the workflows must fail here, or a refused ticket would start a paid retro and a failed merge none.
scenario "the step and jobs it knows by name are still called that in the workflows"
name="Validate the ticket against its template"
grep -qF -- "- name: $name" "$root/factory/workflows/implement.yml" || fail "implement.yml has no step named: $name"
for job in merge start-fix; do
  grep -qx "  $job:" "$root/factory/workflows/ci.yml" || fail "ci.yml has no job named: $job"
done
