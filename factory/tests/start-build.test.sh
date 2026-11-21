#!/usr/bin/env bash
# Tests for factory/scripts/start-build.sh, which decides whether a build may start.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/trusted-on-github.sh"

# $T/fail lists the gh calls that fail, $T/after those that fail once the ticket has its place; $T/rival lists rivals.
# $T/labels holds the ticket's labels, $T/ticket who opened it, and $T/writers the accounts that may write to the repo.
# $T/events holds the repo's issue events, newest first.
# $T/ready holds the open issues labelled ready, for start-waiting.sh: a lower number has carried ready longer.
github() {
  echo '[]' > "$T/issues"
  echo '[]' > "$T/pulls"
  echo '{"labels":[{"name":"ready"}]}' > "$T/labels"
  echo '{"user":{"login":"owner"}}' > "$T/ticket"
  printf '%s\n' owner colleague > "$T/writers"
  echo '[]' > "$T/events"
  : > "$T/fail"; : > "$T/after"; : > "$T/rival"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    put() { jq -c "$1" "$T/issues" > "$T/issues.new" && mv "$T/issues.new" "$T/issues"; }
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "pr list --state open "*) cat "$T/pulls" ;;
      "issue comment "*) ;;
      "issue view $3 --json labels "*) json "$(cat "$T/labels")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*" --jq .user.login"*) json "$(cat "$T/ticket")" "$@" ;;
      "api repos/{owner}/{repo}/collaborators/"*) permission_on_github "$@" ;;
      "api repos/{owner}/{repo}/issues/events?per_page=100 "*) json "$(cat "$T/events")" "$@" ;;
      "issue edit "*)
        case "$*" in
          *"--add-label in-progress"*)
            put ". + [{number: $3}]"
            for rival in $(cat "$T/rival"); do put ". + [{number: $rival}]"; done
            cat "$T/after" >> "$T/fail" ;;
          *"--remove-label in-progress"*) put "map(select(.number != $3))" ;;
        esac ;;
      *) waiting_on_github "$@" || exit 1 ;;
    esac'
}
opened_by() { jq -cn --arg login "$1" '{user: {login: $login}}' > "$T/ticket"; }
proposal() { echo '{"labels":[{"name":"factory"},{"name":"proposal"},{"name":"retro"},{"name":"ready"}]}' > "$T/labels"; }
# wait_with_ready <number>...: every open ticket labelled ready, the one being started among them.
wait_with_ready() { printf '{"number":%s}\n' "$@" | jq -cs . > "$T/ready"; }
in_progress() { printf '{"number":%s}\n' "$@" | jq -cs . > "$T/issues"; }
pull() {
  jq -cn --argjson number "$1" --arg branch "$2" --arg author "${3:-app/claude}" --arg label "${4:-}" \
    --argjson draft "${5:-false}" \
    '{number: $number, headRefName: $branch, author: {login: $author}, isDraft: $draft,
      labels: (if $label == "" then [] else [{name: $label}] end)}'
}
pulls_are() { printf '%s\n' "$@" | jq -cs . > "$T/pulls"; }
limit_holds() { echo "$1" > "$T/usage-limit"; }
soon=$(( $(date +%s) + 3600 ))
past=$(( $(date +%s) - 60 ))
when=$(jq -rn --argjson at "$soon" '$at | strftime("%Y-%m-%d %H:%M UTC")')

# took_places <number>...: the tickets labelled in-progress, the last to be labelled first, among other events.
took_places() {
  printf '%s\n' "$@" | jq -c '{event: "labeled", label: {name: "in-progress"}, issue: {number: .}},
    {event: "labeled", label: {name: "ready"}, issue: {number: .}}, {event: "closed", issue: {number: 99}}' | jq -cs . > "$T/events"
}
# start [issue] [event]: the event is the one that started the run, the ticket's label unless it is said.
start() {
  : > "$T/outputs"
  run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_OUTPUT="$T/outputs" GITHUB_EVENT_NAME="${2:-issues}" "$scripts/start-build.sh" "${1:-12}"
}
expect_written() {
  [ "$(cat "$T/outputs")" = "start=$1" ] || fail "expected it to write start=$1 and nothing else"
}
expect_place() {
  jq -e --argjson n "$1" 'any(.[]; .number == $n)' "$T/issues" >/dev/null || fail "expected issue #$1 to be left in-progress"
}
expect_no_place() {
  jq -e --argjson n "$1" 'all(.[]; .number != $n)' "$T/issues" >/dev/null || fail "expected issue #$1 not to be left in-progress"
}
expect_untouched() {
  expect_no_call "gh issue edit"
  expect_no_call "gh issue comment"
}

scenario "starts a ticket when nothing is in flight: ready and needs-human come off, in-progress goes on"
github
start
expect_status 0
expect_written true
expect_call "gh issue edit 12 --remove-label ready --remove-label needs-human --add-label in-progress"
expect_no_call "gh issue comment"
# gh refuses a whole edit that names a label the repo does not have, so a ticket without proposal never names it.
expect_no_call "proposal"
expect_place 12

scenario "a ticket another account opened takes no place and starts no session: it is told why, loses ready and is flagged for a person"
github
opened_by stranger
start
expect_status 0
expect_written false
expect_output "not started: issue #12 was opened by stranger, who may not write to this repository"
expect_first_line "gh issue comment 12 --body" "File this ticket again from an account that may write to this repository, if it is to be built."
expect_call 'Not started: `stranger` opened this ticket and may not write to this repository.'
expect_call "gh issue edit 12 --remove-label ready --add-label needs-human"
expect_no_call "in-progress"
expect_no_call "workflow run"
expect_no_place 12

scenario "a ticket another account opened is refused the same way when the waiting are started from it"
github
opened_by stranger
start 12 workflow_dispatch
expect_status 0
expect_written false
expect_calls 1 "gh issue comment 12 --body File this ticket again"
expect_call "gh issue edit 12 --remove-label ready --add-label needs-human"
expect_no_call "in-progress"

scenario "a ticket whose author GitHub no longer names is refused the same way"
github
echo '{"user":null}' > "$T/ticket"
start
expect_status 0
expect_written false
expect_call "Not started: an account GitHub no longer names opened this ticket"
expect_call "gh issue edit 12 --remove-label ready --add-label needs-human"
expect_no_call "collaborators"

scenario "a ticket opened by the owner, by another account that may write, by the Claude app or by a workflow is built as before"
for author in owner colleague 'claude[bot]' 'github-actions[bot]'; do
  github
  opened_by "$author"
  start
  expect_status 0
  expect_written true
  expect_call "gh issue edit 12 --remove-label ready --remove-label needs-human --add-label in-progress"
  expect_no_call "gh issue comment"
  expect_place 12
done

scenario "a short form of a bot's login is not the bot: a ticket by an account named so is refused"
github
opened_by github-actions
start
expect_status 0
expect_written false
expect_call "gh issue edit 12 --remove-label ready --add-label needs-human"

scenario "stops, with ready left on, when who opened the ticket cannot be read"
github
echo "api repos/{owner}/{repo}/issues/12 " > "$T/fail"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: who opened it could not be read from GitHub. It keeps the ready label"
expect_untouched
expect_no_call "collaborators"

scenario "stops, with ready left on, when GitHub would not say whether its author may write: not known is not trusted"
github
touch "$T/permission-fails"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: whether owner, who opened it, may write to this repository is not known. It keeps the ready label"
expect_untouched
expect_no_call "labels=in-progress"

scenario "stops when a ticket another account opened cannot be told why, or cannot be flagged"
github
opened_by stranger
echo "issue comment" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "it could not be told so and flagged for a person"
expect_no_call "gh issue edit"
github
opened_by stranger
echo "issue edit" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "it could not be told so and flagged for a person"
expect_no_place 12

scenario "an accepted proposal loses proposal as it takes its place, with ready and needs-human"
github
proposal
start
expect_status 0
expect_written true
expect_call "gh issue edit 12 --remove-label ready --remove-label needs-human --remove-label proposal --add-label in-progress"
expect_place 12

scenario "a proposal refused a place keeps proposal: a sixth waits with it"
github
proposal
in_progress 20 21 22 28 29
start
expect_status 0
expect_written false
expect_no_call "gh issue edit"

scenario "a proposal already in flight keeps proposal: only ready comes off"
github
proposal
pulls_are "$(pull 30 fix/12-this-ticket)"
start
expect_status 0
expect_written false
expect_call "gh issue edit 12 --remove-label ready"
expect_no_call "proposal"

scenario "a proposal the usage limit holds keeps proposal"
github
proposal
limit_holds "$soon"
start
expect_status 0
expect_written false
expect_output "the Claude usage limit holds every agent until $when"
expect_no_call "proposal"

scenario "a proposal that steps back from the last place gets proposal back with ready"
github
proposal
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 12 13
start
expect_status 0
expect_written false
expect_call "gh issue edit 12 --remove-label in-progress --add-label ready --add-label proposal"
expect_no_place 12

scenario "a proposal whose place is given back gets proposal back: nobody has accepted it until ready is added again"
github
proposal
echo "api repos/{owner}/{repo}/issues?state=open&labels=in-progress" > "$T/after"
start
expect_status 1
expect_written false
expect_output "Its place was given back"
expect_call "gh issue edit 12 --remove-label in-progress --add-label proposal"
expect_no_place 12

scenario "with three being built or checked a fourth starts"
github
in_progress 20 22
pulls_are "$(pull 30 feat/20-first-ticket)" "$(pull 31 fix/21-other-ticket)" "$(pull 33 fix/23-held-ticket app/claude needs-human)"
start
expect_status 0
expect_written true
expect_output "started: issue #12 takes a place, with 4 other tickets in flight"
expect_no_call "gh issue comment"
expect_place 12

scenario "with four being built or checked a fifth starts"
github
in_progress 20 22 24
pulls_are "$(pull 30 feat/20-first-ticket)" "$(pull 31 fix/21-other-ticket)" "$(pull 33 fix/23-held-ticket app/claude needs-human)"
start
expect_status 0
expect_written true
expect_output "started: issue #12 takes a place, with 5 other tickets in flight"
expect_no_call "gh issue comment"
expect_place 12

scenario "with five being built or checked a sixth waits: it keeps ready, and one comment says why and names the five"
github
in_progress 20 22 24 25
pulls_are "$(pull 30 feat/20-first-ticket)" "$(pull 31 fix/21-other-ticket)" "$(pull 33 fix/23-held-ticket app/claude needs-human)"
start
expect_status 0
expect_written false
expect_output "not started: 5 tickets are being built or checked, so issue #12 waits with ready until a place frees"
[ "$(grep -c '^gh issue comment' "$T/calls")" -eq 1 ] || fail "expected one comment and no more"
expect_call "gh issue comment 12 --body Waiting: 5 tickets are being built or checked, and that is the most the factory allows at once."
expect_call "- #20 (pull request #30)"
expect_call "- #21 (pull request #31)"
expect_call "- #22 (being built)"
expect_call "- #24 (being built)"
expect_call "- #25 (being built)"
expect_no_call "#23"
expect_call "This ticket keeps the \`ready\` label, and its build starts when one of them has merged, been closed or been left for a person."
expect_no_call "gh issue edit"
expect_no_place 12

scenario "a waiting ticket started when a place freed, and finding none, waits on and is not told twice"
github
in_progress 20 21 22 28 29
start 12 workflow_dispatch
expect_status 0
expect_written false
expect_output "issue #12 waits with ready until a place frees"
expect_untouched

scenario "a run whose ticket no longer carries ready starts nothing: another run started its build"
github
echo '{"labels":[{"name":"needs-human"}]}' > "$T/labels"
start 12 workflow_dispatch
expect_status 0
expect_written false
expect_output "not started: issue #12 does not carry ready"
expect_untouched
expect_no_call "labels=in-progress"
expect_no_call "user.login"
start
expect_written false
expect_untouched

scenario "a ticket and its pull request are one in flight, so two tickets with a pull request each leave a place"
github
in_progress 20 21 28 29
pulls_are "$(pull 30 feat/20-first-ticket)" "$(pull 31 fix/21-other-ticket)"
start
expect_written true

scenario "two pull requests waiting for the owner hold no place a build needs: beside three tickets being built, a new ticket starts"
github
in_progress 22 28 29
pulls_are "$(pull 30 feat/20-a-ticket app/claude needs-human)" "$(pull 31 fix/21-b-ticket app/claude needs-human)"
start
expect_status 0
expect_written true
expect_output "started: issue #12 takes a place, with 5 other tickets in flight"
expect_place 12
expect_no_call "gh issue comment"

scenario "with five pull requests waiting for the owner nothing starts, and the comment says that is why"
github
pulls_are "$(pull 30 feat/20-a-ticket app/claude needs-human)" "$(pull 31 fix/21-b-ticket app/claude needs-human)" \
  "$(pull 32 fix/22-c-ticket app/claude needs-human)" "$(pull 33 fix/23-d-ticket app/claude needs-human)" \
  "$(pull 34 fix/24-e-ticket app/claude needs-human)"
start
expect_status 0
expect_written false
expect_output "not started: 5 pull requests wait for the owner, so issue #12 waits with ready until a place frees"
[ "$(grep -c '^gh issue comment' "$T/calls")" -eq 1 ] || fail "expected one comment and no more"
expect_call "gh issue comment 12 --body Waiting: 5 pull requests wait for the owner, and that is the most the factory allows at once."
expect_call "- #20 (pull request #30, waiting for a person)"
expect_call "- #24 (pull request #34, waiting for a person)"
expect_call "This ticket keeps the \`ready\` label, and its build starts when the owner has merged or closed one of them."
expect_no_call "gh issue edit"
expect_no_place 12

scenario "four pull requests waiting for the owner and two tickets being built leave a place"
github
in_progress 25 26
pulls_are "$(pull 30 feat/20-a-ticket app/claude needs-human)" "$(pull 31 fix/21-b-ticket app/claude needs-human)" \
  "$(pull 32 fix/22-c-ticket app/claude needs-human)" "$(pull 33 fix/23-d-ticket app/claude needs-human)"
start
expect_written true

scenario "a factory pull request that names no ticket takes one of the five places"
github
in_progress 20 21 28 29
pulls_are "$(pull 32 chore/no-ticket)"
start
expect_written false
expect_call "- pull request #32, which names no ticket"
expect_no_call "gh issue edit"

scenario "a factory pull request that names no ticket and waits for the owner takes none of the five places"
github
in_progress 20 21 28 29
pulls_are "$(pull 32 chore/no-ticket app/claude needs-human)"
start
expect_written true

scenario "a person's pull requests take no place"
github
in_progress 20 21 28 29
pulls_are "$(pull 40 feat/40-mine ada)" "$(pull 41 feat/41-mine ada)"
start
expect_written true

scenario "a ticket already in-progress is refused and keeps its labels: only ready comes off"
github
in_progress 12
start
expect_status 0
expect_written false
expect_output "not started: issue #12 is already in flight: #12 (being built)"
[ "$(grep -c '^gh issue edit' "$T/calls")" -eq 1 ] || fail "expected one label change and no more"
expect_call "gh issue edit 12 --remove-label ready"
expect_no_call "needs-human"
expect_place 12

scenario "with no pull request to show where it is, it is told how to free a place no build holds"
github
in_progress 12
start
expect_call "gh issue comment 12 --body Not started again: this ticket is labelled \`in-progress\`"
expect_call "If no build of it is running, take \`in-progress\` off and add the \`ready\` label again."

scenario "a draft is no pull request ready for review: a ticket in-progress beside its draft is told the same"
github
in_progress 12
pulls_are "$(pull 130 feat/12-a-ticket app/claude "" true)"
start
expect_written false
expect_output "not started: issue #12 is already in flight: #12 (being built, in draft pull request #130)"
expect_call "gh issue comment 12 --body Not started again: this ticket is labelled \`in-progress\`"
expect_place 12

scenario "a ticket whose build was cut short, leaving only a draft, is built again"
github
pulls_are "$(pull 130 feat/12-a-ticket app/claude needs-human true)"
start
expect_status 0
expect_written true
expect_call "gh issue edit 12 --remove-label ready --remove-label needs-human --add-label in-progress"
expect_no_call "gh issue comment"
expect_place 12

scenario "another ticket's unfinished draft still takes a place"
github
in_progress 20 21 28 29
pulls_are "$(pull 131 feat/22-other-ticket app/claude needs-human true)"
start
expect_written false
expect_call "- #22 (draft pull request #131, left unfinished)"
expect_no_place 12

scenario "another ticket's draft, cut short and waiting with ready, takes no place: beside four being built the build starts"
github
in_progress 20 21 28 29
pulls_are "$(pull 131 feat/22-other-ticket app/claude "" true)"
wait_with_ready 12 22
start 12 workflow_dispatch
expect_status 0
expect_written true
expect_place 12

scenario "stops, with ready left on, when a ticket in-progress cannot be told why it was refused"
github
in_progress 12
echo "issue comment" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "already in flight and was not started again, but it could not be told so"
expect_no_call "gh issue edit"

scenario "a ticket whose pull request is open is refused the same way, in-progress or not"
github
pulls_are "$(pull 31 fix/12-a-ticket app/claude needs-human)"
start
expect_written false
expect_output "issue #12 is already in flight: #12 (pull request #31, waiting for a person)"
[ "$(grep -c '^gh issue edit' "$T/calls")" -eq 1 ] || fail "expected one label change and no more"
expect_call "gh issue edit 12 --remove-label ready"
expect_no_call "gh issue comment"

scenario "a ticket already in flight is refused as that, not as a sixth, when the places are full"
github
in_progress 12 20 21 28 29
start
expect_written false
expect_no_call "tickets are being built"

scenario "#12 is not #112 or #1: their being in flight does not refuse it"
github
in_progress 112 1
start
expect_written true

scenario "two tickets labelled at the same moment do not both take the last place: the later one steps back and waits"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 12 13
start
expect_status 0
expect_written false
expect_call "gh issue edit 12 --remove-label in-progress --add-label ready"
expect_call "gh issue comment 12 --body Waiting: 5 tickets are being built or checked, and that is the most the factory allows at once."
expect_call "- #13 (being built)"
expect_call "Another ticket asked for the last place at the same moment as this one, and took it."
expect_no_place 12

scenario "the earlier of the two keeps the last place: they do not both step back"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 13 12
start
expect_status 0
expect_written true
expect_no_call "gh issue comment"
expect_no_call "--remove-label in-progress"
expect_place 12

scenario "of those labelled together the one that takes the fifth place keeps it and the next waits"
github
in_progress 10 11 28 29
echo 13 > "$T/rival"
took_places 14 13 12 11 10
start
expect_written true
github
in_progress 10 11 9 28 29
echo 13 > "$T/rival"
took_places 14 13 12 9 11 10
start
expect_written false
expect_no_place 12

scenario "a later ticket whose build was cut short at a draft held no place before either: the earlier one keeps the last place"
github
in_progress 20 28 29
pulls_are "$(pull 131 feat/13-other-ticket app/claude "" true)"
wait_with_ready 12 13
echo "13 21" > "$T/rival"
took_places 13 12 21
start
expect_status 0
expect_written true
expect_no_call "gh issue comment"
expect_place 12

scenario "an earlier ticket being built in its draft keeps its place: the later one steps back"
github
in_progress 20 28 29
pulls_are "$(pull 131 feat/13-other-ticket app/claude "" true)"
wait_with_ready 12 13
echo "13 21" > "$T/rival"
took_places 12 13 21
start
expect_written false
expect_call "- #13 (being built, in draft pull request #131)"
expect_no_place 12

scenario "steps back when the list of events does not hold its own label: it cannot show it was first"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 13
start
expect_written false
expect_no_place 12

scenario "a waiting ticket that loses the last place at the same moment waits on with ready, and is not told twice"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 12 13
start 12 workflow_dispatch
expect_status 0
expect_written false
expect_call "gh issue edit 12 --remove-label in-progress --add-label ready"
expect_no_call "gh issue comment"

scenario "gives its place back when which ticket was first cannot be read"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
echo "api repos/{owner}/{repo}/issues/events" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "which took it first could not be read from GitHub. Its place was given back"
expect_no_place 12

scenario "says so when the labels of a ticket that stepped back cannot be put back"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 12 13
echo "issue edit" > "$T/after"
start
expect_status 1
expect_written false
expect_output "it holds a place with no build until in-progress is removed by hand"

scenario "stops when a ticket that stepped back cannot be told it waits"
github
in_progress 20 21 28 29
echo 13 > "$T/rival"
took_places 12 13
echo "issue comment" > "$T/after"
start
expect_status 1
expect_written false
expect_output "Its place was given back, and it is started when a place frees"
expect_no_place 12

scenario "two tickets labelled at the same moment both start when there is a place for each"
github
in_progress 20 28 29
echo 13 > "$T/rival"
start
expect_written true
expect_place 12

scenario "labelled while another waits beside one free place, it waits with a comment and the waiting ticket is started"
github
in_progress 20 21 28 29
wait_with_ready 12 5
start
expect_status 0
expect_written false
expect_call "gh workflow run implement.yml -f issue=5"
[ "$(grep -c '^gh issue comment' "$T/calls")" -eq 1 ] || fail "expected one comment and no more"
expect_call "gh issue comment 12 --body Waiting: a place was free, and it went to a ticket ahead of this one in the queue. This ticket keeps the \`ready\` label, and its build starts when a place frees."
expect_output "not started: the free place went to a ticket ahead of it in the queue, so issue #12 waits with ready until a place frees"
expect_no_call "gh issue edit"
expect_no_place 12

scenario "a ticket whose body says After #20 while #20 is open is not started: start-waiting.sh tells it, and it keeps ready"
github
in_progress 20
echo '[{"number":12,"body":"## Change\nAfter #20\n"}]' > "$T/ready"
echo '[{"number":12},{"number":20}]' > "$T/open"
start
expect_status 0
expect_written false
expect_output "not started: issue #12 comes after a ticket that is still open, so it waits with ready until that ticket closes"
[ "$(grep -c '^gh issue comment' "$T/calls")" -eq 1 ] || fail "expected the ticket to be told once"
expect_call "gh issue comment 12 --body <!-- factory:after 20 -->"
expect_no_call "gh issue edit"
expect_no_place 12

scenario "with a place for each, the waiting ticket is started and the new one takes the other"
github
in_progress 20 28 29
wait_with_ready 12 5
start
expect_status 0
expect_written true
expect_call "gh workflow run implement.yml -f issue=5"
expect_no_call "issue=12"
expect_no_call "gh issue comment"
expect_place 12

scenario "a ticket labelled before the others that carry ready takes the one place, and starts none of them"
github
in_progress 20 21 28 29
wait_with_ready 30 12 31
start
expect_status 0
expect_written true
expect_no_call "gh workflow run"
expect_place 12

scenario "a ticket started when a place freed was given it in order already: the waiting are not read again"
github
in_progress 20 21 28 29
wait_with_ready 12 5
start 12 workflow_dispatch
expect_status 0
expect_written true
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

scenario "stops, with ready left on, when the tickets that wait cannot be read: that is not 'none waits'"
github
wait_with_ready 12 5
echo "api repos/{owner}/{repo}/issues?state=open&labels=ready" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: start-waiting.sh could not settle its turn in the queue, for the reason it gives above. It keeps the ready label"
expect_untouched

scenario "stops, with ready left on, when how long a ticket has waited cannot be read"
github
wait_with_ready 12 5
echo "api repos/{owner}/{repo}/issues/5/events" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "start-waiting.sh could not settle its turn in the queue"
expect_untouched
expect_no_call "gh workflow run"

scenario "takes the place itself when the build of the ticket ahead of it cannot be started"
github
in_progress 20 21 28 29
wait_with_ready 12 5
echo "workflow run implement.yml -f issue=5" > "$T/fail"
start
expect_status 0
expect_written true
expect_output "the build of these waiting tickets could not be started: #5"
expect_no_call "gh issue comment"
expect_place 12

scenario "stops, with ready left on, when a ticket that gave way cannot be told it waits"
github
in_progress 20 21 28 29
wait_with_ready 12 5
echo "issue comment" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "the free place went to a ticket ahead of it in the queue, but it could not be told so. It keeps the ready label"
expect_no_call "gh issue edit"

scenario "while the usage limit holds every agent a build is refused with the reset time, and the ticket keeps ready"
github
limit_holds "$soon"
start
expect_status 0
expect_written false
expect_output "not started: the Claude usage limit holds every agent until $when, so issue #12 waits with ready"
expect_call "gh issue comment 12 --body Waiting: the Claude usage limit covers the whole account, and no agent starts until it resets on $when. This ticket keeps the \`ready\` label, and its build starts after that. If the limit was lifted sooner, run \`gh workflow run resume.yml\`: everything that waits starts at once."
expect_no_call "gh issue edit"
expect_no_call "gh workflow run implement.yml"
expect_no_place 12

scenario "a ticket the waiting were started from is refused the same way, and is not told again"
github
limit_holds "$soon"
start 12 workflow_dispatch
expect_status 0
expect_written false
expect_output "the Claude usage limit holds every agent until $when"
expect_untouched

scenario "the same ticket is started once the reset time has passed"
github
limit_holds "$past"
start
expect_status 0
expect_written true
expect_call "gh issue edit 12 --remove-label ready --remove-label needs-human --add-label in-progress"
expect_no_call "gh issue comment"
expect_place 12

scenario "a ticket flagged for a person is started when no limit holds"
github
echo '{"labels":[{"name":"ready"},{"name":"needs-human"}]}' > "$T/labels"
start
expect_status 0
expect_written true

scenario "stops, with ready left on, when the hold cannot be read: that is not 'no limit'"
github
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: whether the Claude usage limit holds every agent could not be read from GitHub. It keeps the ready label"
expect_untouched

scenario "stops, with ready left on, when a ticket the limit holds cannot be told so"
github
limit_holds "$soon"
echo "issue comment" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "because the Claude usage limit holds every agent until $when, but it could not be told so. It keeps the ready label"
expect_no_call "gh issue edit"

scenario "stops, with ready left on, when the ticket's labels cannot be read"
github
echo "issue view" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: its labels could not be read from GitHub"
expect_untouched

scenario "when GitHub cannot be reached, nothing starts and the message says why"
github
in_progress 20
echo "api repos/{owner}/{repo}/issues?state=open&labels=in-progress" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "Issue #12 was not started: what is in flight could not be read from GitHub"
expect_untouched

scenario "the same when only the pull requests cannot be read: two in flight is not known"
github
in_progress 20
echo "pr list" > "$T/fail"
start
expect_status 1
expect_written false
expect_untouched

scenario "stops when the ticket cannot be labelled in-progress"
github
echo "issue edit" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "it could not be labelled in-progress"
expect_no_place 12

scenario "gives its place back when the second look fails: no ticket is left in-progress with no build"
github
echo "api repos/{owner}/{repo}/issues?state=open&labels=in-progress" > "$T/after"
start
expect_status 1
expect_written false
expect_output "could not be read from GitHub a second time. Its place was given back"
expect_call "gh issue edit 12 --remove-label in-progress"
expect_no_place 12

scenario "says so when the place cannot be given back"
github
printf 'api repos/{owner}/{repo}/issues?state=open&labels=in-progress\nissue edit\n' > "$T/after"
start
expect_status 1
expect_written false
expect_output "it holds a place with no build until the label is removed by hand"

scenario "stops, with ready left on, when a sixth ticket cannot be told that it waits"
github
in_progress 20 21 22 28 29
echo "issue comment" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "it could not be told so"
expect_no_call "gh issue edit"

scenario "stops when ready cannot be taken off a refused ticket"
github
in_progress 12
echo "issue edit" > "$T/fail"
start
expect_status 1
expect_written false
expect_output "the ready label could not be taken off it"

scenario "refuses anything that is not an issue number, and calls nothing"
github
start "12 --add-label deployed"
expect_status 1
expect_written false
expect_output "is not an issue number"
expect_no_call "gh "

# A change to either side must fail here: implement.yml skips a refused build's steps on what this script writes.
scenario "implement.yml runs it first, and every step after it is skipped for a ticket refused a place"
workflow="$root/factory/workflows/implement.yml"
grep -qF 'run: factory/scripts/start-build.sh "$ISSUE"' "$workflow" || fail "implement.yml does not run start-build.sh"
# A step with no condition would run for a refused ticket, and one that fails would turn the run red (decisions T64f).
unguarded() {
  awk -v needs="steps.place.outputs.start == 'true'" '
    function check() { if (after && step != "" && !guarded) print step }
    /^      - / { check(); if (placed) after = 1; step = $0; sub(/^      - (name: )?/, "", step); guarded = 0 }
    /^        id: place$/ { placed = 1 }
    /^        if: / && index($0, needs) { guarded = 1 }
    # The run of a refused build is green, so a step for a failed or cancelled job does not run in it (decisions A20).
    /^        if: (cancelled\(\)$|steps\.trusted\.outcome != \047failure\047 && \(failure\(\) \|\| \(cancelled\(\) && )/ { guarded = 1 }
    END { check(); if (!after) print "(no step follows the one with id: place)" }' "$1"
}
unguarded_steps=$(unguarded "$workflow")
[ -z "$unguarded_steps" ] || fail "implement.yml has steps that would run for a ticket refused a place: $unguarded_steps"
grep -v "if: steps.place.outputs.start == 'true'$" "$workflow" > "$T/unguarded.yml"
[ "$(unguarded "$T/unguarded.yml" | head -n 1)" = "Validate the ticket against its template" ] \
  || fail "a step after the place with no condition on it was not found"
[ "$(grep -n 'start-build.sh' "$workflow" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'check-ticket.sh' "$workflow" | head -n 1 | cut -d: -f1)" ] \
  || fail "implement.yml validates the ticket before it has a place"
