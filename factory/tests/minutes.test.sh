#!/usr/bin/env bash
# Tests for minutes.sh, which prints a period's billed Actions minutes by workflow, by job and by ticket.
. "$(dirname "$0")/helpers.sh"

# github: answers from $T/runs (or $T/runs-<period> when there is one), $T/jobs-<run>, $T/tree and $T/pulls.
# A call that starts with a line of $T/fail fails; one that starts with a line of $T/fail-once fails the first time.
github() {
  : > "$T/fail"; : > "$T/fail-once"
  echo '{"total_count": 0, "workflow_runs": []}' > "$T/runs"
  echo '{"truncated": false, "tree": []}' > "$T/tree"
  echo '[]' > "$T/pulls"
  stub sleep 'exit 0'
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    while IFS= read -r words; do
      case "$*" in "$words"*) : > "$T/fail-once"; echo "gh: failed once: $*" >&2; exit 1 ;; esac
    done < "$T/fail-once"
    case "$*" in
      "api --method GET repos/{owner}/{repo}/actions/runs -f created="*" -f per_page=100 --paginate --jq "*)
        file="$T/runs-${6#created=}"
        [ -e "$file" ] || file="$T/runs"
        json "$(cat "$file")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs/"*"/jobs -f filter=all -f per_page=100 --paginate --jq "*)
        run=${4#*/runs/}
        json "$(cat "$T/jobs-${run%/jobs}")" "$@" ;;
      "api repos/{owner}/{repo}/git/trees/sessions?recursive=1 --jq "*) json "$(cat "$T/tree")" "$@" ;;
      "api repos/{owner}/{repo}/pulls?state=all&per_page=100 --paginate --jq "*) json "$(cat "$T/pulls")" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# a_run <id> <workflow> <branch> <conclusion> [attempt]: one more run in $T/runs.
a_run() {
  jq -c --argjson id "$1" --arg name "$2" --arg branch "$3" --arg conclusion "$4" --argjson attempt "${5:-1}" '
    .workflow_runs += [{id: $id, name: $name, head_branch: $branch, conclusion: $conclusion, run_attempt: $attempt}]
    | .total_count = (.workflow_runs | length)' "$T/runs" > "$T/runs.new"
  mv "$T/runs.new" "$T/runs"
  [ -e "$T/jobs-$1" ] || echo '{"jobs": []}' > "$T/jobs-$1"
}
# a_job <run> <name> <started at> <completed at, or ""> [conclusion] [runner group]: one more job of that run.
a_job() {
  jq -c --argjson run "$1" --arg name "$2" --arg from "$3" --arg to "$4" --arg conclusion "${5:-success}" --arg group "${6-GitHub Actions}" '
    .jobs += [{run_id: $run, name: $name, started_at: $from, completed_at: (if $to == "" then null else $to end),
               conclusion: (if $to == "" then null else $conclusion end), runner_group_name: $group}]' "$T/jobs-$1" > "$T/jobs.new"
  mv "$T/jobs.new" "$T/jobs-$1"
}
a_transcript() { jq -c --arg path "$1" '.tree += [{path: $path, type: "blob"}]' "$T/tree" > "$T/tree.new"; mv "$T/tree.new" "$T/tree"; }
a_pull() { jq -c --argjson n "$1" --arg ref "$2" '. += [{number: $n, head: {ref: $ref}}]' "$T/pulls" > "$T/pulls.new"; mv "$T/pulls.new" "$T/pulls"; }
# a_ticket: ticket #12's build, its pull request's checks and a fix round, 16 billed minutes in three runs.
a_ticket() {
  a_run 1 implement main success
  a_job 1 implement 2026-11-17T09:00:00Z 2026-11-17T09:10:00Z
  a_transcript "issue-12/20261117T091000Z-fred-run1.json"
  a_run 2 ci feat/12-export-forecast-csv failure
  a_job 2 checks 2026-11-17T09:11:00Z 2026-11-17T09:12:01Z
  a_job 2 review 2026-11-17T09:11:00Z 2026-11-17T09:11:30Z failure
  a_job 2 fits-main 2026-11-17T09:11:00Z 2026-11-17T09:12:01Z skipped
  a_run 3 fix main success
  a_job 3 fix 2026-11-17T09:20:00Z 2026-11-17T09:22:30.000Z
  a_transcript "pr-20/20261117T092230Z-fred-fix-run3.json"
  a_pull 20 feat/12-export-forecast-csv
}
november() { run "$scripts/minutes.sh" 2026-11-01 2026-11-18; }
expect_line() { grep -qxF -- "$1" <<<"$out" || fail "expected the line: $1"; }
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder, found: $(ls -A "$T/tmp")"
  [ -z "$(ls -A "$T/work")" ] || fail "expected nothing left in the working folder"
}

scenario "prints the minutes by workflow, by job and by ticket, each job rounded up to a whole minute"
github; a_ticket
a_run 4 install-workflows main success
a_job 4 install 2026-11-17T09:30:00Z 2026-11-17T09:30:10Z
november
expect_status 0
expect_line "Actions minutes billed for the runs created from 2026-11-01 to 2026-11-18 (UTC): 17, in 4 runs."
expect_line "| Workflow | Minutes | Runs |"
expect_line "| implement | 10 | 1 |"
expect_line "| ci | 3 | 1 |"
expect_line "| fix | 3 | 1 |"
expect_line "| install-workflows | 1 | 1 |"
expect_line "| Workflow | Job | Minutes | Jobs | Minutes it ran |"
expect_line "| implement | implement | 10 | 1 | 10 |"
expect_line "| ci | checks | 2 | 1 | 1 |"
expect_line "| ci | review | 1 | 1 | 1 |"
expect_line "| fix | fix | 3 | 1 | 3 |"
expect_no_output "fits-main"
expect_line "| Ticket | Minutes | Runs |"
expect_call "-f created=2026-11-01T00:00:00Z..2026-11-18T23:59:59Z"
expect_nothing_left

scenario "the largest spend comes first in each table"
github; a_ticket
a_run 4 install-workflows main success
a_job 4 install 2026-11-17T09:30:00Z 2026-11-17T09:30:10Z
november
[ "$(grep -E '^\| (implement|ci|fix|install-workflows) \| [0-9]+ \| [0-9]+ \|$' <<<"$out" | cut -d ' ' -f 2 | tr '\n' ' ')" = "implement ci fix install-workflows " ] \
  || fail "expected the workflows in the order implement, ci, fix, install-workflows"
[ "$(grep -E '^\| (#|No ticket)' <<<"$out" | head -n 1)" = "| #12 | 16 | 3 |" ] || fail "expected ticket #12 first"

scenario "a run for a pull request's branch is its ticket's, and so is a build or fix round whose transcript names it"
github; a_ticket
november
expect_line "| #12 | 16 | 3 |"
expect_no_output "No ticket"

scenario "a run that names no ticket is counted under \"No ticket\""
github
a_run 4 install-workflows main success
a_job 4 install 2026-11-17T09:30:00Z 2026-11-17T09:30:10Z
a_run 5 fix main success
a_job 5 fix 2026-11-17T09:40:00Z 2026-11-17T09:44:00Z
a_transcript "pr-30/20261117T094400Z-fred-fix-run5.json"
a_pull 30 tidy-up
a_run 6 retro main success
a_job 6 retro 2026-11-17T09:50:00Z 2026-11-17T09:52:00Z
a_transcript "lessons/20261117T095200Z-lesson-run6.json"
november
expect_line "| No ticket | 7 | 3 |"
expect_no_output "| #"

scenario "a job run in two attempts is billed for both"
github
a_run 2 ci feat/12-export-forecast-csv success 2
a_job 2 fits-main 2026-11-17T09:11:00Z 2026-11-17T09:13:00Z failure
a_job 2 fits-main 2026-11-17T09:30:00Z 2026-11-17T09:32:30Z
november
expect_line "| ci | fits-main | 5 | 2 | 5 |"
expect_line "| ci | 5 | 1 |"

scenario "a run skipped in its only attempt has no job read"
github; a_ticket
a_run 7 retro main skipped
november
expect_status 0
expect_no_call "actions/runs/7/jobs"
expect_no_output "retro"

scenario "a skipped run that was run again has its jobs read"
github
a_run 7 ci feat/12-export-forecast-csv skipped 2
a_job 7 checks 2026-11-17T09:11:00Z 2026-11-17T09:12:00Z
november
expect_call "actions/runs/7/jobs"
expect_line "| ci | checks | 1 | 1 | 1 |"

scenario "a job still running is counted to now"
github
a_run 1 implement main ""
a_job 1 implement "$(jq -rn 'now - 90 | todate')" ""
november
expect_line "| implement | implement | 2 | 1 | 2 |"

scenario "a job that was cancelled before it began is billed nothing"
github; a_ticket
a_run 8 implement main cancelled
a_job 8 implement 2026-11-17T10:00:00Z 2026-11-17T10:00:00Z cancelled
november
expect_line "| implement | 10 | 1 |"

scenario "a job on a runner the owner keeps is billed nothing, and the time it ran is shown"
github; a_ticket
a_run 9 retro main success
a_job 9 retro 2026-11-17T10:00:00Z 2026-11-17T10:03:10Z success Default
a_run 10 implement main success
a_job 10 implement 2026-11-17T11:00:00Z 2026-11-17T11:05:00Z success Default
november
expect_line "Actions minutes billed for the runs created from 2026-11-01 to 2026-11-18 (UTC): 16, in 5 runs."
expect_line "| implement | 10 | 2 |"
expect_line "| retro | 0 | 1 |"
expect_line "| retro | retro | 0 | 1 | 3 |"
expect_line "| implement | implement | 10 | 2 | 15 |"

scenario "a job cancelled while it waited for a runner none took is billed nothing, however long it waited"
github; a_ticket
a_run 11 retro main cancelled
a_job 11 retro 2026-11-17T10:00:00Z 2026-11-18T10:00:00Z cancelled ""
november
expect_line "Actions minutes billed for the runs created from 2026-11-01 to 2026-11-18 (UTC): 16, in 3 runs."
expect_no_output "retro"

scenario "a period GitHub cuts short is read in halves"
github; a_ticket
# GitHub counts three runs in the two days and lists two of them.
jq -c '.workflow_runs |= .[:2]' "$T/runs" > "$T/runs-2026-11-16T00:00:00Z..2026-11-17T23:59:59Z"
echo '{"total_count": 0, "workflow_runs": []}' > "$T/runs-2026-11-16T00:00:00Z..2026-11-16T23:59:59Z"
cp "$T/runs" "$T/runs-2026-11-17T00:00:00Z..2026-11-17T23:59:59Z"
run "$scripts/minutes.sh" 2026-11-16 2026-11-17
expect_status 0
expect_call "-f created=2026-11-16T00:00:00Z..2026-11-16T23:59:59Z"
expect_call "-f created=2026-11-17T00:00:00Z..2026-11-17T23:59:59Z"
expect_line "| #12 | 16 | 3 |"

scenario "a single second GitHub still cuts short stops it"
github; a_ticket
jq -c '.workflow_runs |= .[:2]' "$T/runs" > "$T/runs.new"; mv "$T/runs.new" "$T/runs"
run "$scripts/minutes.sh" 2026-11-17 2026-11-17
expect_status 1
expect_output "GitHub lists fewer runs than it counts in 2026-11-17T00:00:00Z..2026-11-17T00:00:00Z, so the minutes they were billed are not known."
expect_no_output "| Workflow |"

scenario "a period with no billed run says so"
github
a_run 7 retro main skipped
november
expect_status 0
expect_line "No run created from 2026-11-01 to 2026-11-18 (UTC) was billed a minute."

scenario "a read that fails once is asked again"
github; a_ticket
echo "api --method GET repos/{owner}/{repo}/actions/runs/2/jobs" > "$T/fail-once"
november
expect_status 0
expect_line "| #12 | 16 | 3 |"

scenario "a list of runs that cannot be read stops it"
github; a_ticket
echo "api --method GET repos/{owner}/{repo}/actions/runs -f created=" > "$T/fail"
november
expect_status 1
expect_output "Could not list the workflow runs created in 2026-11-01T00:00:00Z..2026-11-18T23:59:59Z, so the minutes they were billed are not known."
expect_no_output "| Workflow |"
expect_nothing_left

scenario "one run's jobs that cannot be read stop it"
github; a_ticket
echo "api --method GET repos/{owner}/{repo}/actions/runs/3/jobs" > "$T/fail"
november
expect_status 1
expect_output "Could not read the jobs of every workflow run, so the minutes they were billed are not known."
expect_no_output "| Workflow |"
expect_nothing_left

scenario "a sessions branch that cannot be listed stops it"
github; a_ticket
echo "api repos/{owner}/{repo}/git/trees/sessions" > "$T/fail"
november
expect_status 1
expect_output "Could not list the transcripts on the sessions branch, so which ticket a build or fix round ran for is not known."
expect_no_output "| Workflow |"

scenario "a list of transcripts GitHub cut short stops it"
github; a_ticket
jq -c '.truncated = true' "$T/tree" > "$T/tree.new"; mv "$T/tree.new" "$T/tree"
november
expect_status 1
expect_output "Could not list the transcripts on the sessions branch"
expect_no_output "| Workflow |"

scenario "a list of pull requests that cannot be read stops it"
github; a_ticket
echo "api repos/{owner}/{repo}/pulls" > "$T/fail"
november
expect_status 1
expect_output "Could not list the pull requests, so which ticket a review or fix round ran for is not known."
expect_no_output "| Workflow |"

scenario "a date that is no date, or a period that ends before it starts, is refused before anything is read"
github
run "$scripts/minutes.sh" 2026-11-01
expect_status 1
expect_output "Usage: minutes.sh <from> <to>"
run "$scripts/minutes.sh" 2026-11-01 18-11-2026
expect_status 1
expect_output "Usage: minutes.sh <from> <to>"
run "$scripts/minutes.sh" 2026-11-18 2026-11-01
expect_status 1
expect_output "2026-11-18 is after 2026-11-01, so there is no period to read."
[ ! -s "$T/calls" ] || fail "expected no outside call"
