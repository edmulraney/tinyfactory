#!/usr/bin/env bash
# Starts the build of each ticket that waits with `ready` while a place is free, the top card of Backlog first.
# Usage: start-waiting.sh [--closed <merged issue>]... [issue]
#        With an issue, start-build.sh asks for the ticket it is about to build: in its turn that ticket takes a place
#        and no build is started for it or for any ticket behind it, and exit 3 says that no place was left for it
#        (decisions T323). Exit 4 says that it waits for a ticket its body names, and was told so.
#        A ticket whose body has a line `After #<n>` is not started while issue or pull request #<n> is open: it
#        keeps `ready`, and one comment tells it which ticket it waits for (decisions T339a).
#        --closed names the ticket of a pull request ship.sh has just merged, which counts as closed and holds
#        no place though GitHub may still list it as open and in flight (decisions T339f, T359a).
#        Needs GH_TOKEN (issues: write; pull requests: read; actions: write) and GITHUB_REPOSITORY.
#        BOARD_TOKEN reads the board, which is named as the repo is (decisions T269a, T335a), and is shown each
#        card's title and no ticket number: a Backlog card places the waiting ticket that alone has its title
#        (decisions T523). Without it, or when the board cannot be read, it says so and starts the tickets longest
#        with `ready` first (decisions T335b).
#        A call to GitHub that fails stops it with a message and exit 1; a ticket not started keeps `ready` and waits.
#        A ticket whose build was cut short at a draft, and that finds no place, is told which tickets hold the
#        places (decisions T505b).
#        A ticket that could not be told what it waits for stops nothing: the rest are started, then exit 1
#        (decisions T339c).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
closed=""; nl=$'\n'
while [ "${1:-}" = --closed ]; do closed+="${closed:+$nl}$2"; shift 2; done
mine="${1:-}"
die() { echo "$1" >&2; exit 1; }
# none <message>: nothing was started, which leaves the caller's ticket without a place.
none() { echo "$1"; [ -z "$mine" ] || exit 3; exit 0; }

# A ticket's number, the number of each ticket a line of its body says it comes after (decisions T339a), then a tab
# and its title, which is all of the ticket that its card shows BOARD_TOKEN (decisions T523).
after='"\(.number)" + ([(.body // "") | split("\n")[] | capture("^After #(?<n>[0-9]+)\\s*$").n | " " + .] | join("")) + "\t" + .title'
# Listed: a search would miss a label seconds old. On an idea the label starts Peta, and no build (decisions A611b).
listed=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100" --paginate \
    --jq ".[] | select(.pull_request == null and (any(.labels[]?; .name == \"idea\") | not)) | $after") \
  || die "No waiting ticket was started: the tickets labelled ready could not be read from GitHub."
# The caller's ticket carries ready, as start-build.sh has read, whether or not the list holds it yet.
if [ -n "$mine" ] && ! cut -f1 <<<"$listed" | cut -d' ' -f1 | grep -qxF "$mine"; then
  its=$(gh api "repos/{owner}/{repo}/issues/$mine" --jq "$after") \
    || die "No waiting ticket was started: the body of issue #$mine could not be read from GitHub."
  listed="${listed:+$listed$'\n'}$its"
fi
titles=$(sed -E $'s/^([0-9]+)[^\t]*/\\1/' <<<"$listed")
listed=$(cut -f1 <<<"$listed")
ready=$(cut -d' ' -f1 <<<"$listed")
[ -n "$ready" ] || none "no ticket waits with ready: nothing was started"

# start-build.sh would refuse each build while the Claude usage limit holds every agent (decisions A231b).
# Asked as a job that runs no agent, so a hold of one model starts the builds, and start-build.sh asks for each (decisions A663a).
limit=$(MODEL="" AGENT_MODEL="" "$script_dir/usage-limit.sh" held) \
  || die "No waiting ticket was started: whether the Claude usage limit holds every agent could not be read from GitHub."
[ -z "$limit" ] || none "the Claude usage limit holds every agent until $limit: no waiting ticket was started"

in_flight=$("$script_dir/in-flight.sh") \
  || die "No waiting ticket was started: what is in flight could not be read from GitHub."
# A ticket ship.sh has just merged holds no place (decisions T359a); awk reads them from the environment (H632a).
[ -z "$closed" ] || in_flight=$(CLOSED="$closed" awk 'BEGIN { split(ENVIRON["CLOSED"], list, "\n"); for (i in list) merged[list[i]] } !($1 in merged)' <<<"$in_flight")
# A draft left unfinished is built again from its ticket (decisions T64h); start-build.sh answers any other in flight.
held=$(sed -n '/left unfinished)$/!s/ .*//p' <<<"$in_flight")
waiting=$(grep -vxF -e "$held" <<<"$ready" || true)
[ -n "$waiting" ] || none "every ticket labelled ready is in flight: nothing was started"

# free <ticket>: whether a place is free for it. A build started here is added to $in_flight.
started=0
free() { [ -z "$({ grep -v "^$1 " <<<"$in_flight" || true; } | "$script_dir/in-flight.sh" full)" ]; }

# tell_no_place <ticket>: tells a ticket whose build was cut short, and that no place is left for, which tickets
# hold the places. The factory's last comment on it promised a start, so it is told unless that comment already
# says this (decisions T505b, T563m). It fails when the ticket could not be told.
tell_no_place() {
  local marker="<!-- factory:no-place -->" last taken
  # start-build.sh tells the caller's ticket why it waits.
  [ "$1" != "$mine" ] || return 0
  grep -q "^$1 #$1 (waiting with ready; " <<<"$in_flight" || return 0
  # A marker counts only in the factory's own comment, named in full by the REST list (decisions U563l).
  last=$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate \
      --jq ".[] | select(.user.login == \"github-actions[bot]\") | (.body // \"\") | startswith(\"$marker\")" | tail -n 1) \
    || return 1
  [ "$last" != true ] || return 0
  taken=$({ grep -v "^$1 " <<<"$in_flight" || true; } | "$script_dir/in-flight.sh" full)
  gh issue comment "$1" --body "${marker}Waiting: $(sed -n 1p <<<"$taken"), and that is the most the factory allows at once.

$(sed -n '3,$p' <<<"$taken" | sed -E 's/^[0-9-]+ /- /')

This ticket keeps the \`ready\` label, and the build that was cut short starts again when $(sed -n 2p <<<"$taken")." >/dev/null
}

# No ticket is asked how long it has waited when none could start.
fits="" unplaced=""
while read -r ticket; do
  ! free "$ticket" || fits=yes
done <<<"$waiting"
if [ -z "$fits" ]; then
  while read -r ticket; do
    tell_no_place "$ticket" || unplaced+=" #$ticket"
  done <<<"$waiting"
  [ -z "$unplaced" ] || die "These tickets wait with ready for a place, and could not be told so:$unplaced. Each keeps the ready label and is started when a place next frees."
  none "$("$script_dir/in-flight.sh" full <<<"$in_flight" | sed -n 1p), so no waiting ticket was started"
fi

# backlog: prints the title of each card in the board's Backlog column, top card first, or says why it cannot and fails.
backlog() {
  local owner="${GITHUB_REPOSITORY%/*}" number cards
  [ -n "${BOARD_TOKEN:-}" ] || { echo "this run holds no BOARD_TOKEN"; return 1; }
  # Through the API, as board.sh finds the board (decisions U222).
  number=$(GH_TOKEN="$BOARD_TOKEN" gh api graphql --paginate -f owner="$owner" -f query='
      query($owner: String!, $endCursor: String) {
        user(login: $owner) { projectsV2(first: 100, after: $endCursor) {
          nodes { number title closed }
          pageInfo { hasNextPage endCursor }
        } }
      }' --jq '.data.user.projectsV2.nodes[]' \
    | jq -rs --arg name "${GITHUB_REPOSITORY#*/}" '[.[] | select(.title == $name and (.closed | not)) | .number] | first // ""') \
    || { echo "$owner's boards could not be read from GitHub"; return 1; }
  [ -n "$number" ] || { echo "$owner has no open board called ${GITHUB_REPOSITORY#*/}"; return 1; }
  cards=$(GH_TOKEN="$BOARD_TOKEN" gh api graphql --paginate -f owner="$owner" -F number="$number" -f query='
      query($owner: String!, $number: Int!, $endCursor: String) {
        user(login: $owner) { projectV2(number: $number) {
          items(first: 100, after: $endCursor, orderBy: {field: POSITION, direction: ASC}) {
            nodes {
              status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              title: fieldValueByName(name: "Title") { ... on ProjectV2ItemFieldTextValue { text } }
            }
            pageInfo { hasNextPage endCursor }
          }
        } }
      }' --jq '.data.user.projectV2.items.nodes[]' | jq -cs .) \
    || { echo "the cards of board #$number could not be read from GitHub"; return 1; }
  [ "$cards" = "[]" ] || [ "$(jq 'any(.[]; .title.text)' <<<"$cards")" = true ] \
    || { echo "BOARD_TOKEN read the $(jq length <<<"$cards") cards of board #$number and the title of none"; return 1; }
  jq -r '.[] | select(.status.name == "Backlog") | .title.text // empty' <<<"$cards"
}

# A Backlog card places the waiting ticket that alone has its title, when no other Backlog card has that title
# (decisions T523); the rest follow, longest with ready first (decisions T335c). awk reads the waiting tickets
# from the environment (decisions H632a).
placed=""
if order=$(backlog); then
  placed=$(WAITING="$waiting" awk '
    BEGIN { n = split(ENVIRON["WAITING"], list, "\n"); for (i = 1; i <= n; i++) waits[list[i]] }
    FILENAME == ARGV[1] { if ($1 in waits) { title = substr($0, length($1) + 2); tickets[title]++; number[title] = $1 }; next }
    { cards[$0]++; card[++last] = $0 }
    END { for (i = 1; i <= last; i++) if (cards[card[i]] == 1 && tickets[card[i]] == 1) print number[card[i]] }
  ' <(echo "$titles") <(echo "$order"))
  echo "The board's order was read from the titles of its Backlog cards ($(grep -c . <<<"$order" || true)), which place $(grep -c . <<<"$placed" || true) of the $(grep -c . <<<"$waiting") waiting tickets." >&2
else
  echo "The board's order was not used: $order. The waiting tickets are started longest with ready first." >&2
fi
rest=$(grep -vxF -e "$placed" <<<"$waiting" || true)

# The id of the event that last added ready: GitHub numbers events in the order they happen.
since=""
while read -r ticket; do
  [ -n "$ticket" ] || continue
  at=$(gh api "repos/{owner}/{repo}/issues/$ticket/events?per_page=100" --paginate \
      --jq '.[] | select(.event == "labeled" and .label.name == "ready") | .id') \
    || die "No waiting ticket was started: when issue #$ticket was labelled ready could not be read from GitHub."
  # With no such event listed, the caller's ticket sorts behind every other (decisions T336).
  late=0
  [ -n "$at" ] || [ "$ticket" != "$mine" ] || late=1
  since+="$late $(tail -n 1 <<<"${at:-0}") $ticket"$'\n'
done <<<"$rest"
queue=$(printf '%s\n' "$placed"; sort -k1,1n -k2,2n <<<"$since" | cut -d' ' -f3)

# tell <ticket> <open ticket>: says on the ticket, once for each ticket it waits for, why its build has not started.
# It fails when the ticket could not be told.
tell() {
  local marker="<!-- factory:after $2 -->" told
  told=$(gh api "repos/{owner}/{repo}/issues/$1/comments?per_page=100" --paginate \
      --jq ".[] | select(.user.login == \"github-actions[bot]\" and ((.body // \"\") | startswith(\"$marker\"))) | .id") \
    || return 1
  [ -z "$told" ] || return 0
  gh issue comment "$1" --body "${marker}Waiting: this ticket's body says \`After #$2\`, and #$2 is still open. This ticket keeps the \`ready\` label, and its build starts when a place next frees after #$2 has closed. If #$2 is closed by hand, with no pull request merged, take \`ready\` off this ticket and add it again to start the build." >/dev/null
}

failed="" untold="" turn="" blocked="" open=""
while read -r ticket; do
  [ -n "$ticket" ] || continue
  free "$ticket" || { tell_no_place "$ticket" || unplaced+=" #$ticket"; continue; }
  named=$(sed -n "s/^$ticket //p" <<<"$listed" | tr ' ' '\n')
  if [ -n "$named" ]; then
    # Read here, after the board, and once: GitHub closes a ticket seconds after its pull request merges (decisions T339b).
    [ -n "$open" ] || open=$(gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --paginate --jq '.[].number') \
      || die "Issue #$ticket was not started: whether the ticket it comes after is still open could not be read from GitHub. It keeps the ready label, and no ticket behind it was started."
    first=$(grep -xF -e "$named" <<<"$open" | grep -vxF -m 1 -e "$closed" || true)
    if [ -n "$first" ]; then
      echo "issue #$ticket waits with ready for #$first to close"
      # The ticket waits whether or not it was told, and those behind it are still started (decisions T339c).
      tell "$ticket" "$first" || untold+=" #$ticket"
      [ "$ticket" != "$mine" ] || { blocked=yes; break; }
      continue
    fi
  fi
  # start-build.sh takes ready off as the build takes its place, and refuses a second run of it (decisions T269b).
  if [ "$ticket" = "$mine" ]; then
    started=$((started + 1)) turn=yes
    echo "issue #$ticket takes a place in its turn"
    # No ticket behind it is started: one labelled later has its own run, and the run that freed the place starts
    # the others (decisions T323).
    break
  elif gh workflow run implement.yml -f issue="$ticket" >/dev/null; then
    started=$((started + 1))
    in_flight+=$'\n'"$ticket #$ticket (being built)"
    echo "started the build of issue #$ticket, which waited with ready"
  else
    failed+=" #$ticket"
  fi
done <<<"$queue"

failed="${failed:+A place is free, and the build of these waiting tickets could not be started:$failed. Each keeps the ready label and is started when a place next frees.}"
untold="${untold:+These tickets wait for the ticket their body names to close, and could not be told so:$untold. Each keeps the ready label.}"
unplaced="${unplaced:+These tickets wait with ready for a place, and could not be told so:$unplaced. Each keeps the ready label and is started when a place next frees.}"
untold="$untold${untold:+${unplaced:+ }}$unplaced"
failed="$failed${failed:+${untold:+ }}$untold"
# The caller's ticket takes no place whatever else failed; exit 4 says that every ticket held back was told why.
[ -z "$blocked" ] || { [ -z "$failed" ] || echo "$failed" >&2; [ -z "$untold" ] || exit 1; exit 4; }
# The caller's build goes on with the place it has: stopping it would leave one more ticket waiting beside a free place.
[ -z "$failed" ] || [ -z "$turn" ] || { echo "$failed" >&2; exit 0; }
[ -z "$failed" ] || die "$failed"
[ "$started" -gt 0 ] || echo "no waiting ticket was started"
[ -z "$mine" ] || [ -n "$turn" ] || exit 3
