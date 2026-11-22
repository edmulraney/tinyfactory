#!/usr/bin/env bash
# Tests for rerun-refused.sh: the runs GitHub refused to start for billing are run again (decisions H220a to H220f).
. "$(dirname "$0")/helpers.sh"

refusal="The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"

# $T/runs holds the runs newest first, as GitHub lists them; $T/jobs-<run> and $T/annotations-<job> answer for each.
github() {
  : > "$T/fail"; : > "$T/runs"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api --method GET repos/{owner}/{repo}/actions/runs -f created=>="*" -f per_page=100 --jq "*)
        since=${6#created=>=}
        json "$(jq -s --arg since "$since" "{workflow_runs: map(select(.created_at >= \$since))}" "$T/runs")" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/"*"/attempts/1/jobs?per_page=100 --paginate --jq "*)
        id=${2#*/runs/}; id=${id%/attempts*}; json "{\"jobs\":$(cat "$T/jobs-$id")}" "$@" ;;
      "api repos/{owner}/{repo}/check-runs/"*"/annotations?per_page=100 --jq "*)
        id=${2#*/check-runs/}; id=${id%/annotations*}
        annotations=$(jq -Rs "[{annotation_level: \"failure\", message: .}]" "$T/annotations-$id")
        json "$annotations" "$@" ;;
      "run rerun "*) : ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# a_run <id> <workflow> <conclusion> [attempt]: one run older than those already there, created $ago (1) hours ago.
# A conclusion of "null" is a run still in progress.
a_run() {
  jq -cn --argjson id "$1" --arg name "$2" --arg conclusion "$3" --argjson attempt "${4:-1}" \
    --argjson ago "${ago:-1}" \
    '{id: $id, name: $name, display_title: "the title of \($id)", created_at: (now - $ago * 3600 | todate), run_attempt: $attempt,
      conclusion: (if $conclusion == "null" then null else $conclusion end)}' >> "$T/runs"
}
# refused <id> <workflow> [attempt]: in its first attempt, its first job (<id>1) never began and says why; the job after it was skipped.
refused() {
  a_run "$1" "$2" failure "${3:-1}"
  echo "[{\"id\":${1}1,\"conclusion\":\"failure\",\"steps\":[]},{\"id\":${1}2,\"conclusion\":\"skipped\",\"steps\":[]}]" > "$T/jobs-$1"
  printf '%s' "$refusal" > "$T/annotations-${1}1"
}
# failed_in_a_step <id> <workflow> [attempt]: in its first attempt.
failed_in_a_step() {
  a_run "$1" "$2" failure "${3:-1}"
  echo "[{\"id\":${1}1,\"conclusion\":\"failure\",\"steps\":[{\"name\":\"Set up job\",\"conclusion\":\"success\"},{\"name\":\"Run pnpm lint\",\"conclusion\":\"failure\"}]}]" > "$T/jobs-$1"
  printf 'Process completed with exit code 1.' > "$T/annotations-${1}1"
}
# refused_in_part <id> <workflow>: its first job (<id>1) ran and passed; its second (<id>2) never began and says why.
refused_in_part() {
  a_run "$1" "$2" failure
  echo "[{\"id\":${1}1,\"conclusion\":\"success\",\"steps\":[{\"name\":\"Set up job\",\"conclusion\":\"success\"}]},{\"id\":${1}2,\"conclusion\":\"failure\",\"steps\":[]}]" > "$T/jobs-$1"
  printf '%s' "$refusal" > "$T/annotations-${1}2"
}
reruns() { grep '^gh run rerun' "$T/calls" | sed 's/ --failed$//' | tr '\n' ';'; }

scenario "runs each refused run again, oldest first, and no run that started"
github
a_run 507 ci success
failed_in_a_step 506 ci
refused 505 retro
refused 504 approve-merge
refused 503 implement
a_run 502 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 503;gh run rerun 504;gh run rerun 505;" ] || fail "expected runs 503, 504 and 505 run again in that order, got: $(reruns)"
expect_output "running again: 503 implement: the title of 503"
expect_output "running again: 505 retro: the title of 505"

expect_call "gh run rerun 503 --failed"

scenario "runs again a run with one job that started and one refused, and searches on past it"
github
refused 506 retro
refused_in_part 505 ci
refused 504 approve-merge
a_run 503 ci success
refused 502 implement
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 504;gh run rerun 505;gh run rerun 506;" ] || fail "expected runs 504, 505 and 506 run again, got: $(reruns)"
expect_call "gh run rerun 505 --failed"

scenario "leaves an earlier outage when its runs are all that is refused"
github
a_run 507 ci success
ago=48 refused 506 retro
ago=48 a_run 505 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
expect_no_call "gh run rerun"
expect_output "nothing to run again"

scenario "ends the search at this outage when every run of it is being run again"
github
a_run 507 ci success
refused 506 retro 2
refused 505 approve-merge 2
sed -i.bak 's/"run_attempt":2,"conclusion":"failure"/"run_attempt":2,"conclusion":null/' "$T/runs" && rm "$T/runs.bak"
a_run 504 ci success
refused 503 implement
run "$scripts/rerun-refused.sh"
expect_status 0
expect_no_call "gh run rerun"
expect_output "nothing to run again"

scenario "leaves a run that failed in a step"
github
failed_in_a_step 506 ci
a_run 502 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
expect_no_call "gh run rerun"
expect_output "nothing to run again"
expect_no_call "check-runs"

scenario "leaves a run already run again, and runs again the others refused with it"
github
refused 505 retro
refused 504 approve-merge 2
refused 503 implement
a_run 502 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 503;gh run rerun 505;" ] || fail "expected only runs 503 and 505 run again, got: $(reruns)"

scenario "called twice, leaves the runs of an earlier outage at the second call"
github
a_run 507 ci success
refused 506 retro
refused 505 approve-merge
a_run 504 ci success
refused 503 implement
run "$scripts/rerun-refused.sh"
[ "$(reruns)" = "gh run rerun 505;gh run rerun 506;" ] || fail "expected runs 505 and 506 run again at the first call, got: $(reruns)"
: > "$T/runs"; : > "$T/calls"
a_run 507 ci success
refused 506 retro 2
refused 505 approve-merge 2
a_run 504 ci success
refused 503 implement
run "$scripts/rerun-refused.sh"
expect_status 0
expect_no_call "gh run rerun"
expect_output "nothing to run again"

scenario "does not end the search at a run whose first attempt started after the refusals"
github
failed_in_a_step 506 ci 2
refused 505 retro
a_run 504 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 505;" ] || fail "expected run 505 run again, got: $(reruns)"

scenario "ends the search at a run already run again whose first attempt started ahead of these refusals"
github
refused 505 retro
failed_in_a_step 504 ci 2
refused 503 implement
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 505;" ] || fail "expected only run 505 run again, got: $(reruns)"

scenario "leaves a run refused before the last run that started ahead of these refusals"
github
refused 505 retro
a_run 504 ci success
refused 503 implement
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 505;" ] || fail "expected only run 505 run again, got: $(reruns)"
expect_no_call "runs/503/attempts"

scenario "ends the search at a run that failed in a step ahead of these refusals"
github
refused 505 retro
failed_in_a_step 504 ci
refused 503 implement
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 505;" ] || fail "expected only run 505 run again, got: $(reruns)"

scenario "leaves a run whose jobs never started for another reason"
github
refused 505 retro
printf 'The job was not acquired by a runner.' > "$T/annotations-5051"
a_run 504 ci cancelled
a_run 503 ci failure
echo '[]' > "$T/jobs-503"
run "$scripts/rerun-refused.sh"
expect_status 0
expect_no_call "gh run rerun"
expect_output "nothing to run again"

scenario "leaves a refused run of flag-idle, the look that calls this, and runs again those refused with it"
github
refused 505 flag-idle
refused 504 approve-merge
a_run 503 ci success
run "$scripts/rerun-refused.sh"
expect_status 0
[ "$(reruns)" = "gh run rerun 504;" ] || fail "expected only run 504 run again, got: $(reruns)"

scenario "says so when there is no run at all"
github
run "$scripts/rerun-refused.sh"
expect_status 0
expect_output "nothing to run again"
expect_no_call "gh run rerun"

for words in "api --method GET repos/{owner}/{repo}/actions/runs" "api repos/{owner}/{repo}/actions/runs/504/attempts/1/jobs" "api repos/{owner}/{repo}/check-runs/5041/annotations"; do
  scenario "stops with a message, and runs nothing again, when this fails: gh $words"
  github
  refused 505 retro
  refused 504 approve-merge
  echo "$words" > "$T/fail"
  run "$scripts/rerun-refused.sh"
  expect_status 1
  expect_output "so nothing was run again"
  expect_no_output "nothing to run again"
  expect_no_call "gh run rerun"
done

scenario "says which run GitHub did not run again, runs the others, and fails"
github
refused 505 retro
refused 504 approve-merge
echo "run rerun 504" > "$T/fail"
run "$scripts/rerun-refused.sh"
expect_status 1
expect_output "Run 504 (approve-merge: the title of 504) was refused for billing, and GitHub did not run it again."
expect_output "running again: 505 retro: the title of 505"
expect_no_output "running again: 504"
