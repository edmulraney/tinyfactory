#!/usr/bin/env bash
# Tests for factory/scripts/start-waiting.sh, which starts the tickets that wait with `ready` when a place is free.
. "$(dirname "$0")/helpers.sh"

# $T/ready holds the open issues labelled ready, $T/issues and $T/pulls what in-flight.sh reads.
# $T/search holds what GitHub's search answers, which names a label for seconds after it comes off (decisions T331).
# $T/since-<n> holds the id of the event that labelled ticket <n> ready; $T/fail lists the gh calls that fail.
# $T/boards holds the owner's boards and $T/cards the cards of board #4, top first: only the board token is given them.
# $T/open holds every open issue and pull request, and $T/comments-<n> the comments on ticket <n>.
github() {
  echo '[]' > "$T/ready"
  echo '[]' > "$T/open"
  echo '[]' > "$T/issues"
  echo '[]' > "$T/pulls"
  echo '[]' > "$T/search"
  : > "$T/fail"
  echo '[{"number":3,"title":"other","closed":false},{"number":9,"title":"myapp","closed":true},{"number":4,"title":"myapp","closed":false}]' > "$T/boards"
  echo '[]' > "$T/cards"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100 --paginate --jq "*) json "$(cat "$T/ready")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "issue list --state open --label in-progress "*) cat "$T/search" ;;
      "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") cat "$T/pulls" ;;
      "api repos/{owner}/{repo}/issues/"*"/events?per_page=100 --paginate --jq "*)
        n=${2#*/issues/}; n=${n%/events*}
        # No ready event is listed yet for a ticket that was given none.
        [ -f "$T/since-$n" ] || { json "[{\"id\":99999,\"event\":\"labeled\",\"label\":{\"name\":\"factory\"}}]" "$@"; exit; }
        # Labelled ready once before, taken off, and labelled again: the last time counts.
        json "[{\"id\":1,\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}},{\"id\":2,\"event\":\"unlabeled\",\"label\":{\"name\":\"ready\"}},
               {\"id\":$(cat "$T/since-$n"),\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}},{\"id\":99999,\"event\":\"labeled\",\"label\":{\"name\":\"factory\"}}]" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --jq "*) json "$(cat "$T/open")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*)
        n=${2#*/issues/}; n=${n%/comments*}
        json "$(cat "$T/comments-$n" 2>/dev/null || echo "[]")" "$@" ;;
      # A ticket the list of ready does not hold yet.
      "api repos/{owner}/{repo}/issues/"*" --jq "*) json "$(cat "$T/unlisted")" "$@" ;;
      "issue comment "*)
        jq -cn --arg body "$5" "[{id: 7, body: \$body}]" > "$T/comments-$3" ;;
      "workflow run implement.yml -f issue="*) [ "$GH_TOKEN" = workflow-token ] ;;
      "api graphql "*)
        [ "$GH_TOKEN" = board-token ] || { echo "gh: Resource not accessible by integration" >&2; exit 1; }
        case "$*" in
          "api graphql --paginate -f owner=owner -f query="*"projectsV2(first: 100, after: \$endCursor)"*)
            json "{\"data\":{\"user\":{\"projectsV2\":{\"nodes\":$(cat "$T/boards")}}}}" "$@" ;;
          "api graphql --paginate -f owner=owner -F number=4 -f query="*"items(first: 100, after: \$endCursor, orderBy: {field: POSITION, direction: ASC})"*)
            json "{\"data\":{\"user\":{\"projectV2\":{\"items\":{\"nodes\":$(cat "$T/cards")}}}}}" "$@" ;;
          *) echo "unexpected call: gh $*" >&2; exit 1 ;;
        esac ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# waits <number> <event id>: a ticket labelled ready by that event; GitHub lists the newest ticket first.
waits() {
  echo "$2" > "$T/since-$1"
  jq -c --argjson n "$1" '[{number: $n}] + .' "$T/ready" > "$T/ready.new" && mv "$T/ready.new" "$T/ready"
}
# after <ticket> <number>...: the waiting ticket's body has a line `After #<number>` for each, as a web form sends it.
after() {
  local ticket="$1" body=$'## Change\r\n\r\nSay which format the export gives. After #77 it would be wrong.\r\n'
  shift
  body+=$(printf 'After #%s\r\n' "$@")
  jq -c --argjson n "$ticket" --arg body "$body" 'map(if .number == $n then .body = $body else . end)' "$T/ready" > "$T/ready.new" \
    && mv "$T/ready.new" "$T/ready"
}
# open_are <number>...: every open issue and pull request, the waiting tickets among them.
open_are() { printf '{"number":%s}\n' "$@" | jq -cs . > "$T/open"; }
# told <ticket> <number>: the ticket was told that it waits for that one.
told() { jq -cn --arg body "<!-- factory:after $2 -->Waiting: this ticket's body says \`After #$2\`." '[{id: 5, body: "Waiting: 3 tickets are in flight."}, {id: 6, body: $body}]' > "$T/comments-$1"; }
in_progress() { printf '{"number":%s}\n' "$@" | jq -cs . > "$T/issues"; }
# pull <number> <branch> [draft]: one open pull request the factory opened, as gh prints it.
pull() { echo "{\"number\":$1,\"headRefName\":\"$2\",\"author\":{\"login\":\"app/claude\"},\"labels\":[],\"isDraft\":${3:-false}}"; }
pulls_are() { printf '%s\n' "$@" | jq -cs . > "$T/pulls"; }
# start [issue]: with an issue, as start-build.sh asks for the ticket it is about to build.
start() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/start-waiting.sh" "$@"; }
started() { grep -c '^gh workflow run' "$T/calls" || true; }
# card <number> [column] [repo]: the next card down the board, a ticket of this repo in Backlog unless said.
card() {
  jq -c --argjson n "$1" --arg column "${2:-Backlog}" --arg repo "${3:-owner/myapp}" \
    '. + [{status: {name: $column}, content: {number: $n, repository: {nameWithOwner: $repo}}}]' "$T/cards" > "$T/cards.new" \
    && mv "$T/cards.new" "$T/cards"
}
# start_with_board [issue]: as a workflow given the BOARD_TOKEN secret runs it.
start_with_board() {
  run env GH_TOKEN=workflow-token BOARD_TOKEN=board-token GITHUB_REPOSITORY=owner/myapp "$scripts/start-waiting.sh" "$@"
}
# builds: the tickets whose builds were started, in order.
builds() { sed -n 's/^gh workflow run implement.yml -f issue=//p' "$T/calls" | tr '\n' ' '; }

scenario "with nothing waiting it asks GitHub one thing and starts nothing"
github
in_progress 20
start
expect_status 0
expect_output "no ticket waits with ready: nothing was started"
[ "$(wc -l < "$T/calls")" -eq 1 ] || fail "expected one call to GitHub"

scenario "a merge that frees one place starts the ticket that has carried ready longest, and only that one"
github
in_progress 20 21
waits 30 700
waits 31 500
waits 32 600
start
expect_status 0
expect_call "gh workflow run implement.yml -f issue=31"
[ "$(started)" -eq 1 ] || fail "expected one build to be started, got $(started)"
expect_output "started the build of issue #31, which waited with ready"
expect_output "The board's order was not used: this run holds no BOARD_TOKEN. The waiting tickets are started longest with ready first."
expect_no_call "api graphql"

scenario "two free places start the two that waited longest, the longest first"
github
in_progress 20
waits 30 700
waits 31 500
waits 32 600
start
expect_status 0
[ "$(grep '^gh workflow run' "$T/calls" | tr '\n' ' ')" = "gh workflow run implement.yml -f issue=31 gh workflow run implement.yml -f issue=32 " ] \
  || fail "expected #31 then #32 to be started, and not #30"

scenario "with three in flight nothing is started, and no ticket is asked how long it has waited"
github
in_progress 20 21
pulls_are "$(pull 40 feat/22-a-ticket)"
waits 30 700
start
expect_status 0
expect_output "3 tickets are being built or checked, so no waiting ticket was started"
expect_no_call "gh workflow run"
expect_no_call "/events"

scenario "two pull requests waiting for the owner hold no place a build needs: beside one ticket being built, two that wait are started"
github
in_progress 20
pulls_are "$(pull 41 feat/21-a-ticket | jq -c '.labels = [{name: "needs-human"}]')" "$(pull 42 feat/22-b-ticket | jq -c '.labels = [{name: "needs-human"}]')"
waits 30 700
waits 31 500
waits 32 600
start
expect_status 0
[ "$(builds)" = "31 32 " ] || fail "expected #31 then #32 to be started, and not #30: got $(builds)"

scenario "with five pull requests waiting for the owner nothing is started, and it says that is why"
github
pulls_are "$(for n in 1 2 3 4 5; do pull "4$n" "feat/2$n-a-ticket" | jq -c '.labels = [{name: "needs-human"}]'; done)"
waits 30 700
start
expect_status 0
expect_output "5 pull requests wait for the owner, so no waiting ticket was started"
expect_no_call "gh workflow run"

scenario "a merged ticket the search still names takes no place: with two others in flight the waiting ticket is started"
github
in_progress 20 21
echo '[{"number":20},{"number":21},{"number":22}]' > "$T/search"
waits 30 700
start
expect_status 0
[ "$(builds)" = "30 " ] || fail "expected #30 alone to be started, got: $(builds)"

scenario "the ticket ship.sh has just merged holds no place though GitHub still lists it as open and in progress"
github
in_progress 20 21 22
waits 30 700
start --closed 22
expect_status 0
[ "$(builds)" = "30 " ] || fail "expected #30 alone to be started, got: $(builds)"

scenario "the ticket ship.sh has just merged holds no place though GitHub still lists its pull request as open"
github
in_progress 20 21
pulls_are "$(pull 40 feat/22-a-ticket)"
waits 30 700
start --closed 22
expect_status 0
[ "$(builds)" = "30 " ] || fail "expected #30 alone to be started, got: $(builds)"

scenario "the merged ticket frees one place and no more: with three others in flight nothing is started"
github
in_progress 20 21 22 23
waits 30 700
start --closed 22
expect_status 0
expect_output "3 tickets are being built or checked, so no waiting ticket was started"
expect_no_call "gh workflow run"

scenario "a ticket in flight that carries ready is not started: start-build.sh answers it"
github
in_progress 30
pulls_are "$(pull 41 feat/31-a-ticket)"
waits 30 500
waits 31 600
start
expect_status 0
expect_output "every ticket labelled ready is in flight: nothing was started"
expect_no_call "gh workflow run"

scenario "a ticket whose build was cut short at a draft waits like any other, and its own draft takes no place from it"
github
in_progress 20 21
pulls_are "$(pull 42 feat/30-a-ticket true)"
waits 30 500
waits 31 400
start
expect_status 0
expect_call "gh workflow run implement.yml -f issue=30"
expect_no_call "issue=31"

scenario "with only a draft left unfinished in flight, the ticket that waits is started"
github
pulls_are "$(pull 42 feat/30-a-ticket true)"
waits 31 500
start
expect_status 0
expect_call "gh workflow run implement.yml -f issue=31"

scenario "asked for a ticket that waits alone, it starts nothing and says the ticket has a place"
github
in_progress 20
waits 30 700
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
expect_no_call "gh workflow run"

scenario "asked for a ticket behind another, it starts the other and exits 3: no place was left"
github
in_progress 20 21
waits 30 700
waits 31 500
start 30
expect_status 3
expect_call "gh workflow run implement.yml -f issue=31"
expect_no_call "issue=30"
expect_no_output "issue #30 takes a place"

scenario "asked for the ticket that waited longest, it gives it the place and starts none behind it: each has its own run"
github
in_progress 20
waits 30 500
waits 31 600
waits 32 700
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
expect_no_call "gh workflow run"

scenario "asked for a ticket between two others with places for all, it starts the one ahead and not the one behind"
github
waits 30 600
waits 31 500
waits 32 700
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
[ "$(grep '^gh workflow run' "$T/calls")" = "gh workflow run implement.yml -f issue=31" ] || fail "expected #31 alone to be started"

scenario "asked for a ticket the list of ready does not hold yet, it still gives it its turn"
github
in_progress 20 21
echo 900 > "$T/since-30"
echo '{"number":30,"body":null}' > "$T/unlisted"
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"

scenario "asked for a ticket whose ready event is not listed yet, it starts the other that waits and exits 3"
github
in_progress 20 21
waits 31 500
start 30
expect_status 3
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"
expect_no_output "issue #30 takes a place"

scenario "asked for a ticket, another whose ready event is not listed keeps its place ahead"
github
in_progress 20 21
waits 30 700
jq -c '[{number: 31}] + .' "$T/ready" > "$T/ready.new" && mv "$T/ready.new" "$T/ready"
start 30
expect_status 3
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "asked for a ticket with three in flight, it exits 3"
github
in_progress 20 21 22
waits 30 700
start 30
expect_status 3
expect_output "3 tickets are being built or checked, so no waiting ticket was started"

scenario "asked for a ticket already in flight, it exits 3"
github
in_progress 30
waits 30 700
start 30
expect_status 3
expect_output "every ticket labelled ready is in flight"

scenario "asked for a ticket, a build that cannot be started gives the ticket the place and does not fail it"
github
in_progress 20 21
waits 30 700
waits 31 500
echo "workflow run implement.yml -f issue=31" > "$T/fail"
start 30
expect_status 0
expect_output "the build of these waiting tickets could not be started: #31"
expect_output "issue #30 takes a place in its turn"

scenario "a pull request labelled ready is no ticket"
github
echo '[{"number":50,"pull_request":{}}]' > "$T/ready"
start
expect_status 0
expect_output "no ticket waits with ready"
expect_no_call "gh workflow run"

scenario "when the tickets labelled ready cannot be read, it fails and starts nothing"
github
waits 30 500
echo "api repos/{owner}/{repo}/issues?state=open" > "$T/fail"
start
expect_status 1
expect_output "No waiting ticket was started: the tickets labelled ready could not be read from GitHub."
expect_no_call "gh workflow run"

scenario "when what is in flight cannot be read, it fails and starts nothing: three in flight is not known"
github
waits 30 500
echo "pr list" > "$T/fail"
start
expect_status 1
expect_output "No waiting ticket was started: what is in flight could not be read from GitHub."
expect_no_call "gh workflow run"

scenario "when how long a ticket has waited cannot be read, it fails and starts nothing: the newest is not started as the oldest"
github
waits 30 500
waits 31 400
echo "api repos/{owner}/{repo}/issues/31/events" > "$T/fail"
start
expect_status 1
expect_output "when issue #31 was labelled ready could not be read from GitHub"
expect_no_call "gh workflow run"

scenario "a build that cannot be started fails it, and the place goes to the next that waits"
github
in_progress 20 21
waits 30 500
waits 31 600
echo "workflow run implement.yml -f issue=30" > "$T/fail"
start
expect_status 1
expect_output "the build of these waiting tickets could not be started: #30. Each keeps the ready label"
expect_output "started the build of issue #31"

scenario "the higher card in the board's Backlog column is started first, whichever was labelled first"
github
in_progress 20 21
waits 30 500
waits 31 600
waits 32 700
card 32
card 30
card 31
start_with_board
expect_status 0
[ "$(builds)" = "32 " ] || fail "expected #32 alone to be started, got: $(builds)"
expect_output "BOARD_TOKEN read the ticket numbers of 3 cards of board #4"
expect_no_output "The board's order was not used"
# The board places all three, so none is asked how long it has waited.
expect_no_call "/events"

scenario "two free places go to the two highest cards, top first"
github
in_progress 20
waits 30 500
waits 31 600
waits 32 700
card 31
card 32
card 30
start_with_board
expect_status 0
[ "$(builds)" = "31 32 " ] || fail "expected #31 then #32 to be started, got: $(builds)"

scenario "a card without ready is never started, wherever it sits, nor is another repo's card with a waiting ticket's number"
github
in_progress 20
waits 30 500
waits 31 600
card 40
card 31 Backlog owner/other
card 30
card 31
start_with_board
expect_status 0
[ "$(builds)" = "30 31 " ] || fail "expected #30 then #31 to be started, got: $(builds)"

scenario "a waiting ticket outside the Backlog column, or on no card, follows those in it, longest with ready first"
github
waits 30 500
waits 31 400
waits 32 300
card 31 "In progress"
card 30
start_with_board
expect_status 0
[ "$(builds)" = "30 32 31 " ] || fail "expected #30, then #32 and #31 as labelled, got: $(builds)"
expect_call "issues/31/events"
expect_no_call "issues/30/events"

scenario "with three in flight the board is not read"
github
in_progress 20 21 22
waits 30 700
card 30
start_with_board
expect_status 0
expect_output "3 tickets are being built or checked, so no waiting ticket was started"
expect_no_call "api graphql"

scenario "asked for a newly labelled ticket at the top of Backlog, it gives it the place ahead of one that waited longer"
github
in_progress 20 21
waits 30 700
waits 31 500
card 30
card 31
start_with_board 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
expect_no_call "gh workflow run"

scenario "asked for a ticket below another in Backlog, it starts the other and exits 3, though the other was labelled later"
github
in_progress 20 21
waits 30 500
waits 31 700
card 31
card 30
start_with_board 30
expect_status 3
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "when the owner's boards cannot be read, it says so and starts the ticket longest with ready"
github
in_progress 20 21
waits 30 700
waits 31 500
card 30
card 31
echo "api graphql --paginate -f owner=owner -f query=" > "$T/fail"
start_with_board
expect_status 0
expect_output "The board's order was not used: owner's boards could not be read from GitHub. The waiting tickets are started longest with ready first."
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "when the board's cards cannot be read, it says so and starts the ticket longest with ready"
github
in_progress 20 21
waits 30 700
waits 31 500
card 30
card 31
echo "api graphql --paginate -f owner=owner -F number=4" > "$T/fail"
start_with_board
expect_status 0
expect_output "The board's order was not used: the cards of board #4 could not be read from GitHub."
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "when the owner has no open board named as the repo is, it says so and uses the order of the labels"
github
in_progress 20 21
waits 30 700
waits 31 500
echo '[{"number":9,"title":"myapp","closed":true}]' > "$T/boards"
start_with_board
expect_status 0
expect_output "The board's order was not used: owner has no open board called myapp."
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "when the token is shown no ticket number on the cards, it says how many cards it read and uses the order of the labels"
github
in_progress 20 21
waits 30 700
waits 31 500
echo '[{"status":{"name":"Backlog"},"content":null},{"status":{"name":"Backlog"},"content":{}}]' > "$T/cards"
start_with_board
expect_status 0
expect_output "The board's order was not used: BOARD_TOKEN read the 2 cards of board #4 and the ticket number of none."
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "when the token is shown no ticket number, it prints the type, content and fields of the first three cards"
github
waits 30 500
field() { echo "{\"field\":{\"name\":\"$1\"},$2}"; }
# empty_card <type> <content> [field]...: a card whose content names no ticket, as GitHub returns it.
empty_card() {
  local type="$1" content="$2"
  shift 2
  jq -c --arg type "$type" --argjson content "$content" --argjson fields "$(printf '%s\n' "$@" | jq -cs .)" \
    '. + [{status: null, content: $content, type: $type, fieldValues: {nodes: $fields}}]' "$T/cards" > "$T/cards.new" \
    && mv "$T/cards.new" "$T/cards"
}
empty_card ISSUE '{}' "$(field Title '"text":"Export forecast as CSV"')" "$(field Status '"name":"Backlog"')" \
  "$(field Repository '"repository":{"nameWithOwner":"owner/myapp"}')" "$(field Labels '"labels":{"nodes":[{"name":"ready"},{"name":"factory"}]}')" '{}'
empty_card REDACTED null
empty_card DRAFT_ISSUE '{}' "$(field Estimate '"number":3')"
empty_card ISSUE '{}' "$(field Title '"text":"The fourth card"')"
start_with_board
[ "$(builds)" = "30 " ] || fail "expected the waiting ticket to be started, got: $(builds)"
expect_output "BOARD_TOKEN read the 4 cards of board #4 and the ticket number of none."
expect_output "card 1 of the board: type ISSUE, content {}, fields: Title=Export forecast as CSV; Status=Backlog; Repository=owner/myapp; Labels=ready, factory"
expect_output "card 2 of the board: type REDACTED, content null, fields: none"
expect_output "card 3 of the board: type DRAFT_ISSUE, content {}, fields: Estimate=3"
expect_no_output "card 4"
expect_no_output "The fourth card"

scenario "when ticket numbers are read, no card is printed"
github
waits 30 500
card 30
start_with_board
[ "$(builds)" = "30 " ] || fail "expected the waiting ticket to be started, got: $(builds)"
expect_no_output "of the board:"

scenario "a card with no column is no Backlog card"
github
in_progress 20 21
waits 30 700
waits 31 500
echo '[{"status":null,"content":{"number":30,"repository":{"nameWithOwner":"owner/myapp"}}}]' > "$T/cards"
card 31
start_with_board
expect_status 0
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"

scenario "a ticket whose body says After #20 is not started while #20 is open: it is told so, and the place goes to the next"
github
in_progress 20 21
waits 30 500
waits 31 600
after 30 20
open_are 20 21 30 31 77
start
expect_status 0
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"
expect_output "issue #30 waits with ready for #20 to close"
expect_call "gh issue comment 30 --body <!-- factory:after 20 -->Waiting: this ticket's body says \`After #20\`, and #20 is still open. This ticket keeps the \`ready\` label, and its build starts when a place next frees after #20 has closed. If #20 is closed by hand, with no pull request merged, take \`ready\` off this ticket and add it again to start the build."
expect_no_call "gh issue edit"

scenario "a ticket already told which ticket it waits for is not told again, and still is not started"
github
in_progress 20
waits 30 500
after 30 20
open_are 20 30
told 30 20
start
expect_status 0
expect_output "no waiting ticket was started"
expect_no_call "gh workflow run"
expect_no_call "gh issue comment"

scenario "once the ticket it names has closed, it is started in its turn"
github
in_progress 21
waits 30 500
waits 31 600
after 30 20
open_are 21 30 31
told 30 20
start
expect_status 0
[ "$(builds)" = "30 31 " ] || fail "expected #30 then #31 to be started, got: $(builds)"
expect_no_call "gh issue comment"

scenario "the ticket ship.sh has just merged counts as closed though GitHub still lists it as open"
github
in_progress 21
waits 30 500
waits 31 600
after 30 20
after 31 21
open_are 20 21 30 31
start --closed 20
expect_status 0
[ "$(builds)" = "30 " ] || fail "expected #30 alone to be started, got: $(builds)"
expect_no_call "gh issue comment 30"
expect_call "gh issue comment 31 --body <!-- factory:after 21 -->"

scenario "a ticket that names two waits for the one still open, and is told of it though it was told of the other"
github
waits 30 500
after 30 20 21
open_are 21 30
told 30 20
start
expect_status 0
expect_no_call "gh workflow run"
expect_call "gh issue comment 30 --body <!-- factory:after 21 -->"

scenario "a ticket that waits for another takes no place: one free place goes to the first ticket that may start, and only to it"
github
in_progress 20 21
waits 30 500
waits 31 600
waits 32 700
waits 33 800
after 30 20
after 31 21
open_are 20 21 30 31 32 33
start
expect_status 0
[ "$(builds)" = "32 " ] || fail "expected #32 alone to be started, got: $(builds)"
expect_call "gh issue comment 30"
expect_call "gh issue comment 31"
[ "$(grep -c 'issues?state=open&per_page' "$T/calls")" -eq 1 ] || fail "expected the open tickets to be read once"

# ship.sh runs it within seconds of a merge, and GitHub closes the merged ticket a little later (decisions T339b).
scenario "the open tickets are read after the board, as late as a ticket can be held back"
github
waits 30 500
after 30 20
open_are 20 30
card 30
start_with_board
expect_status 0
[ "$(grep -n -e 'api graphql' -e 'issues?state=open&per_page' "$T/calls" | tail -n 1 | grep -c 'issues?state=open&per_page')" -eq 1 ] \
  || fail "expected the open tickets to be read after the board"

scenario "a body that only mentions another ticket holds nothing back, and the open tickets are not read"
github
waits 30 500
jq -c '.[0].body = "## Change\n<!-- An optional line `After #<n>` -->\nBuild it After #20\nafter #20\nAfter #20 merges\n"' "$T/ready" > "$T/ready.new" && mv "$T/ready.new" "$T/ready"
open_are 20 30
start
expect_status 0
[ "$(builds)" = "30 " ] || fail "expected #30 to be started, got: $(builds)"
expect_no_call "issues?state=open&per_page"

scenario "with three in flight a ticket that waits for another is not told so: it is told when it would have started"
github
in_progress 20 21 22
waits 30 500
after 30 20
open_are 20 21 22 30
start
expect_status 0
expect_no_call "issues?state=open&per_page"
expect_no_call "gh issue comment"

scenario "when the open tickets cannot be read, it fails and does not start the ticket that names another"
github
waits 30 500
after 30 20
echo "api repos/{owner}/{repo}/issues?state=open&per_page" > "$T/fail"
start
expect_status 1
expect_output "Issue #30 was not started: whether the ticket it comes after is still open could not be read from GitHub."
expect_no_call "gh workflow run"
expect_no_call "gh issue comment"

scenario "when a ticket's comments cannot be read, it is not told twice or started, the next is started, and it fails"
github
in_progress 20 21
waits 30 500
waits 31 600
after 30 20
open_are 20 21 30 31
echo "api repos/{owner}/{repo}/issues/30/comments" > "$T/fail"
start
expect_status 1
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"
expect_no_call "gh issue comment"
expect_output "These tickets wait for the ticket their body names to close, and could not be told so: #30. Each keeps the ready label."

scenario "when a ticket cannot be told that it waits, it is not started, the next is started, and it fails"
github
in_progress 20 21
waits 30 500
waits 31 600
after 30 20
open_are 20 21 30 31
echo "issue comment 30" > "$T/fail"
start
expect_status 1
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"
expect_output "could not be told so: #30."

scenario "asked for a ticket that names an open one, it tells it, exits 4, and starts the ticket ahead and none behind"
github
waits 30 600
waits 31 500
waits 32 700
after 30 20
open_are 20 30 31 32
start 30
expect_status 4
expect_call "gh issue comment 30 --body <!-- factory:after 20 -->"
[ "$(builds)" = "31 " ] || fail "expected #31 alone to be started, got: $(builds)"
expect_no_output "issue #30 takes a place"

scenario "asked for a ticket that names a closed one, it gives it its turn"
github
in_progress 21
waits 30 600
after 30 20
open_are 21 30
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
expect_no_call "gh issue comment"

scenario "asked for a ticket behind one that waits for another, it gives it the place"
github
in_progress 20 21
waits 30 600
waits 31 500
after 31 20
open_are 20 21 30 31
start 30
expect_status 0
expect_output "issue #30 takes a place in its turn"
expect_no_call "gh workflow run"

scenario "asked for a ticket the list of ready does not hold yet, it reads its body and holds it back all the same"
github
echo 900 > "$T/since-30"
printf '{"number":30,"body":"## Change\\nAfter #20\\n"}' > "$T/unlisted"
open_are 20 30
start 30
expect_status 4
expect_call "gh issue comment 30"

scenario "asked for a ticket the list does not hold, whose body cannot be read, it fails and starts nothing"
github
in_progress 20
waits 31 500
echo "api repos/{owner}/{repo}/issues/30 " > "$T/fail"
start 30
expect_status 1
expect_output "No waiting ticket was started: the body of issue #30 could not be read from GitHub."
expect_no_call "gh workflow run"

scenario "asked for a ticket that names an open one and cannot be told so, it fails: exit 4 would say it was told"
github
waits 30 600
after 30 20
open_are 20 30
echo "issue comment 30" > "$T/fail"
start 30
expect_status 1
expect_output "could not be told so: #30."

# A change to either side must fail here: nothing else starts the script when a person closes a pull request.
scenario "start-waiting.yml runs it with main's scripts when a pull request the factory opened is closed"
workflow="$root/factory/workflows/start-waiting.yml"
grep -qF 'run: factory/scripts/start-waiting.sh' "$workflow" || fail "start-waiting.yml does not run start-waiting.sh"
grep -A1 -F 'pull_request_target:' "$workflow" | grep -qxF '    types: [closed]' || fail "start-waiting.yml does not start when a pull request is closed"
grep -qF "if: github.event.pull_request.user.login == 'claude[bot]'" "$workflow" || fail "start-waiting.yml runs for a person's pull request, which held no place"
grep -qF 'ref: ${{ github.event.repository.default_branch }}' "$workflow" || fail "start-waiting.yml runs the pull request's copy of the script"
grep -qF 'actions: write' "$workflow" || fail "start-waiting.yml may not start implement.yml"
grep -qF 'issues: write' "$workflow" || fail "start-waiting.yml may not tell a ticket that it waits for another"
grep -qF '"$script_dir/start-waiting.sh"' "$scripts/ship.sh" || fail "ship.sh does not start a waiting ticket after a merge"

# A step without the secret would use the order of the labels and only say so in its log (decisions T335b).
scenario "each workflow step that can run it is given BOARD_TOKEN"
given() { grep -B8 -F -- "$2" "$root/factory/workflows/$1" | grep -qF 'BOARD_TOKEN: ${{ secrets.BOARD_TOKEN }}' || fail "$1 does not give BOARD_TOKEN to the step that runs: $2"; }
given start-waiting.yml 'run: factory/scripts/start-waiting.sh'
given flag-idle.yml 'run: factory/scripts/flag-idle.sh'
given implement.yml 'run: factory/scripts/start-build.sh'
given implement.yml 'flag-unfinished.sh" build'
given implement.yml 'run: factory/scripts/give-back-place.sh'
given fix.yml 'flag-unfinished.sh" fix'
given ci.yml 'run: factory/scripts/merge-gate.sh'
given approve-merge.yml 'run: factory/scripts/approve-merge.sh'

# A place given back with no pull request closing starts no workflow either (decisions T297a).
scenario "each script that takes a ticket out of flight with no pull request runs it"
for script in flag-unfinished give-back-place flag-idle; do
  grep -qF '"$script_dir/start-waiting.sh"' "$scripts/$script.sh" || fail "$script.sh does not start a waiting ticket when it frees a place"
done
