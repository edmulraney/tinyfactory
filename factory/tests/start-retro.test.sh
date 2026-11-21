#!/usr/bin/env bash
# Tests for the step with which a failed job of a factory workflow starts the retro of its own run (decisions A20).
. "$(dirname "$0")/helpers.sh"

workflows="$root/factory/workflows"
name="Start a retro when this job failed"

jobs_of() { sed -n '/^jobs:$/,$p' "$workflows/$1.yml" | sed -n 's/^  \([a-z0-9-]*\):$/\1/p'; }
job() { awk -v job="  $2:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflows/$1.yml"; }
# step <workflow> <job> [name]: the step's lines, read from the source, so a change there fails here.
step() { job "$1" "$2" | awk -v first="      - name: ${3:-$name}" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$1" | sed '1d; s/^          //'; }

fails() {
  run env GH_TOKEN=workflow-token GH_REPO=owner/myapp GITHUB_RUN_ID=900 bash -c "$(commands "$(step "$1" "$2")")"
}
asked() { grep -c '^gh workflow run retro.yml -f run=900$' "$T/calls"; }

# Every job of the four, the two of `ci` whose failure is the factory's own, and the two of `merge-group` that hold
# a token: its `test` job runs the pull requests' code with none (decisions M455i).
each_job() {
  local workflow job
  for workflow in implement approve-merge install-workflows fix; do
    # test-main may only read, and the ship job that waits for it fails in its place (decisions M439i).
    for job in $(jobs_of "$workflow"); do [ "$workflow $job" = "approve-merge test-main" ] || echo "$workflow $job"; done
  done
  echo "ci merge"
  echo "ci start-fix"
  echo "merge-group begin"
  echo "merge-group merge"
}

while read -r workflow job; do
  scenario "a failed $job job of $workflow starts one retro, of its own run"
  found=$(step "$workflow" "$job")
  [ "$(grep -cF -- "- name: $name" <<<"$found")" = 1 ] || fail "expected the job to hold the step once"
  case "$workflow" in
    ci) condition="failure()" ;;
    # A job an outsider's event can start asks no retro for a run an account that is not trusted started (decisions W563c).
    implement | approve-merge | install-workflows)
      condition="steps.trusted.outcome != 'failure' && (failure() || (cancelled() && steps.limit.outputs.reached == 'true'))" ;;
    *) condition="failure() || (cancelled() && steps.limit.outputs.reached == 'true')" ;;
  esac
  grep -qxF "        if: $condition" <<<"$found" || fail "expected the step to run only when the job failed or stopped at its time limit"
  # shellcheck disable=SC2016
  grep -qxF '          GH_TOKEN: ${{ github.token }}' <<<"$found" || fail "expected the step to ask with the workflow's own token"
  job "$workflow" "$job" | sed -n '/^    permissions:$/,/^    steps:$/p' | grep -qE '^      actions: write( |$)' \
    || fail "expected the job to hold actions: write, which starts a workflow"
  stub gh 'case "$*" in "workflow run retro.yml -f run=900") ;; *) exit 1 ;; esac'
  stub sleep ':'
  fails "$workflow" "$job"
  expect_status 0
  [ "$(asked)" = 1 ] || fail "expected the retro to be asked for once, got $(asked)"
  expect_no_call "sleep"

  scenario "the $job job of $workflow asks again when GitHub does not start the retro, and stops at three"
  stub gh '[ -e "$T/up" ] || { touch "$T/up"; exit 1; }'
  stub sleep ':'
  fails "$workflow" "$job"
  expect_status 0
  [ "$(asked)" = 2 ] || fail "expected the retro to be asked for twice, got $(asked)"
  : > "$T/calls"
  stub gh 'echo "could not create workflow dispatch event" >&2; exit 1'
  fails "$workflow" "$job"
  expect_failure
  expect_output "could not create workflow dispatch event"
  [ "$(asked)" = 3 ] || fail "expected the retro to be asked for three times, got $(asked)"
done < <(each_job)

# stopped <workflow> <job> <minutes>: runs the time-limit step as that job would, cancelled so many minutes after it started; needs \$limit.
stopped() {
  local found; found=$(step "$1" "$2" "Tell whether this job stopped at its time limit")
  STARTED=$(date -u -d "$(( $3 * 60 + 5 )) seconds ago" +%Y-%m-%dT%H:%M:%SZ)
  export STARTED
  : > "$T/output"
  run env GH_TOKEN=workflow-token GH_REPO=owner/myapp GITHUB_RUN_ID=900 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB="$2" \
    GITHUB_OUTPUT="$T/output" LIMIT_MINUTES="$limit" bash -c "$(commands "$found")"
}
# GitHub's answer holds another job too, so that the step must pick its own.
jobs_answer='case "$*" in
  "api repos/owner/myapp/actions/runs/900/attempts/2/jobs --jq "*)
    jq -n --arg job "$GITHUB_JOB" --arg at "$STARTED" "{jobs: [{name: \"other\", started_at: \"2020-01-01T00:00:00Z\"}, {name: \$job, started_at: \$at}]}" \
      | jq -r "${*: -1}" ;;
  *) exit 1 ;;
esac'

while read -r workflow job; do
  scenario "the $job job of $workflow, cancelled at its time limit, starts its retro; cancelled before it, none"
  found=$(step "$workflow" "$job" "Tell whether this job stopped at its time limit")
  grep -qx '        if: cancelled()' <<<"$found" || fail "expected the step to run only when the job was cancelled"
  grep -qx '        id: limit' <<<"$found" || fail "expected the step to be the one the retro's step reads"
  limit=$(sed -n 's/^          LIMIT_MINUTES: \([0-9]*\) .*/\1/p' <<<"$found")
  job "$workflow" "$job" | grep -qx "    timeout-minutes: $limit" \
    || fail "expected the step's limit to be the job's timeout-minutes"
  job "$workflow" "$job" | grep -E '^      - name: (Tell whether|Start a retro)' | head -n 1 | grep -q 'Tell whether' \
    || fail "expected the step to come before the one that starts the retro"
  stub gh "$jobs_answer"
  stopped "$workflow" "$job" "$limit"
  expect_status 0
  grep -qx 'reached=true' "$T/output" || fail "expected a job cancelled at its limit to be told as stopped at it"
  stopped "$workflow" "$job" "$((limit - 2))"
  expect_status 0
  [ ! -s "$T/output" ] || fail "expected a job cancelled before its limit to start no retro"

  scenario "the $job job of $workflow stops with a message when GitHub does not say when it started"
  stub gh 'exit 1'
  stopped "$workflow" "$job" "$limit"
  expect_failure
  expect_output "Could not read from GitHub when this job started"
  [ ! -s "$T/output" ] || fail "expected nothing to be told about the limit"
  stub gh ':'
  stopped "$workflow" "$job" "$limit"
  expect_failure
  expect_output "Could not read from GitHub when this job started"
done < <(each_job | grep -v '^ci ')

scenario "no failed run starts two retros: the retro starts on no other workflow's end"
! grep -q 'workflow_run' "$workflows/retro.yml" || fail "expected retro.yml not to start when another workflow ends"
# A label on a ticket names no run, so it adds no retro of one (decisions A574a).
[ "$(sed -n '/^on:$/,/^[a-z]/p' "$workflows/retro.yml" | grep -oE '^  [a-z_]+:' | sort | tr -d ' \n')" = "issues:workflow_dispatch:" ] \
  || fail "expected retro.yml to start when a job asks for it or a ticket is labelled, and in no other way"
grep -qx '  workflow_dispatch:' "$workflows/retro.yml" || fail "expected retro.yml to start when a job asks for it"

scenario "a failed retro starts no retro"
[ "$(jobs_of retro)" = retro ] || fail "expected retro.yml to hold the retro job alone"
[ -z "$(step retro retro)" ] || fail "expected the retro job not to start a retro"
! grep -q 'workflow run retro.yml' "$workflows/retro.yml" || fail "expected retro.yml not to start itself"

scenario "the probe of the time limit runs the two steps as the factory's jobs hold them"
[ "$(commands "$(step probe-time-limit probe "Tell whether this job stopped at its time limit")")" \
  = "$(commands "$(step implement implement "Tell whether this job stopped at its time limit")")" ] \
  || fail "expected the probe to read the job's start with the commands the implement job runs"
# shellcheck disable=SC2016
for field in "        id: limit" "        if: cancelled()" '          GH_TOKEN: ${{ github.token }}' '          GH_REPO: ${{ github.repository }}'; do
  step probe-time-limit probe "Tell whether this job stopped at its time limit" | grep -qxF -- "$field" \
    || fail "expected the probe's time-limit step to hold: $field"
done
grep -qxF "        if: failure() || (cancelled() && steps.limit.outputs.reached == 'true')" <<<"$(step probe-time-limit probe)" \
  || fail "expected the probe's last-but-one step to run on the condition that starts a retro"
limit=$(step probe-time-limit probe "Tell whether this job stopped at its time limit" | sed -n 's/^          LIMIT_MINUTES: \([0-9]*\) .*/\1/p')
job probe-time-limit probe | grep -qx "    timeout-minutes: $limit" || fail "expected the probe's step to hold the job's timeout-minutes"

scenario "the probe starts no retro and no other workflow"
! grep -q 'gh workflow run' "$workflows/probe-time-limit.yml" || fail "expected the probe to start nothing"
