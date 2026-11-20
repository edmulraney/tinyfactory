#!/usr/bin/env bash
# Tests for cut-rule-files.sh, which files the ticket that cuts a rule file over its word budget (decisions H476a).
. "$(dirname "$0")/helpers.sh"

# main_holds <budget> <words> <file>: `main` on GitHub lists the file with that budget, and the file holds that many words.
main_holds() {
  mkdir -p "$T/main/repo/factory" "$(dirname "$T/main/repo/$3")"
  echo "$1 $3" >> "$T/main/repo/factory/rule-files.txt"
  # shellcheck disable=SC2046
  echo $(seq "$2") > "$T/main/repo/$3"
}
# a_ticket <number> <state> <opened at> <title> [pull]: one GitHub lists among the open tickets, or those changed this month.
a_ticket() {
  jq -cn --argjson n "$1" --arg state "$2" --arg at "$3" --arg title "$4" --arg pull "${5:-}" \
    '{number: $n, state: $state, created_at: $at, title: $title} | if $pull != "" then .pull_request = {} else . end' >> "$T/tickets"
}
# The month is November 2026, and the next ticket filed is #30. $T/title-<n> and $T/body-<n> hold what was filed.
github() {
  : > "$T/fail"; : > "$T/tickets"
  stub date 'echo 2026-11'
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/tarball/main") tar -cz -C "$T/main" repo ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 --paginate --jq "*)
        json "$(jq -sc "map(select(.state == \"open\"))" "$T/tickets")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f labels=factory -f since=2026-11-01T00:00:00Z -f per_page=100 --paginate --jq "*)
        json "$(jq -sc . "$T/tickets")" "$@" ;;
      "issue create --title "*)
        n=$(($(cat "$T/filed" 2>/dev/null || echo 29) + 1)); echo "$n" > "$T/filed"
        printf "%s" "$4" > "$T/title-$n"; printf "%s\n" "${@: -1}" > "$T/body-$n"
        echo "https://github.com/owner/myapp/issues/$n" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
cut() { run "$scripts/cut-rule-files.sh" "$@"; }
# expect_buildable <n>: the gate that starts a build passes ticket #<n> as it was filed.
expect_buildable() {
  local problems
  problems=$("$scripts/check-ticket.sh" --draft factory "$(cat "$T/title-$1")" "$T/body-$1") \
    || fail "expected check-ticket.sh to pass the ticket filed as #$1: $problems"
}
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder, found: $(ls -A "$T/tmp")"
}

scenario "a file one word over its budget on main: one ticket is filed with ready, and says to move or delete and not to raise the budget"
github
main_holds 700 701 TASTE.md
main_holds 600 600 DESIGN.md
cut
expect_status 0
expect_calls 1 "gh issue create"
expect_call 'gh issue create --title Cut `TASTE.md` to budget --label factory --label ready --body ## Change'
expect_call '`TASTE.md` holds 701 words on `main`, and its budget in `factory/rule-files.txt` is 700 words.'
expect_call 'move what only some tasks need to the document those tasks read, and delete what no agent needs to do its work well, to avoid a mistake or to save tokens (`TASTE.md`, "Writing"). Do not raise the budget.'
expect_output "TASTE.md holds 701 words and its budget is 700: filed with ready, and its build starts when a place is free, https://github.com/owner/myapp/issues/30"
expect_buildable 30
expect_nothing_left

scenario "the same file is over while its ticket is open: no second ticket is filed"
github
main_holds 700 716 TASTE.md
a_ticket 21 open "2026-10-30T09:00:00Z" 'Cut `TASTE.md` to budget'
cut
expect_status 0
expect_no_call "gh issue create"
expect_output "TASTE.md holds 716 words and its budget is 700; issue #21 is open to cut it, so no second ticket was filed"

scenario "an open ticket for another file, a closed one for this file and a pull request titled as the ticket stop nothing"
github
main_holds 700 716 TASTE.md
a_ticket 21 open "2026-11-02T09:00:00Z" 'Cut `DESIGN.md` to budget'
a_ticket 22 closed "2026-11-03T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 23 open "2026-11-04T09:00:00Z" 'Cut `TASTE.md` to budget' pull
cut
expect_status 0
expect_call 'gh issue create --title Cut `TASTE.md` to budget --label factory --label ready '

scenario "each file over its budget gets its own ticket, and one in budget gets none"
github
main_holds 700 716 TASTE.md
main_holds 600 600 DESIGN.md
main_holds 800 801 .claude/skills/implement/SKILL.md
cut
expect_status 0
expect_calls 2 "gh issue create"
expect_call 'gh issue create --title Cut `TASTE.md` to budget '
expect_call 'gh issue create --title Cut `.claude/skills/implement/SKILL.md` to budget '
expect_no_call 'DESIGN.md'

scenario "the third ticket for one file in a calendar month is a proposal that names the two choices, and gets no ready"
github
main_holds 700 716 TASTE.md
a_ticket 21 closed "2026-11-02T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 22 closed "2026-11-09T09:00:00Z" 'Cut `TASTE.md` to budget'
cut
expect_status 0
expect_calls 1 "gh issue create"
expect_first_line 'gh issue create --title Cut `TASTE.md` to budget --label factory --label proposal --body' 'Choose one of the two below and edit "Change" to say which, then add the `ready` label: nothing is built until then.'
expect_call "Two tickets opened in 2026-11 already cut it."
expect_call "- a larger budget, with its decision row;"
expect_call "- a split of the file, so that what only some tasks need is in a document those tasks read."
expect_no_call "--label ready"
expect_output "TASTE.md holds 716 words and its budget is 700, for the third time in 2026-11: a proposal waits for the owner, https://github.com/owner/myapp/issues/30"
expect_buildable 30

scenario "the second ticket in a month, after two in the month before and two for another file, is no proposal"
github
main_holds 700 716 TASTE.md
a_ticket 19 closed "2026-10-20T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 20 closed "2026-10-30T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 21 closed "2026-11-02T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 22 closed "2026-11-03T09:00:00Z" 'Cut `DESIGN.md` to budget'
a_ticket 23 closed "2026-11-04T09:00:00Z" 'Cut `DESIGN.md` to budget'
cut
expect_status 0
expect_call 'gh issue create --title Cut `TASTE.md` to budget --label factory --label ready '
expect_no_call "--label proposal"

scenario "no file over its budget: nothing is filed, and no ticket is listed"
github
main_holds 700 700 TASTE.md
cut
expect_status 0
expect_output "no rule file on main is over its word budget"
expect_calls 1 "gh "
expect_nothing_left

for words in "api repos/{owner}/{repo}/tarball/main" "api repos/{owner}/{repo}/issues?state=open" "api --method GET repos/{owner}/{repo}/issues -f state=all"; do
  scenario "stops with a message, having filed nothing, when GitHub fails: gh $words"
  github
  main_holds 700 716 TASTE.md
  echo "$words" > "$T/fail"
  cut
  expect_status 1
  expect_output "no ticket was filed"
  expect_no_call "gh issue create"
  expect_nothing_left
done

scenario "stops with a message when the ticket cannot be filed"
github
main_holds 700 716 TASTE.md
echo "issue create" > "$T/fail"
cut
expect_status 1
expect_output "Could not file the ticket that cuts TASTE.md to its word budget; the next merge files it."
expect_nothing_left

scenario "stops with a message when the proposal cannot be filed"
github
main_holds 700 716 TASTE.md
a_ticket 21 closed "2026-11-02T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 22 closed "2026-11-09T09:00:00Z" 'Cut `TASTE.md` to budget'
echo "issue create" > "$T/fail"
cut
expect_status 1
expect_output "Could not file the proposal for TASTE.md, over its word budget for the third time in 2026-11; the next merge files it."

scenario "stops with a message, having filed nothing, when the list on main names a file main does not hold"
github
main_holds 700 716 TASTE.md
echo "600 DESIGN.md" >> "$T/main/repo/factory/rule-files.txt"
cut
expect_status 1
expect_output "The list of rule files on main could not be read, so no ticket was filed: "
expect_output "factory/rule-files.txt:2: DESIGN.md is not a file"
expect_no_call "gh issue create"

scenario "count prints how many such tickets each file had in the month, whatever their state"
github
a_ticket 19 closed "2026-10-30T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 21 closed "2026-11-02T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 22 open "2026-11-09T09:00:00Z" 'Cut `TASTE.md` to budget'
a_ticket 23 closed "2026-11-10T09:00:00Z" 'Cut `.claude/skills/retro/SKILL.md` to budget'
a_ticket 24 closed "2026-11-11T09:00:00Z" 'Cut the cost of a retro'
a_ticket 25 open "2026-11-12T09:00:00Z" 'Cut `DESIGN.md` to budget' pull
cut count 2026-11
expect_status 0
[ "$out" = "1 .claude/skills/retro/SKILL.md"$'\n'"2 TASTE.md" ] || fail "expected one ticket for the retro skill and two for TASTE.md, and nothing else"

scenario "count prints nothing for a month with no such ticket"
github
a_ticket 24 closed "2026-11-11T09:00:00Z" 'Cut the cost of a retro'
cut count 2026-11
expect_status 0
[ -z "$out" ] || fail "expected no output"

scenario "count stops with a message when GitHub fails"
github
echo "api --method GET" > "$T/fail"
cut count 2026-11
expect_status 1
expect_output "Could not list the tickets opened in 2026-11, so the tickets that cut a rule file are not counted."

for words in "count" "count 2026-13" "count 2026-W47" "--month 2026-11"; do
  scenario "refuses, and calls nothing: cut-rule-files.sh $words"
  github
  # shellcheck disable=SC2086
  cut $words
  expect_status 1
  expect_output "Usage: cut-rule-files.sh"
  expect_no_call "gh "
done

scenario "the gate passes the ticket for each of the factory's own rule files, the one with the longest path included"
github
while read -r budget file; do
  case "$budget" in '' | '#'*) continue ;; esac
  main_holds 1 2 "$file"
done < "$root/factory/rule-files.txt"
cut
expect_status 0
for title in "$T"/title-*; do
  expect_buildable "${title##*-}"
done
[ "$(cat "$T/filed")" -gt 30 ] || fail "expected a ticket for each rule file"
