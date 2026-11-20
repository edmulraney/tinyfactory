#!/usr/bin/env bash
# Tests for usage-limit.sh: the hold the Claude usage limit puts on every agent, kept on the sessions branch.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

ahead=99999999999
ahead_in_words="5138-11-16 09:46 UTC"
passed=1000000000

# github [sessions]: the repo on GitHub, with a sessions branch when asked. $T/fail lists the gh calls that fail,
# by their first words; $T/posted keeps each comment. Issue #12 carries ready, and what else start-waiting.sh
# reads is as waiting_on_github says.
github() {
  sessions_remote "${1:-}"
  : > "$T/fail"; : > "$T/posted"; : > "$T/outputs"
  export GITHUB_RUN_ID=900 GITHUB_OUTPUT="$T/outputs" GITHUB_EVENT_NAME=issues
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "issue comment "*" --body "*) printf "#%s: %s\n" "$3" "$5" >> "$T/posted" ;;
      "run rerun "*) ;;
      "issue view 12 --json labels "*) json "{\"labels\":[{\"name\":\"ready\"}]}" "$@" ;;
      "issue edit 12 "*) ;;
      "api repos/{owner}/{repo}/issues/events?per_page=100 "*) json "[]" "$@" ;;
      *) waiting_on_github "$@" ;;
    esac'
}
limit() { run "$scripts/usage-limit.sh" "$@"; }
expect_silent() { [ -z "$out" ] || fail "expected it to print nothing"; }
expect_hold() { [ "$(the_hold)" = "$1" ] || fail "expected the sessions branch to hold: $1"$'\n'"it holds: $(the_hold)"; }
expect_posted() { [[ "$(cat "$T/posted")" == *"$1"* ]] || fail "expected the comment: $1"$'\n'"posted: $(cat "$T/posted")"; }
expect_written() { [ "$(cat "$T/outputs")" = "$1" ] || fail "expected the step's outputs to be: $1"$'\n'"they are: $(cat "$T/outputs")"; }

scenario "a reset time ahead refuses a build and a review with that time and leaves a limit-ended fix round uncounted; once resume.yml's step lifts it, both start"
github sessions
echo '[{"number":12}]' > "$T/ready"
limit hold "$ahead"
expect_status 0
run "$scripts/start-build.sh" 12
expect_status 0
expect_output "not started: the Claude usage limit holds every agent until $ahead_in_words, so issue #12 waits with ready"
expect_written "start=false"
expect_posted "#12: Waiting: the Claude usage limit covers the whole account, and no agent starts until it resets on $ahead_in_words."
expect_no_call "gh issue edit"
: > "$T/outputs"
limit wait 7 "Adam's review" failed
expect_status 1
expect_output "the Claude usage limit holds every agent until $ahead_in_words: Adam's review starts after it"
expect_written "held=true"
expect_posted "#7: Nothing to do: Adam's review starts after the Claude usage limit resets on $ahead_in_words."
echo '[{"type":"result","is_error":true,"terminal_reason":"api_error","api_error":"usage_limit_reached","session_id":"abc-123"}]' > "$T/execution.json"
: > "$T/calls"
run "$scripts/record-fix-round.sh" 7 "$T/execution.json"
expect_status 0
expect_output "the Claude usage limit ended the fix round on pull request #7: it is not counted"
[ ! -s "$T/calls" ] || fail "expected no marker to be written, and GitHub not to be called"
# What resume.yml runs.
: > "$T/outputs"
limit resume now
expect_status 0
expect_hold ""
expect_call "gh run rerun 900 --failed"
expect_call "gh workflow run implement.yml -f issue=12"
run "$scripts/start-build.sh" 12
expect_status 0
expect_written "start=true"
: > "$T/outputs"; : > "$T/posted"
limit wait 7 "Adam's review" failed
expect_status 0
expect_silent
expect_written ""
[ ! -s "$T/posted" ] || fail "expected a review that starts to be told nothing"

scenario "held: prints nothing when no hold is recorded, or when the repo has no sessions branch yet"
github sessions
limit held
expect_status 0
expect_silent
github
limit held
expect_status 0
expect_silent

scenario "held: prints when the limit resets while that time is ahead, and nothing once it has passed"
github sessions
hold_is "$ahead"
limit held
expect_status 0
expect_output "$ahead_in_words"
hold_is "$passed" "run 44"
limit held
expect_status 0
expect_silent

scenario "held: a read that fails is not 'no hold'"
github sessions
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
limit held
expect_status 1
expect_output "Whether the Claude usage limit holds every agent could not be read from the sessions branch."

scenario "hold: records the reset time, prints it in words, and makes the sessions branch when there is none"
github
limit hold "$ahead"
expect_status 0
expect_output "$ahead_in_words"
expect_hold "$ahead"
[ "$(on_github log -1 --format=%s sessions)" = "usage limit: no agent starts until $ahead_in_words" ] || fail "expected the commit to say until when"

scenario "hold: keeps the later of two reset times, and the runs that wait"
github sessions
hold_is "$ahead" "run 44" "failed 45"
limit hold "$passed"
expect_status 0
expect_output "$ahead_in_words"
expect_hold "$ahead"$'\n'"run 44"$'\n'"failed 45"
limit hold 99999999999
limit hold 100000000000
expect_hold "100000000000"$'\n'"run 44"$'\n'"failed 45"

scenario "hold: a push that loses a race is made again on what the winner left"
github sessions
refuses_pushes 2
limit hold "$ahead"
expect_status 0
expect_hold "$ahead"

scenario "hold: stops with a message when the time cannot be written, and when it is given none"
github sessions
refuses_pushes
limit hold "$ahead"
expect_status 1
expect_output "The Claude usage limit resets on $ahead_in_words, and that could not be written to the sessions branch, so nothing holds the other agents until then."
limit hold tomorrow
expect_status 1
expect_output "Usage: usage-limit.sh"

scenario "wait: with no limit holding it says nothing, writes nothing and tells nobody"
github sessions
hold_is "$passed"
limit wait 7 "a fix round"
expect_status 0
expect_silent
expect_written ""
expect_hold "$passed"
expect_no_call "gh issue comment"

scenario "wait: held, a run keeps its place once, its pull request is told what to do, and the step passes"
github sessions
hold_is "$ahead"
limit wait 7 "a fix round"
expect_status 0
expect_output "the Claude usage limit holds every agent until $ahead_in_words: a fix round starts after it"
expect_written "held=true"
expect_hold "$ahead"$'\n'"run 900"
expect_first_line "gh issue comment 7 --body" "Nothing to do: a fix round starts after the Claude usage limit resets on $ahead_in_words."
expect_posted "If the limit was lifted sooner, run \`gh workflow run resume.yml\`: everything that waits starts at once."
limit wait 7 "a fix round"
expect_hold "$ahead"$'\n'"run 900"

scenario "wait: with failed the step fails, and the run is kept as one whose failed jobs alone are run again"
github sessions
hold_is "$ahead" "run 44"
limit wait 7 "Ryan's review" failed
expect_status 1
expect_written "held=true"
expect_hold "$ahead"$'\n'"run 44"$'\n'"failed 900"

scenario "wait: a run with no ticket or pull request keeps its place and tells nobody"
github sessions
hold_is "$ahead"
limit wait "" "the retro"
expect_status 0
expect_output "the retro starts after it"
expect_hold "$ahead"$'\n'"run 900"
expect_no_call "gh issue comment"

scenario "wait: when the hold cannot be read the step fails, marked held so that a review's failed job starts no fix round"
github sessions
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
limit wait 7 "Adam's review" failed
expect_status 1
expect_written "held=true"
expect_output "could not be read from the sessions branch, so Adam's review did not start."

scenario "wait: stops, telling nobody, when the run's place cannot be written"
github sessions
hold_is "$ahead"
refuses_pushes
limit wait 7 "a fix round"
expect_status 1
expect_output "the place of run 900 could not be written to the sessions branch: nothing starts a fix round again."
expect_no_call "gh issue comment"

scenario "wait: stops when the pull request cannot be told, or when no run is named to run again"
github sessions
hold_is "$ahead"
echo "issue comment" > "$T/fail"
limit wait 7 "a fix round"
expect_status 1
expect_output "#7 could not be told that a fix round starts after it."
unset GITHUB_RUN_ID
limit wait 7 "a fix round"
expect_status 1
expect_output "GITHUB_RUN_ID names no run to run again then, so a fix round has no place."

scenario "resume: with no hold recorded it prints nothing, and by hand it says so"
github sessions
limit resume
expect_status 0
expect_silent
limit resume now
expect_status 0
expect_output "No usage limit is recorded: no agent is held, and nothing was started again."
expect_no_call "gh run rerun"
expect_no_call "labels=ready"

scenario "resume: before the reset time it starts nothing and leaves the hold"
github sessions
hold_is "$ahead" "run 44"
echo '[{"number":30}]' > "$T/ready"
limit resume
expect_status 0
expect_output "The Claude usage limit holds every agent until $ahead_in_words: nothing was started again."
expect_hold "$ahead"$'\n'"run 44"
expect_no_call "gh run rerun"
expect_no_call "gh workflow run"

scenario "resume: once the time has passed it removes the hold, runs each run again as it waited, and starts the waiting tickets"
github sessions
hold_is "$passed" "run 44" "failed 45"
echo '[{"number":30}]' > "$T/ready"
limit resume
expect_status 0
expect_hold ""
expect_call "gh run rerun 44"
expect_no_call "gh run rerun 44 --failed"
expect_call "gh run rerun 45 --failed"
expect_call "gh workflow run implement.yml -f issue=30"
expect_output "The hold of the Claude usage limit is lifted."
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcripts to still be on the branch"

scenario "resume: five builds the usage limit cut short, each with a draft and ready, all start again, and a sixth is told why it waits"
github sessions
hold_is "$passed"
echo '[{"number":35},{"number":34},{"number":33},{"number":32},{"number":31},{"number":30}]' > "$T/ready"
for ticket in 30 31 32 33 34 35; do
  echo "{\"number\":$((ticket + 100)),\"headRefName\":\"feat/$ticket-a-ticket\",\"author\":{\"login\":\"app/claude\"},\"labels\":[],\"isDraft\":true}"
done | jq -cs . > "$T/pulls"
limit resume
expect_status 0
expect_output "The hold of the Claude usage limit is lifted."
for ticket in 30 31 32 33 34; do
  expect_call "gh workflow run implement.yml -f issue=$ticket"
done
expect_no_call "issue=35"
expect_posted "#35: <!-- factory:no-place -->Waiting: 5 tickets are being built or checked, and that is the most the factory allows at once."
expect_posted "- #34 (being built)"
expect_posted "the build that was cut short starts again when one of them has merged, been closed or been left for a person."

scenario "resume now: lifts a hold whose time is ahead, for an owner who lifted the limit early"
github sessions
hold_is "$ahead" "run 44"
echo '[{"number":30}]' > "$T/ready"
limit resume now
expect_status 0
expect_hold ""
expect_call "gh run rerun 44"
expect_call "gh workflow run implement.yml -f issue=30"

scenario "resume: starts nothing when the hold cannot be read or removed"
github sessions
hold_is "$passed" "run 44"
refuses_pushes
limit resume
expect_status 1
expect_output "The hold of the Claude usage limit could not be removed from the sessions branch, so nothing was started again."
expect_no_call "gh run rerun"
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
limit resume
expect_status 1
expect_output "could not be read from the sessions branch, so nothing was started again."

scenario "resume: a run GitHub does not run again is named, the others are still run, and it fails"
github sessions
hold_is "$passed" "run 44" "failed 45"
echo '[{"number":30}]' > "$T/ready"
echo "run rerun 44" > "$T/fail"
limit resume
expect_status 1
expect_output "Run 44 waited for the Claude usage limit, and GitHub did not run it again: start what it was for by hand."
expect_call "gh run rerun 45 --failed"
expect_call "gh workflow run implement.yml -f issue=30"
expect_hold ""

scenario "resume: fails when the waiting tickets could not be started"
github sessions
hold_is "$passed"
echo "api repos/{owner}/{repo}/issues?state=open&labels=ready" > "$T/fail"
limit resume
expect_status 1
expect_output "The tickets that wait with ready were not all started; each is started when a place next frees."
