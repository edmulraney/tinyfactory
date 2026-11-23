#!/usr/bin/env bash
# Tests for ci.yml's and flag-idle.yml's steps that delete preview database branches (decisions M672a, M672b).
. "$(dirname "$0")/helpers.sh"

# job <workflow> <job>: the job's lines; step <workflow> <job> <name>: the step's; commands: what it runs.
job() { awk -v job="  $2:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/$1"; }
step() { job "$1" "$2" | awk -v first="      - name: $3" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$1" | sed -e 1d -e 's/^          //'; }
after_e2e="Delete this preview's database branch once its end-to-end tests have run"
scheduled="Delete the preview database branches of pull requests that are closed"
api=https://console.neon.tech/api/v2/projects/proj/branches
deleted() { echo "curl -fsS -X DELETE -H Authorization: Bearer key $api/$1"; }

# A call holding the text in $T/broken fails, in either stand-in.
broken() { printf '%s' "$1" > "$T/broken"; }
fails='[ ! -s "$T/broken" ] || [[ "$*" != *"$(cat "$T/broken")"* ]] || exit 1'
# neon: production, this pull request's preview, a closed pull request's, and another open one's.
neon() {
  echo '{"branches":[{"id":"br-production","name":"main","default":true},{"id":"br-preview","name":"preview/feat/598-race-label","default":false},{"id":"br-closed","name":"preview/feat/1-closed","default":false},{"id":"br-other","name":"preview/feat/2-other","default":false}]}' > "$T/branches"
  stub curl "$fails"'
  case "$*" in
    *"-X DELETE"*) ;;
    *"/projects/proj/branches") cat "$T/branches" ;;
    *) exit 1 ;;
  esac'
}
# github <head sha>: the pull request's head is that commit, and the open pull requests are those of feat/598 and feat/2.
github() {
  stub gh "$fails
  case \"\$*\" in
    *pulls/7*) echo $1 ;;
    *pulls?state=open*) printf '%s\n' feat/598-race-label feat/2-other ;;
    *) exit 1 ;;
  esac"
}
# As GitHub runs a step that names no shell: bash -e, without pipefail.
step_runs() {
  run env NEON_API_KEY=key NEON_PROJECT_ID=proj GH_TOKEN=token GITHUB_REPOSITORY=owner/myapp PR=7 \
    BRANCH=feat/598-race-label HEAD_SHA=head123 bash --noprofile --norc -e -c "$1"
}
tested=$(commands "$(step ci.yml delete-preview "$after_e2e")")
swept=$(commands "$(step flag-idle.yml look "$scheduled")")

scenario "once the end-to-end tests have run, the pull request's preview database branch is deleted, and no other"
neon; github head123
step_runs "$tested"
expect_status 0
expect_calls 1 "$(deleted br-preview)"
expect_no_call "$(deleted br-production)"
expect_no_call "$(deleted br-other)"
expect_output "deleted preview/feat/598-race-label: its end-to-end tests have run"

scenario "a push since the tested commit keeps the branch its build uses, and asks Neon nothing"
neon; github newer45
step_runs "$tested"
expect_status 0
expect_no_call "console.neon.tech"
expect_output "kept preview/feat/598-race-label: newer45 was pushed after head123"

scenario "a pull request with no preview branch deletes nothing"
neon; github head123
echo '{"branches":[{"id":"br-production","name":"main","default":true}]}' > "$T/branches"
step_runs "$tested"
expect_status 0
expect_no_call "-X DELETE"
expect_output "preview/feat/598-race-label does not exist"

for broken in 'gh:pulls/7' 'curl:/projects/proj/branches' 'curl:-X DELETE'; do
  scenario "a failed ${broken%%:*} call (${broken#*:}) after the tests fails the step"
  neon; github head123
  broken "${broken#*:}"
  step_runs "$tested"
  [ "$status" -ne 0 ] || fail "expected the step to fail, got status 0"
  expect_no_output "deleted preview/"
done

scenario "ci.yml deletes the branch only once e2e ran the tests and passed, in a job with no checkout"
deleting=$(job ci.yml delete-preview)
[ "$(sed -n 's/^    needs: //p' <<<"$deleting")" = e2e ] || fail "expected delete-preview to need e2e"
condition=$(sed -n 's/^    if: //p' <<<"$deleting")
# With a status function it would run after a failed, refused or skipped e2e, whose fix round needs the database.
! grep -qE 'always\(|cancelled\(|failure\(' <<<"$condition" \
  || fail "expected delete-preview to run only after a passed e2e, got: $condition"
grep -qF -- "needs.e2e.outputs.run == 'true'" <<<"$condition" \
  || fail "expected delete-preview to run only when the tests ran, got: $condition"
! grep -qE 'uses: actions/checkout|factory/scripts/' <<<"$deleting" \
  || fail "expected delete-preview to check out nothing and run no script, which an agent can change (decisions M15)"

scenario "on the schedule, a closed pull request's preview database branch is deleted, and an open one's kept"
neon; github head123
step_runs "$swept"
expect_status 0
expect_calls 1 "$(deleted br-closed)"
expect_no_call "$(deleted br-preview)"
expect_no_call "$(deleted br-other)"
expect_no_call "$(deleted br-production)"
expect_output "kept preview/feat/2-other: its pull request is open"
expect_output "deleted preview/feat/1-closed: no open pull request is built from its git branch"

scenario "on the schedule, with no pull request open, every preview database branch is deleted, and production kept"
neon
stub gh 'case "$*" in *pulls?state=open*) ;; *) exit 1 ;; esac'
step_runs "$swept"
expect_status 0
expect_calls 3 "-X DELETE"
expect_no_call "$(deleted br-production)"

for broken in 'gh:pulls?state=open' 'curl:/projects/proj/branches'; do
  scenario "a failed ${broken%%:*} call (${broken#*:}) on the schedule deletes nothing"
  neon; github head123
  broken "${broken#*:}"
  step_runs "$swept"
  [ "$status" -ne 0 ] || fail "expected the step to fail, got status 0"
  expect_no_call "-X DELETE"
done

scenario "flag-idle.yml runs the clean-up on its schedule, before any checkout, and a failure keeps the idle tickets flagged"
grep -q '^  schedule:$' "$root/factory/workflows/flag-idle.yml" || fail "expected flag-idle.yml to start on a schedule"
look=$(job flag-idle.yml look)
first=$(grep -n -F -- "- name: $scheduled" <<<"$look" | cut -d: -f1)
checkout=$(grep -n -F -- "uses: actions/checkout" <<<"$look" | head -n 1 | cut -d: -f1)
[ -n "$first" ] && [ "$first" -lt "${checkout:-0}" ] || fail "expected the clean-up before the checkout (decisions M15)"
grep -q '^        continue-on-error: true$' <<<"$(step flag-idle.yml look "$scheduled")" \
  || fail "expected a failed clean-up to let the rest of the job run"

