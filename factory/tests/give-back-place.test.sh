#!/usr/bin/env bash
# Tests for factory/scripts/give-back-place.sh: a build that never reached the engineer gives its place back.
. "$(dirname "$0")/helpers.sh"

# $T/fail holds the start of each call that should fail; what start-waiting.sh reads is as waiting_on_github says.
github() {
  : > "$T/fail"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "issue edit "*|"issue comment "*) ;;
      *) waiting_on_github "$@" ;;
    esac'
}
give_back() {
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=900 \
    "$scripts/give-back-place.sh" "$@"
}

scenario "gives the place back, asks for a person and says the build never began"
github
give_back 12
expect_status 0
expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
expect_call "gh issue comment 12 --body The build of this ticket never began"
expect_call "Add the \`ready\` label again to start it. See https://github.com/owner/myapp/actions/runs/900"

scenario "says nothing more to a ticket that was told why it was not built"
github
give_back 12 true
expect_status 0
expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
expect_no_call "gh issue comment"

scenario "an empty second argument is a ticket that was not told"
github
give_back 12 ""
expect_call "gh issue comment 12"

scenario "stops, and says the place is still held, when the label cannot be taken off"
github
echo "issue edit" > "$T/fail"
give_back 12
expect_status 1
expect_output "it holds a place with no build until the label is removed by hand"
expect_no_call "gh issue comment"

scenario "stops when the ticket cannot be told, with the place already given back"
github
echo "issue comment" > "$T/fail"
give_back 12
expect_status 1
expect_output "its place was given back, but it could not be told so"
expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"

scenario "a ticket told why it was not built, with a ticket waiting with ready, starts the waiting ticket's build"
github
echo '[{"number":20},{"number":21}]' > "$T/issues"
echo '[{"number":31},{"number":30}]' > "$T/ready"
give_back 12 true
expect_status 0
expect_call "gh workflow run implement.yml -f issue=30"
expect_no_call "issue=31"
[ "$(grep -n 'workflow run' "$T/calls" | cut -d: -f1)" -gt "$(grep -n 'issue edit 12' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the place was given back"

scenario "a build that never began for a cause unknown starts no waiting ticket: its build could fail the same way"
github
echo '[{"number":30}]' > "$T/ready"
give_back 12
expect_status 0
expect_call "gh issue comment 12"
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

scenario "with three still in flight it starts no waiting ticket"
github
echo '[{"number":20},{"number":21},{"number":22}]' > "$T/issues"
echo '[{"number":30}]' > "$T/ready"
give_back 12 true
expect_status 0
expect_no_call "gh workflow run"

scenario "a place that could not be taken back starts no waiting ticket"
github
echo '[{"number":30}]' > "$T/ready"
echo "issue edit" > "$T/fail"
give_back 12 true
expect_status 1
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

while IFS='|' read -r words message; do
  scenario "stops with a message, the place given back, when this fails: gh $words"
  github
  echo '[{"number":30}]' > "$T/ready"
  echo "$words" > "$T/fail"
  give_back 12 true
  expect_status 1
  expect_output "$message"
  expect_output "Issue #12 gave its place back, and the tickets that wait with ready were not all started"
  expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
done <<'CALLS'
api repos/{owner}/{repo}/issues?state=open&labels=ready|the tickets labelled ready could not be read from GitHub
pr list|what is in flight could not be read from GitHub
workflow run implement.yml|the build of these waiting tickets could not be started: #30
CALLS

scenario "refuses anything that is not an issue number, and calls nothing"
github
give_back "12 --add-label deployed"
expect_status 1
expect_output "is not an issue number"
expect_no_call "gh "

scenario "implement.yml gives the place back whenever the engineer never ran"
workflow="$root/factory/workflows/implement.yml"
grep -qF "if: always() && steps.place.outputs.start == 'true' && steps.agent.outcome == 'skipped'" "$workflow" \
  || fail "implement.yml has no step that runs when a place was taken and the engineer was skipped"
grep -qF 'run: factory/scripts/give-back-place.sh "$ISSUE" "${{ steps.validate.outputs.notified }}"' "$workflow" \
  || fail "implement.yml does not run give-back-place.sh with what validation told the ticket"
# A step's outcome is empty until its turn has come, so the condition holds only after it.
[ "$(grep -n 'give-back-place.sh' "$workflow" | cut -d: -f1)" -gt "$(grep -n 'id: agent' "$workflow" | cut -d: -f1)" ] \
  || fail "implement.yml gives the place back before the engineer's step, where its outcome is not yet known"
grep -qF '      actions: write' "$workflow" || fail "implement.yml may not start the build of a ticket that waits"
grep -qF 'echo "notified=true" >> "$GITHUB_OUTPUT"' "$workflow" || fail "the validation step does not say that it told the ticket"
[ "$(grep -c -- '--remove-label in-progress' "$workflow")" -eq 0 ] \
  || fail "implement.yml takes in-progress off in a step of its own, which a failure before it would skip"
