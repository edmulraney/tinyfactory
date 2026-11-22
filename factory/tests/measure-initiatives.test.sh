#!/usr/bin/env bash
# Tests for factory/scripts/measure-initiatives.sh, which writes whether each shipped initiative's hypothesis held.
. "$(dirname "$0")/helpers.sh"

# $T/initiatives is what GitHub lists as shipped initiatives, $T/comments-<n> the comments on ticket <n>, $T/counts the
# file of what production's database answered, and $T/now the time: Monday 21 December 2026, 05:23 UTC, so the last
# week that has ended began on 2026-12-14. A file $T/github-down fails the call for the initiatives, and
# $T/comments-down the call that posts a comment.
github() {
  echo '[]' > "$T/initiatives"
  echo '[]' > "$T/counts"
  echo 1797830580 > "$T/now"
  stub date 'cat "$T/now"'
  stub gh '
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100 --paginate --jq "*)
        [ ! -e "$T/github-down" ] || { echo "gh: could not connect" >&2; exit 1; }
        json "$(cat "$T/initiatives")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*)
        n=${2#*/issues/}; n=${n%%/*}
        [ -e "$T/comments-$n" ] || echo "[]" > "$T/comments-$n"
        json "$(cat "$T/comments-$n")" "$@" ;;
      "issue comment "*" --body "*)
        [ ! -e "$T/comments-down" ] || { echo "gh: could not connect" >&2; exit 1; }
        [ -e "$T/comments-$3" ] || echo "[]" > "$T/comments-$3"
        jq -c --arg body "$5" ". + [{user: {login: \"github-actions[bot]\"}, body: \$body}]" "$T/comments-$3" > "$T/posted"
        mv "$T/posted" "$T/comments-$3" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# initiative <number> <title> <line of the metric>...: one issue, as GitHub lists it.
initiative() {
  local number="$1" title="$2"
  shift 2
  jq -nc --argjson number "$number" --arg title "$title" --arg metric "$(printf '%s\n' "$@")" '{number: $number, title: $title,
    body: ("## Problem\nPeople forget a race.\n\n## Success metric\n<!-- Example: - Event: race added -->\n" + $metric + "\n\n## Scope\nIn: the list.")}'
}
reminder() { initiative 12 "Remind a user of a race" "- Event: race added" "- Number: at least 5 users in a week" "- Date: ${1:-2026-12-20}"; }
shipped() { jq -sc . > "$T/initiatives"; }
# week <monday> <event> <times> <users>: the counts of one event in one week, as the database answers them.
week() {
  jq -nc --arg week "$1" --arg event "$2" --argjson times "$3" --argjson users "$4" \
    '{week: $week, event: $event, times: $times, users: $users}'
}
counted() { jq -s . > "$T/counts"; }
measure() { run env GH_TOKEN=workflow-token "$scripts/measure-initiatives.sh" "$T/counts"; }
posted() { [ -e "$T/comments-$1" ] && jq length "$T/comments-$1" || echo 0; }
verdict_on() {
  if [ "$(posted "$1")" -gt 0 ]; then jq -r 'last | .body' "$T/comments-$1"; else echo "#$1 holds no verdict"; fi
}
expect_verdict() {
  [ "$(verdict_on "$1")" = "$2" ] || fail "expected #$1 to hold this verdict:"$'\n'"$2"$'\n'"got:"$'\n'"$(verdict_on "$1")"
}
expect_nothing_posted() { expect_no_call "gh issue comment"; }
held='<!-- factory:verdict -->

- Event: race added
- Target: at least 5 users in a week
- Date: 2026-12-20
- Reading: 6 users in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held'

scenario "counts that meet the target on the date post the verdict on the ticket: the hypothesis held, with the reading and its date"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[ "$(posted 12)" = 1 ] || fail "expected one comment on #12, got $(posted 12)"
expect_output "posted on #12: the hypothesis held"

scenario "a verdict is posted on the ticket and nothing is pushed, so a ruleset that admits only pull requests refuses nothing"
github
git init --quiet --bare --initial-branch main "$T/remote.git"
git init --quiet --initial-branch main .
git remote add origin "$T/remote.git"
echo app > app.txt
git add -A && git commit --quiet -m main && git push --quiet origin HEAD:refs/heads/main
printf '#!/bin/sh\nexit 1\n' > "$T/remote.git/hooks/pre-receive"
chmod +x "$T/remote.git/hooks/pre-receive"
tip=$(git rev-parse HEAD)
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[ "$(git --git-dir="$T/remote.git" rev-parse main)" = "$tip" ] || fail "expected main to stay at the commit it was at"
[ "$(git rev-parse HEAD)" = "$tip" ] && [ -z "$(git status --porcelain)" ] \
  || fail "expected the checkout to be as it was, got: $(git status --porcelain)"

scenario "run again with the same counts, it posts nothing"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
: > "$T/calls"
measure
expect_status 0
expect_nothing_posted
expect_output "left: #12"

scenario "a later week whose counts still meet the target posts nothing: the ticket holds the verdict, not each reading"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
: > "$T/calls"
echo $((1797830580 + 7 * 86400)) > "$T/now"
{ week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 30 9; } | counted
measure
expect_status 0
expect_nothing_posted
expect_verdict 12 "$held"

scenario "counts that fall below the target post a new verdict: the hypothesis no longer holds"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
echo $((1797830580 + 7 * 86400)) > "$T/now"
{ week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 4 4; } | counted
measure
expect_status 0
expect_verdict 12 '<!-- factory:verdict -->

- Event: race added
- Target: at least 5 users in a week
- Date: 2026-12-20
- Reading: 4 users in the week from 2026-12-21, read on 2026-12-28
- Verdict: the hypothesis no longer holds'
: > "$T/calls"
measure
expect_nothing_posted

scenario "counts below the target on the date say the hypothesis did not hold, and counts that meet it later say it held"
github
reminder | shipped
week 2026-12-14 "race added" 9 4 | counted
measure
expect_status 0
[[ "$(verdict_on 12)" == *"- Reading: 4 users in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis did not hold" ]] || fail "expected the verdict that it did not hold, got: $(verdict_on 12)"
: > "$T/calls"
measure
expect_nothing_posted
week 2026-12-14 "race added" 9 5 | counted
measure
[[ "$(verdict_on 12)" == *"- Reading: 5 users in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the verdict that it held, got: $(verdict_on 12)"

scenario "a comment that is not the factory's is not read as a verdict, even when it copies one"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
jq -nc --arg body "$held" '[{user: {login: "someone"}, body: $body}]' > "$T/comments-12"
measure
expect_status 0
[ "$(posted 12)" = 2 ] || fail "expected the factory to post its own verdict beside the copy"
expect_verdict 12 "$held"

scenario "a number of times is compared with the times the event happened, whatever the case of its name"
github
initiative 15 "Connect Garmin in one step" "- Event: Garmin Connected" "- Number: at least 3 times in a week." "- Date: 2026-12-21" | shipped
week 2026-12-14 "Garmin connected" 3 1 | counted
measure
expect_status 0
[[ "$(verdict_on 15)" == *"- Target: at least 3 times in a week
- Date: 2026-12-21
- Reading: 3 times in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the times to be read, got: $(verdict_on 15)"

scenario "an event line that ends in a full stop names the same event"
github
initiative 15 "Connect Garmin in one step" "- Event: Garmin connected." "- Number: at least 3 times in a week" "- Date: 2026-12-21" | shipped
week 2026-12-14 "Garmin connected" 3 1 | counted
measure
expect_status 0
[[ "$(verdict_on 15)" == *"- Reading: 3 times in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the event to be read without its full stop, got: $(verdict_on 15)"

scenario "a week in which the event never happened reads as none, and the week still going is not read"
github
reminder | shipped
{ week 2026-12-07 "race added" 9 9; week 2026-12-14 "dashboard opened" 9 9; week 2026-12-21 "race added" 9 9; } | counted
measure
expect_status 0
[[ "$(verdict_on 12)" == *"- Reading: 0 users in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis did not hold" ]] || fail "expected a reading of none for the last whole week, got: $(verdict_on 12)"

scenario "counts larger than 128 KiB, the most one argument may hold, are read"
github
reminder | shipped
{ jq -nc 'range(4000) | {week: "2026-12-14", event: "event number \(.) of many", times: 1, users: 1}'
  week 2026-12-14 "race added" 8 6; } | counted
[ "$(wc -c < "$T/counts")" -gt 131072 ] || fail "expected the counts to be larger than 128 KiB"
measure
expect_status 0
expect_verdict 12 "$held"

for day in "Thursday 24 December:1798070400:2026-12-24" "Sunday 27 December, an hour before the week ends:1798412400:2026-12-27"; do
  scenario "run by hand on ${day%%:*}, it still reads the last week that has ended"
  github
  reminder | shipped
  { week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 2 2; } | counted
  at=${day#*:}
  echo "${at%%:*}" > "$T/now"
  measure
  expect_status 0
  [[ "$(verdict_on 12)" == *"- Reading: 6 users in the week from 2026-12-14, read on ${day##*:}
- Verdict: the hypothesis held" ]] || fail "expected the week from 2026-12-14 to be read, got: $(verdict_on 12)"
done

scenario "one user is written as one user"
github
reminder | shipped
week 2026-12-14 "race added" 1 1 | counted
measure
[[ "$(verdict_on 12)" == *"- Reading: 1 user in the week from 2026-12-14"* ]] || fail "expected \"1 user\", got: $(verdict_on 12)"

scenario "two initiatives whose dates have come each get a verdict on their own ticket, and a body with Windows line ends is read"
github
{ reminder | jq -c '.body |= gsub("\n"; "\r\n")'
  initiative 15 "Connect Garmin in one step" "- Event: Garmin connected" "- Number: at least 3 times in a week" "- Date: 2026-12-01"; } | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[[ "$(verdict_on 15)" == *"- Verdict: the hypothesis did not hold" ]] || fail "expected a verdict on #15, got: $(verdict_on 15)"

scenario "an initiative whose date has not come gets no verdict"
github
reminder 2026-12-22 | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_nothing_posted
expect_output "nothing to measure"

scenario "an initiative gets its verdict on the day its date comes"
github
reminder 2026-12-21 | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
[[ "$(verdict_on 12)" == *"- Verdict: the hypothesis held" ]] || fail "expected a verdict on the date, got: $(verdict_on 12)"

for lacking in Event Number Date; do
  scenario "an initiative whose metric lacks the line \"$lacking\", which another section holds, gets no verdict"
  github
  reminder | jq -c --arg lacking "- $lacking: " \
    '.body |= (split("\n") | map(select(startswith($lacking) | not)) + map(select(startswith($lacking))) | join("\n"))' | shipped
  week 2026-12-14 "race added" 8 6 | counted
  measure
  expect_status 0
  expect_nothing_posted
done

scenario "an initiative whose number no script can compare gets no verdict, and one beside it is still measured"
github
{ initiative 15 "Connect Garmin in one step" "- Event: Garmin connected" "- Number: most users" "- Date: 2026-12-01"
  initiative 16 "Share a race" "- Event: race shared" "- Number: at least 5 runners in a week" "- Date: 2026-12-01"
  reminder; } | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[ "$(verdict_on 15)" = "#15 holds no verdict" ] || fail "expected no verdict on #15"
[ "$(verdict_on 16)" = "#16 holds no verdict" ] || fail "expected no verdict on #16, whose number counts runners, not users"

scenario "only shipped initiatives are asked for, and a pull request that carries the labels is not measured"
github
reminder | jq -c '.pull_request = {url: "https://api.github.com/repos/owner/myapp/pulls/12"}' | shipped
measure
expect_status 0
expect_call "gh api repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100 --paginate"
expect_nothing_posted

scenario "a database with no table of usage is told that the project records no usage, and the run does not fail"
github
reminder | shipped
echo null > "$T/counts"
measure
expect_status 0
expect_nothing_posted
expect_output "Production's database holds no table of usage, so this project records no usage: nothing to measure."

scenario "an answer that holds no counts fails the run: it does not read as a week of nothing"
github
reminder | shipped
: > "$T/counts"
measure
expect_status 1
expect_nothing_posted
expect_output "Production's database answered no weekly counts, so no verdict was posted."

scenario "no file of counts fails the run"
github
reminder | shipped
rm "$T/counts"
measure
expect_status 1
expect_nothing_posted
expect_output "The file of production's usage counts could not be read, so no verdict was posted."

scenario "GitHub not answering fails the run"
github
reminder | shipped
touch "$T/github-down"
measure
expect_status 1
expect_nothing_posted
expect_output "The shipped initiatives could not be read from GitHub, so no verdict was posted."

scenario "comments that cannot be read fail the run, and post nothing: no read is taken for a ticket with no verdict"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
echo 'not json' > "$T/comments-12"
measure
expect_status 1
expect_nothing_posted
expect_output "The verdicts on #12 could not be read from GitHub, so no verdict was posted."

scenario "a comment GitHub refuses fails the run, and the next run posts it"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
touch "$T/comments-down"
measure
expect_status 1
expect_output "The verdict on #12 could not be posted on its ticket, so no verdict was posted."
[ "$(posted 12)" = 0 ] || fail "expected no verdict on #12"
rm "$T/comments-down"
measure
expect_status 0
expect_verdict 12 "$held"

# job <name>: the job's lines in the workflow, read from the source, so a change there fails here.
job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/measure-initiatives.yml"; }

scenario "a project with no Neon project, such as one with no app, skips the weekly job, as ci.yml's Neon steps do"
grep -qxF "    if: vars.NEON_PROJECT_ID != ''" <<<"$(job measure)" \
  || fail "expected the measure job to run only where the repository variable NEON_PROJECT_ID is set"
grep -qF "if: vars.NEON_PROJECT_ID != ''" "$root/factory/workflows/ci.yml" \
  || fail "expected ci.yml's Neon steps to be skipped the same way"
! grep -qF 'exit 1' <<<"$(job measure)" || fail "expected no step of the job to fail for a variable that is not set"

scenario "the job may post on a ticket and may not push"
grep -qxF "      contents: read" <<<"$(job measure)" || fail "expected the job to read the repository's contents and write none"
grep -qE "^      issues: write( |$)" <<<"$(job measure)" || fail "expected the job to post on issues"
