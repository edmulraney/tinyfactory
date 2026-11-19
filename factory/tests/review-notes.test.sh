#!/usr/bin/env bash
# Tests for factory/scripts/review-notes.sh, which keeps the reviewers' notes in one ticket and starts its build.
. "$(dirname "$0")/helpers.sh"

# $T/issues is what GitHub lists; $T/building and $T/pulls are what in-flight.sh reads; $T/fail holds words of the call to fail.
github() {
  echo '[]' > "$T/issues"
  echo '[]' > "$T/building"
  echo '[]' > "$T/pulls"
  echo none > "$T/fail"
  : > "$T/kept"
  stub date 'echo 07'
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "$(cat "$T/building")" "$@" ;;
      "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") cat "$T/pulls" ;;
      "issue create --title Apply the review notes of week 7 --label factory --body "*)
        printf "%s\n" "$8" > "$T/body"; cat "$T/made" 2>/dev/null || echo https://github.com/owner/repo/issues/50 ;;
      "issue comment "*" --body "*) printf "%s\n" "$5" >> "$T/kept" ;;
      "issue close 50 --reason not planned") ;;
      "workflow run implement.yml -f issue="*) ;;
      "issue edit "*" --add-label ready" | "issue edit "*" --remove-label ready --add-label needs-human") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# The second label is built apart: inside ${3:+...} a Mac's bash 3.2 keeps the backslash of an escaped brace, which is not JSON.
ticket() {
  local second=""
  [ -z "${3:-}" ] || second=",{\"name\":\"$3\"}"
  echo "{\"number\":$1,\"title\":\"Apply the review notes of week $2\",\"user\":{\"login\":\"${4:-github-actions[bot]}\"},\"labels\":[{\"name\":\"factory\"}$second]}"
}
pull() { echo "{\"number\":$1,\"headRefName\":\"feat/$2-apply-review-notes\",\"author\":{\"login\":\"app/claude\"},\"labels\":[],\"isDraft\":$3}"; }
keep() { run "$scripts/review-notes.sh" keep "Ryan (correctness)" 7 <<<"$notes"; }
notes='1. `a.ts:9`: The name could say more.
   Fix: Call it runsPerDay.
2. `b.ts`: A long function.
   Fix: Split it.'

scenario "the first notes of a week make the ticket, named for the week, and are its one comment"
github
keep
expect_status 0
expect_call "gh issue create --title Apply the review notes of week 7 --label factory"
[ "$(grep -c '^gh issue comment' "$T/calls")" = 1 ] || fail "expected one comment for the two notes"
expect_call "gh issue comment 50 --body"
[ "$(cat "$T/kept")" = "**Ryan (correctness)** on pull request #7:

$notes" ] || fail "expected the comment to say whose notes they are, then the notes, got: $(cat "$T/kept")"
expect_output "kept in issue #50"

scenario "the ticket it makes is one the build accepts, and tells the engineer where the notes are and what to do with each"
github
keep
made=$(jq -n --arg body "$(cat "$T/body")" '{title: "Apply the review notes of week 7", body: $body, labels: [{name: "factory"}], createdAt: "2027-01-01T00:00:00Z"}')
stub gh 'case "$*" in "issue view 50 --json title,body,labels,createdAt") cat "$T/ticket.json" ;; *) exit 1 ;; esac'
echo "$made" > "$T/ticket.json"
run "$scripts/check-ticket.sh" 50
expect_status 0
for expected in "--comments" "headed by a reviewer's name" "skip any other comment" "or answer it in one line" "seen three times" '`apps/` included'; do
  grep -qF -- "$expected" "$T/body" || fail "expected the ticket to say: $expected"
done

scenario "later notes join the ticket that is there, whatever week it was made in"
github
echo "[$(ticket 40 6)]" > "$T/issues"
keep
expect_status 0
expect_call "gh issue comment 40 --body"
expect_no_call "issue create"

scenario "of two tickets made at the same moment, the older takes the notes"
github
echo "[$(ticket 41 7),$(ticket 40 7)]" > "$T/issues"
keep
expect_call "gh issue comment 40 --body"
expect_no_call "issue comment 41"

scenario "a ticket being built takes no more notes, which its engineer would never read: a new one is made"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo '[{"number":40}]' > "$T/building"
keep
expect_status 0
expect_call "gh issue create"
expect_call "gh issue comment 50 --body"
expect_no_call "issue comment 40"

scenario "a ticket whose pull request waits for the owner takes no more notes either"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "[$(pull 60 40 false)]" > "$T/pulls"
keep
expect_call "gh issue comment 50 --body"
expect_no_call "issue comment 40"

scenario "a ticket whose build was cut short at a draft is built again from the ticket, so it still takes notes"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "[$(pull 60 40 true)]" > "$T/pulls"
keep
expect_call "gh issue comment 40 --body"
expect_no_call "issue create"

scenario "a pull request of that title, and a ticket of another, are not the ticket"
github
echo '[{"number":60,"title":"Apply the review notes of week 6","pull_request":{}},{"number":12,"title":"Keep review notes in one ticket a week"}]' > "$T/issues"
keep
expect_call "gh issue create"
expect_call "gh issue comment 50 --body"

scenario "a ticket of that label and title that another account opened takes no note: anyone may open one"
github
echo "[$(ticket 40 6 "" mallory)]" > "$T/issues"
keep
expect_status 0
expect_call "gh issue create"
expect_call "gh issue comment 50 --body"
expect_no_call "issue comment 40"

scenario "no notes: nothing is asked of GitHub"
github
run "$scripts/review-notes.sh" keep "Ryan (correctness)" 7 <<<""
expect_status 0
[ ! -s "$T/calls" ] || fail "expected no call at all"

scenario "a mention of the agent in a note is taken out"
github
run "$scripts/review-notes.sh" keep "Ryan (correctness)" 7 <<<'1. `a.ts`: Ask @claude.'
[[ "$(cat "$T/kept")" == *"Ask claude."* ]] || fail "expected the mention gone, got: $(cat "$T/kept")"

scenario "when the tickets cannot be listed, it stops and makes none: a second ticket would split the week"
github
echo "api repos" > "$T/fail"
keep
expect_status 1
expect_output "were not kept"
expect_no_call "issue create"
expect_no_call "issue comment"

scenario "when what is in flight cannot be read, it stops: the notes might go to a ticket already built"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "pr list" > "$T/fail"
keep
expect_status 1
expect_output "were not kept"
expect_no_call "issue create"
expect_no_call "issue comment"

scenario "when the ticket cannot be made, it stops with a message"
github
echo "issue create" > "$T/fail"
keep
expect_status 1
expect_output "could not be made"
expect_no_call "issue comment"

scenario "when GitHub does not say which ticket it made, nothing is commented on"
github
echo "created" > "$T/made"
keep
expect_status 1
expect_output "did not say which ticket"
expect_no_call "issue comment"

scenario "when the notes cannot be added to a ticket that was there, it stops and the ticket stays open"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "issue comment" > "$T/fail"
keep
expect_status 1
expect_output "issue #40 could not be commented on"
expect_no_call "issue close"

scenario "when the notes cannot be added to the ticket just made, the ticket is closed: none is left with no note in it"
github
echo "issue comment" > "$T/fail"
keep
expect_status 1
expect_call "gh issue close 50 --reason not planned"
expect_output "were not kept"

scenario "when that ticket cannot be closed either, it says which to close"
github
echo https://github.com/owner/repo/issues/50 > "$T/made"
stub gh '
  case "$*" in
    "api "*) echo ;;
    "issue create "*) cat "$T/made" ;;
    *) echo "gh: could not connect" >&2; exit 1 ;;
  esac'
keep
expect_status 1
expect_output "issue #50, made for them, is open with no note in it: close it"

scenario "start: with no ticket holding notes, nothing is started and the job passes"
github
run "$scripts/review-notes.sh" start
expect_status 0
expect_output "nothing was started"
expect_no_call "workflow run"

scenario "start: the ticket is labelled ready, without which no build starts, then its build is started by its number"
github
echo "[$(ticket 40 6)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_status 0
[ "$(tail -n 2 "$T/calls" | tr '\n' ' ')" = "gh issue edit 40 --add-label ready gh workflow run implement.yml -f issue=40 " ] \
  || fail "expected ready to be added, then the build started"
expect_output "started the build of issue #40"

scenario "start: a ticket already built or being built is not started again; one that waits beside it is"
github
echo "[$(ticket 40 6),$(ticket 41 6),$(ticket 42 7)]" > "$T/issues"
echo '[{"number":41}]' > "$T/building"
echo "[$(pull 60 40 false)]" > "$T/pulls"
run "$scripts/review-notes.sh" start
expect_status 0
expect_call "gh workflow run implement.yml -f issue=42"
expect_no_call "issue=40"
expect_no_call "issue=41"

scenario "start: of two tickets that wait, only the older is built: the other takes the notes that come next"
github
echo "[$(ticket 41 7),$(ticket 40 7)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_status 0
expect_call "gh workflow run implement.yml -f issue=40"
expect_no_call "issue=41"

scenario "start: a ticket flagged needs-human waits for the owner and is not started, though it still takes notes"
github
echo "[$(ticket 40 6 needs-human)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_status 0
expect_output "nothing was started"
expect_no_call "workflow run"
keep
expect_call "gh issue comment 40 --body"

scenario "start: a flagged ticket does not keep the one behind it from being built"
github
echo "[$(ticket 40 6 needs-human),$(ticket 41 7)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_call "gh workflow run implement.yml -f issue=41"
expect_no_call "issue=40"

scenario "start: a ticket another account opened is never labelled ready or started; the one the factory filed beside it is"
github
echo "[$(ticket 40 6 "" mallory),$(ticket 41 7)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_status 0
expect_call "gh issue edit 41 --add-label ready"
expect_call "gh workflow run implement.yml -f issue=41"
expect_no_call "issue edit 40"
expect_no_call "issue=40"

scenario "start: with only a ticket another account opened, nothing is labelled or started"
github
echo "[$(ticket 40 6 "" mallory)]" > "$T/issues"
run "$scripts/review-notes.sh" start
expect_status 0
expect_output "nothing was started"
expect_no_call "issue edit"
expect_no_call "workflow run"

scenario "start: when the tickets cannot be listed, the job fails and starts nothing"
github
echo "api repos" > "$T/fail"
run "$scripts/review-notes.sh" start
expect_status 1
expect_output "No build was started"
expect_no_call "workflow run"

scenario "start: a build that cannot be started fails the job, and the ticket is told and flagged for a person"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "workflow run" > "$T/fail"
run "$scripts/review-notes.sh" start
expect_status 1
expect_output "The build of issue #40 could not be started."
[ "$(head -n 1 "$T/kept")" = 'Add the `ready` label: the build of this ticket starts when a place is free.' ] \
  || fail "expected the comment's first line to say how to start it, got: $(head -n 1 "$T/kept")"
expect_call "gh issue edit 40 --remove-label ready --add-label needs-human"

scenario "start: a ticket that cannot be labelled ready is not started, and is told and flagged the same way"
github
echo "[$(ticket 40 6)]" > "$T/issues"
echo "issue edit 40 --add-label ready" > "$T/fail"
run "$scripts/review-notes.sh" start
expect_status 1
expect_no_call "workflow run"
expect_call "gh issue edit 40 --remove-label ready --add-label needs-human"

scenario "start: when the ticket cannot be told either, the log says so"
github
echo "[$(ticket 40 6)]" > "$T/issues"
stub gh '
  case "$*" in
    "api "*"labels=in-progress"*) ;;
    "api "*) echo 40 ;;
    "pr list "*) echo "[]" ;;
    *) echo "gh: could not connect" >&2; exit 1 ;;
  esac'
run "$scripts/review-notes.sh" start
expect_status 1
expect_output "Issue #40 could not be told so, or flagged for a person."

scenario "with no command, or one it does not know, it says how it is used"
github
run "$scripts/review-notes.sh" sweep
expect_status 1
expect_output "Usage: review-notes.sh keep"
[ ! -s "$T/calls" ] || fail "expected no call at all"

# A change to either side must fail here: the script starts a build with an input implement.yml has to take.
scenario "review-notes.yml runs the start, and implement.yml builds the ticket it is started with"
grep -qF 'run: factory/scripts/review-notes.sh start' "$root/factory/workflows/review-notes.yml" \
  || fail "review-notes.yml does not run review-notes.sh start"
workflow="$root/factory/workflows/implement.yml"
grep -A3 -F 'workflow_dispatch:' "$workflow" | grep -qxF '      issue:' || fail "implement.yml takes no issue to be started with"
grep -qF 'ISSUE: ${{ github.event.issue.number || inputs.issue }}' "$workflow" || fail "implement.yml does not build the issue it is started with"
grep -qF "if: github.event.label.name == 'ready' || github.event_name == 'workflow_dispatch'" "$workflow" \
  || fail "implement.yml's job does not run when it is started with an issue"
# review-notes.sh starts the build with the workflow's own token, and the action refuses a bot it was not told to allow.
steps=$(grep -cF 'uses: anthropics/claude-code-action@v1' "$workflow")
allowed=$(grep -cF "allowed_bots: \${{ github.event_name == 'workflow_dispatch' && '*' || '' }}" "$workflow")
[ "$steps" -gt 0 ] && [ "$steps" = "$allowed" ] \
  || fail "implement.yml has $steps engineer steps and $allowed that allow a build started by a bot"
