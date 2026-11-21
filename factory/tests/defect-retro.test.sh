#!/usr/bin/env bash
# Tests for the retro of a defect met in use: which label starts retro.yml, and that a ticket gets one retro.
. "$(dirname "$0")/helpers.sh"

workflow="$root/factory/workflows/retro.yml"

job() { awk '$0 == "  retro:" { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflow"; }
# step <name>: the step's lines, read from the source, so a change there fails here.
step() { job | awk -v first="      - name: $1" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$1" | sed '1d; s/^          //'; }

# starts <event> <label> [sender]: whether the job's condition, as the workflow holds it, lets the job run for that event
# in the repository of `owner`. The sender is the owner unless one is given.
starts() {
  local condition event="'$1'" label="'$2'" sender="'${3:-owner}'" owner="'owner'"
  condition=$(job | sed -n 's/^    if: //p')
  condition=${condition//github.event_name/$event}
  condition=${condition//github.event.label.name/$label}
  condition=${condition//github.event.sender.login/$sender}
  condition=${condition//github.repository_owner/$owner}
  eval "[[ $condition ]]"
}

# github: ticket #574 on GitHub (decisions A574a, A574b), no usage limit held, and a checkout whose save-session.sh puts a lesson
# on the sessions branch the next run clones, which is .sessions here.
github() {
  stub gh '
    case "$*" in
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;;
      "issue view 574 --json url,state,labels,closedByPullRequestsReferences")
        echo "{\"url\":\"https://github.example/owner/myapp/issues/574\",\"state\":\"CLOSED\",\"labels\":[{\"name\":\"bug\"}],\"closedByPullRequestsReferences\":[{\"number\":577}]}" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  mkdir -p .sessions/lessons factory/scripts "$T/runner"
  ln -s "$root"/factory/scripts/* factory/scripts/
  rm factory/scripts/save-session.sh
  printf '#!/usr/bin/env bash\n[ "$1" != lesson ] || cp "$3" ".sessions/lessons/20261121T080000Z-lesson-run$GITHUB_RUN_ID.json"\n' > factory/scripts/save-session.sh
  chmod +x factory/scripts/save-session.sh
}
# labelled <run-id>: runs the step that gathers the facts as a run the label on ticket #574 started would.
labelled() {
  : > "$T/output"
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID="$1" GITHUB_OUTPUT="$T/output" \
    DEFECT=574 PR="" RUN="" COMMENT="" bash -e -c "$(commands "$(step "Gather the run's facts")")"
}
# learnt <run-id>: runs the step that saves the lesson the session of that run returned.
learnt() {
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID="$1" RUNNER_TEMP="$T/runner" KEY=issue-574 TRANSCRIPT="" \
    OUTPUT='{"summary":"Tickets #348 and #349 left a second race out of scope, and no step asked what a signed-in runner then sees.","cause":"ticket","repeats":[],"handling":[],"retry":"not-applicable","propose":true}' \
    bash -e -c "$(commands "$(step "Save the lesson beside the transcripts")")"
}
output() { grep -cxF -- "$1" "$T/output"; }

scenario "the \`bug\` label starts the job, as a command does, and no other label"
starts issues bug || fail "expected the \`bug\` label to start the job"
starts workflow_dispatch "" || fail "expected a command to start the job"
for label in ready initiative factory retro proposal deployed escaped-defect ""; do
  ! starts issues "$label" || fail "expected the label \"$label\" to start no job"
done
! starts issues bug a-stranger || fail "expected the \`bug\` label to start no job when an account other than the owner added it"
[ "$(job | grep -c '^    if: ')" = 1 ] || fail "expected the job to hold one condition"
[ "$(sed -n '/^jobs:/,$p' "$workflow" | grep -c '^  [a-z-]*:$')" = 1 ] || fail "retro.yml has a second job, which the label does not guard"
grep -qxF '  DEFECT: ${{ github.event.issue.number }}' "$workflow" || fail "retro.yml does not take the number of the labelled ticket"

scenario "retro.yml starts when a ticket is labelled"
cd "$root" || exit 1
run "$scripts/events.sh"
expect_status 0
expect_output '| `retro.yml` | workflow_dispatch (inputs: pr run comment); issues (types: labeled) |'

scenario "the label on a ticket no retro has looked at starts one retro, of that ticket"
github
labelled 900
expect_status 0
[ "$(output go=true)" = 1 ] || fail "expected the retro to go ahead"
[ "$(output "subject=ticket #574, a defect the owner met in use")" = 1 ] || fail "expected the session to be given the ticket"
[ "$(output key=issue-574)" = 1 ] || fail "expected the transcript to be kept with the ticket's"
[ "$(jq -r '.defect.url' .sessions/facts.json)" = "https://github.example/owner/myapp/issues/574" ] || fail "expected the facts to hold the ticket"

scenario "the label a second time, once the first retro saved its lesson, starts none"
github
labelled 900
learnt 900
expect_status 0
[ "$(jq -r '.issue, .facts.defect.state, .lesson.cause' .sessions/lessons/*.json | tr '\n' ' ')" = "574 CLOSED ticket " ] \
  || fail "expected the saved lesson to hold the ticket and what the session returned"
labelled 901
expect_status 0
[ "$(output go=false)" = 1 ] || fail "expected no second retro"
[ "$(output go=true)" = 0 ] || fail "expected no second retro"
expect_output "a retro has looked at ticket #574: no retro"

scenario "the label again after a retro that saved no lesson starts another"
github
labelled 900
labelled 901
expect_status 0
[ "$(output go=true)" = 1 ] || fail "expected the retro to go ahead"

scenario "every step after the facts runs only for a retro that goes ahead"
while IFS= read -r name; do
  step "$name" | grep -qE "^        if: .*steps\.(facts\.outputs\.go == 'true'|(first|second|wait1|wait2)\.|propose\.outputs\.rewrite == 'true')" \
    || fail "the step \"$name\" runs for a ticket whose retro does not go ahead"
done < <(job | sed -n "/- name: Gather the run's facts/,\$p" | sed -n 's/^      - name: //p' | sed 1d)

scenario "the facts of a ticket that cannot be read stop the job, and no retro goes ahead"
github
stub gh 'case "$*" in "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;; *) echo "gh: could not connect" >&2; exit 1 ;; esac'
labelled 900
expect_failure
expect_output "Could not read ticket #574 from GitHub, so the facts of the defect are not known."
[ "$(output go=true)" = 0 ] || fail "expected no retro to go ahead"
