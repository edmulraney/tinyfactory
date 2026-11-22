#!/usr/bin/env bash
# Tests for factory/scripts/wait-for-ticket.sh: a build that needs another open ticket leaves its own to wait for it.
. "$(dirname "$0")/helpers.sh"

# $T/ticket holds ticket #12 as GitHub has it, and the edits change it; $T/state-20 holds whether #20 is open, $T/body-20 its body.
# $T/posted holds the comments on #12; $T/fail holds the start of each call that should fail, and with $T/no-restore
# the body cannot be put back as it was.
# What start-waiting.sh reads beyond those is as waiting_on_github says.
github() {
  jq -cn --arg body "${1:-$'## Change\r\n\r\nSay which format the export gives.\r\n'}" \
    '{number: 12, title: "Export forecast as CSV", body: $body, labels: [{name: "factory"}, {name: "in-progress"}]}' > "$T/ticket"
  echo open > "$T/state-20"
  printf '## Change\r\n\r\nWrite the seed. After #12 it is read.\r\n' > "$T/body-20"
  : > "$T/fail"
  : > "$T/posted"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    change() { jq -c "${@:2}" "$1" "$T/ticket" > "$T/ticket.new" && mv "$T/ticket.new" "$T/ticket"; }
    case "$*" in
      "api repos/{owner}/{repo}/issues/20 --jq "*)
        needed=$(jq -cn --arg state "$(cat "$T/state-20")" --arg body "$(cat "$T/body-20")" "{state: \$state, body: \$body}")
        json "$needed" "$@" ;;
      "issue view 12 --json body --jq .body") jq -r .body "$T/ticket" ;;
      "issue edit 12 --body "*)
        [ ! -e "$T/no-restore" ] || [[ "$5" == *"After #20" ]] || { echo "gh: could not connect" >&2; exit 1; }
        change ".body = \$body" --arg body "$5" ;;
      "issue edit 12 --add-label ready --remove-label in-progress") change ".labels = .labels - [{name: \"in-progress\"}] + [{name: \"ready\"}]" ;;
      "issue comment 12 --body "*) printf "%s\n" "$5" >> "$T/posted" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100 --paginate --jq "*)
        json "$(jq -c "[select(any(.labels[]; .name == \"ready\"))]" "$T/ticket")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --jq "*)
        json "[{\"number\":12}$([ "$(cat "$T/state-20")" != open ] || echo ",{\"number\":20}")]" "$@" ;;
      *) waiting_on_github "$@" ;;
    esac'
}
wait_for() { run env GH_TOKEN=session-token GITHUB_REPOSITORY=owner/myapp "$scripts/wait-for-ticket.sh" "$@"; }
start_waiting() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/start-waiting.sh"; }
expect_labels() {
  [ "$(jq -r '[.labels[].name] | join(" ")' "$T/ticket")" = "$1" ] || fail "expected the labels $1, got: $(jq -r '[.labels[].name] | join(" ")' "$T/ticket")"
}
expect_body() {
  [ "$(jq -r .body "$T/ticket")" = "$1" ] || fail "expected the body $(printf '%q' "$1"), got: $(jq -r '.body | @sh' "$T/ticket")"
}
expect_unchanged() {
  expect_body $'## Change\r\n\r\nSay which format the export gives.\r'
  expect_labels "factory in-progress"
  [ ! -s "$T/posted" ] || fail "expected no comment, got: $(cat "$T/posted")"
}

scenario "a build stopped for an open ticket: the body gains After #20, ready replaces in-progress, and the ticket starts once #20 closes"
github
wait_for 12 20 "the seed it edits is written by #20."
expect_status 0
expect_output "issue #12 waits with ready for #20 to close"
expect_body $'## Change\r\n\r\nSay which format the export gives.\r\n\nAfter #20'
expect_labels "factory ready"
expect_first_line "gh issue comment 12 --body" "Nothing to do: the factory builds this ticket once #20 has closed."
expect_call "this ticket needs #20 merged first: the seed it edits is written by #20."
start_waiting
expect_status 0
expect_output "issue #12 waits with ready for #20 to close"
expect_no_call "gh workflow run"
echo closed > "$T/state-20"
start_waiting
expect_status 0
expect_call "gh workflow run implement.yml -f issue=12"

scenario "a body that already says After #20 is not given the line twice"
github $'## Change\r\n\r\nSay which format.\r\n\r\nAfter #20\r\n'
wait_for 12 20 "the seed it edits is written by #20."
expect_status 0
expect_no_call "gh issue edit 12 --body"
expect_labels "factory ready"

scenario "a body that only mentions After #20 inside a sentence gains the line"
github "Build it After #20 merges"
wait_for 12 20 "the seed it edits is written by #20."
expect_status 0
expect_body $'Build it After #20 merges\n\nAfter #20'

scenario "a closed ticket is not waited for: nothing changes, and a person is asked"
github
echo closed > "$T/state-20"
wait_for 12 20 "the seed it edits is written by #20."
expect_status 2
expect_output "#20 is closed, so issue #12 has nothing to wait for. Nothing was changed: comment on issue #12 and add needs-human"
expect_unchanged

scenario "a ticket that waits for this one is not waited for: nothing changes, and a person is asked"
github
printf '## Change\r\n\r\nWrite the seed.\r\n\r\nAfter #12\r\n' > "$T/body-20"
wait_for 12 20 "the seed it edits is written by #20."
expect_status 2
expect_output "#20 waits for issue #12, as its body says, so neither would ever start. Nothing was changed"
expect_unchanged

scenario "a ticket does not wait for itself: nothing is asked of GitHub, and a person is asked"
github
wait_for 12 12 "it needs itself."
expect_status 2
expect_output "Issue #12 cannot wait for itself."
[ ! -s "$T/calls" ] || fail "expected no call"

for numbers in "12 twenty" "x 20"; do
  scenario "refuses what is not a number: $numbers"
  github
  # shellcheck disable=SC2086
  wait_for $numbers "a reason"
  expect_status 1
  expect_output "is not an issue number."
  [ ! -s "$T/calls" ] || fail "expected no call"
done

while IFS='|' read -r words message; do
  scenario "stops with a message and changes nothing when this fails: gh $words"
  github
  echo "$words" > "$T/fail"
  wait_for 12 20 "the seed it edits is written by #20."
  expect_status 1
  expect_output "$message"
  expect_unchanged
done <<'CALLS'
api repos/{owner}/{repo}/issues/20|whether #20 is open could not be read from GitHub. Nothing was changed.
issue view 12|its body could not be read from GitHub. Nothing was changed.
issue edit 12 --body|the line `After #20` could not be added to its body. Nothing was changed.
issue edit 12 --add-label|its labels could not be changed. Its body is as it was.
CALLS

scenario "says that the line stays in the body when neither the labels nor the body could be changed back"
github
echo "issue edit 12 --add-label" > "$T/fail"
touch "$T/no-restore"
wait_for 12 20 "the seed it edits is written by #20."
expect_status 1
expect_output "its labels could not be changed, and the line \`After #20\` could not be taken out of its body again."

scenario "a ticket left to wait whose comment failed still waits, and the failure is said"
github
echo "issue comment 12" > "$T/fail"
wait_for 12 20 "the seed it edits is written by #20."
expect_status 1
expect_output "Issue #12 waits with ready for #20 to close, but the reason could not be commented on it"
expect_labels "factory ready"
