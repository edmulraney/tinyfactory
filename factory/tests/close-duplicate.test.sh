#!/usr/bin/env bash
# Tests for close-duplicate.sh, which closes a ticket just filed when another run filed the same first (decisions T620).
. "$(dirname "$0")/helpers.sh"

bot='github-actions[bot]'
# $T/open holds what GitHub lists as open, one ticket a line; $T/fail holds the first words of a call to fail.
github() {
  : > "$T/open"; echo none > "$T/fail"
  stub gh '
    case "$*" in "$(cat "$T/fail")"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&sort=created&direction=desc&per_page=100") jq -sc . "$T/open" ;;
      "issue edit "*" --remove-label ready" | "issue close "*" --reason duplicate --comment "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# open_ticket <number> <title> [<author>] [pull]
open_ticket() {
  jq -cn --argjson n "$1" --arg title "$2" --arg by "${3:-$bot}" --arg pull "${4:-}" \
    '{number: $n, title: $title, user: {login: $by}} | if $pull != "" then .pull_request = {} else . end' >> "$T/open"
}
look() { run "$scripts/close-duplicate.sh" "$@"; }

scenario "another run filed the same ticket first: the later is closed as a duplicate, told which is built, and the first is printed"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
look 31
expect_status 0
[ "$out" = 30 ] || fail "expected the number of the ticket that stays, 30"
expect_calls 1 "gh issue close"
[ "$(grep -n -m 1 -F "gh issue edit 31 --remove-label ready" "$T/calls" | cut -d: -f1)" = 2 ] \
  || fail "expected \`ready\` taken off #31 before it is closed, so that no build of it starts"
expect_call "gh issue close 31 --reason duplicate --comment Nothing to do: two runs filed this ticket at once, and #30, filed first, is the one that is built."

scenario "the ticket filed first stays open, whatever was filed after it"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
look 30
expect_status 0
[ -z "$out" ] || fail "expected no output"
expect_no_call "gh issue close"

scenario "of three filed at once, the second and third each close for the first"
github
open_ticket 32 'Cut `TASTE.md` to budget'
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
look 32
[ "$out" = 30 ] || fail "expected the number of the ticket that stays, 30"
expect_call "gh issue close 32 "

scenario "an earlier ticket under another title, one another account opened and a pull request close nothing"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `DESIGN.md` to budget'
open_ticket 29 'Cut `TASTE.md` to budget' stranger
open_ticket 28 'Cut `TASTE.md` to budget' "$bot" pull
look 31
expect_status 0
[ -z "$out" ] || fail "expected no output"
expect_no_call "gh issue close"

scenario "an earlier ticket under one of the other titles given is the same ticket"
github
open_ticket 31 'Take back pull request #7'
open_ticket 30 'Take back the button merge of pull request #7'
look 31 'Take back pull request #7' 'Take back the button merge of pull request #7'
expect_status 0
[ "$out" = 30 ] || fail "expected the number of the ticket that stays, 30"
expect_call "gh issue close 31 --reason duplicate"

scenario "the open tickets cannot be read: it stops with a message, and closes nothing"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
echo "api repos" > "$T/fail"
look 31
expect_status 1
expect_output "Whether another run filed the same ticket as #31 could not be read from GitHub, so #31 stays open."
expect_no_call "gh issue close"

scenario "a list that does not hold the filed ticket is no answer: it stops with a message, and closes nothing"
github
open_ticket 30 'Cut `TASTE.md` to budget'
look 31
expect_status 1
expect_output "Whether another run filed the same ticket as #31 could not be read from GitHub, so #31 stays open."
expect_no_call "gh issue close"

scenario "the ready label cannot be taken off the later ticket: it stops, says which to close, and closes nothing"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
echo "issue edit" > "$T/fail"
look 31
expect_status 1
expect_output "Ticket #31 is the same as #30, filed first by another run, and could not be closed: close #31."
expect_no_call "gh issue close"

scenario "the later ticket cannot be closed: it stops, and says which to close"
github
open_ticket 31 'Cut `TASTE.md` to budget'
open_ticket 30 'Cut `TASTE.md` to budget'
echo "issue close" > "$T/fail"
look 31
expect_status 1
expect_output "Ticket #31 is the same as #30, filed first by another run, and could not be closed: close #31."
[ "$out" = "${out#30}" ] || fail "expected no number printed for a ticket that was not closed"

for words in "" "TASTE.md" "#31"; do
  scenario "refuses, and calls nothing: close-duplicate.sh $words"
  github
  # shellcheck disable=SC2086
  look $words
  expect_status 1
  expect_output "Usage: close-duplicate.sh <ticket-number> [<other-title>...]"
  expect_no_call "gh "
done
