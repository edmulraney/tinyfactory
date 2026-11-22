#!/usr/bin/env bash
# Tests for factory/scripts/measure-initiatives.sh, which writes whether each shipped initiative's hypothesis held.
. "$(dirname "$0")/helpers.sh"

# The work folder is a checkout of main as GitHub holds it. $T/initiatives is what GitHub lists as shipped initiatives,
# $T/counts the file of what production's database answered, and $T/now the time: Monday 21 December 2026, 05:23 UTC,
# so the last week that has ended began on 2026-12-14. A file $T/github-down fails the call to GitHub.
github() {
  git init --quiet --bare --initial-branch main "$T/remote.git"
  git init --quiet --initial-branch main .
  git remote add origin "$T/remote.git"
  echo app > app.txt
  git add -A && git commit --quiet -m main && git push --quiet origin HEAD:refs/heads/main
  echo '[]' > "$T/initiatives"
  echo '[]' > "$T/counts"
  echo 1797830580 > "$T/now"
  stub date 'cat "$T/now"'
  stub gh '
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100 --paginate --jq "*)
        [ ! -e "$T/github-down" ] || { echo "gh: could not connect" >&2; exit 1; }
        json "$(cat "$T/initiatives")" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# initiative <number> <title> <line of the metric>...: one issue, as GitHub lists it.
initiative() {
  local number="$1" title="$2"
  shift 2
  jq -nc --argjson number "$number" --arg title "$title" --arg metric "$(printf '%s\n' "$@")" '{number: $number, title: $title,
    body: ("## Problem\nRunners forget a race.\n\n## Success metric\n<!-- Example: - Event: race added -->\n" + $metric + "\n\n## Scope\nIn: the list.")}'
}
reminder() { initiative 12 "Remind a runner of a race" "- Event: race added" "- Number: at least 5 runners in a week" "- Date: ${1:-2026-12-20}"; }
shipped() { jq -sc . > "$T/initiatives"; }
# week <monday> <event> <times> <runners>: the counts of one event in one week, as the database answers them.
week() {
  jq -nc --arg week "$1" --arg event "$2" --argjson times "$3" --argjson runners "$4" \
    '{week: $week, event: $event, times: $times, runners: $runners}'
}
counted() { jq -s . > "$T/counts"; }
measure() {
  # As on a runner, which has no committer identity.
  run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GH_TOKEN=workflow-token "$scripts/measure-initiatives.sh" "$T/counts"
}
on_main() { git --git-dir="$T/remote.git" "$@"; }
verdict_on_main() { on_main show "main:product/verdicts/$1.md" 2>/dev/null || echo "main holds no verdict on #$1"; }
expect_verdict() {
  [ "$(verdict_on_main "$1")" = "$2" ] || fail "expected main to hold this verdict on #$1:"$'\n'"$2"$'\n'"got:"$'\n'"$(verdict_on_main "$1")"
}
# Nothing reached main, and the checkout is as it was.
expect_nothing_written() {
  [ "$(on_main rev-parse main)" = "$1" ] || fail "expected main to stay at the commit it was at"
  [ "$(git rev-parse HEAD)" = "$1" ] || fail "expected the checkout to stay at the commit it was at"
  [ -z "$(git status --porcelain)" ] || fail "expected the checkout to hold no changed file, got: $(git status --porcelain)"
}
held='# Verdict on #12: Remind a runner of a race

- Event: race added
- Target: at least 5 runners in a week
- Date: 2026-12-20
- Reading: 6 runners in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held'

scenario "counts that meet the target on the date leave the verdict on main: the hypothesis held, with the reading and its date"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[ "$(on_main log -1 --format='%an: %s' main)" = "github-actions[bot]: docs: record the verdict on #12" ] \
  || fail "expected one commit by github-actions[bot] that names the ticket, got: $(on_main log -1 --format='%an: %s' main)"
[ "$(on_main show --name-only --format= main)" = product/verdicts/12.md ] || fail "expected the commit to hold the verdict alone"
expect_output "pushed to main: the verdict on #12"

scenario "run again with the same counts, it changes nothing"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
tip=$(on_main rev-parse main)
measure
expect_status 0
expect_nothing_written "$tip"
expect_output "left: #12"

scenario "a later week whose counts still meet the target changes nothing: the file holds the verdict, not each reading"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
tip=$(on_main rev-parse main)
echo $((1797830580 + 7 * 86400)) > "$T/now"
{ week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 30 9; } | counted
measure
expect_status 0
expect_nothing_written "$tip"
expect_verdict 12 "$held"

scenario "counts that fall below the target rewrite the file: the hypothesis no longer holds"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
echo $((1797830580 + 7 * 86400)) > "$T/now"
{ week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 4 4; } | counted
measure
expect_status 0
expect_verdict 12 '# Verdict on #12: Remind a runner of a race

- Event: race added
- Target: at least 5 runners in a week
- Date: 2026-12-20
- Reading: 4 runners in the week from 2026-12-21, read on 2026-12-28
- Verdict: the hypothesis no longer holds'
tip=$(on_main rev-parse main)
measure
expect_nothing_written "$tip"

scenario "counts below the target on the date say the hypothesis did not hold, and counts that meet it later say it held"
github
reminder | shipped
week 2026-12-14 "race added" 9 4 | counted
measure
expect_status 0
[[ "$(verdict_on_main 12)" == *"- Reading: 4 runners in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis did not hold" ]] || fail "expected the verdict that it did not hold, got: $(verdict_on_main 12)"
tip=$(on_main rev-parse main)
measure
expect_nothing_written "$tip"
week 2026-12-14 "race added" 9 5 | counted
measure
[[ "$(verdict_on_main 12)" == *"- Reading: 5 runners in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the verdict that it held, got: $(verdict_on_main 12)"

scenario "a number of times is compared with the times the event happened, whatever the case of its name"
github
initiative 15 "Connect Garmin in one step" "- Event: Garmin Connected" "- Number: at least 3 times in a week." "- Date: 2026-12-21" | shipped
week 2026-12-14 "Garmin connected" 3 1 | counted
measure
expect_status 0
[[ "$(verdict_on_main 15)" == *"- Target: at least 3 times in a week
- Date: 2026-12-21
- Reading: 3 times in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the times to be read, got: $(verdict_on_main 15)"

scenario "an event line that ends in a full stop names the same event"
github
initiative 15 "Connect Garmin in one step" "- Event: Garmin connected." "- Number: at least 3 times in a week" "- Date: 2026-12-21" | shipped
week 2026-12-14 "Garmin connected" 3 1 | counted
measure
expect_status 0
[[ "$(verdict_on_main 15)" == *"- Reading: 3 times in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis held" ]] || fail "expected the event to be read without its full stop, got: $(verdict_on_main 15)"

scenario "a week in which the event never happened reads as none, and the week still going is not read"
github
reminder | shipped
{ week 2026-12-07 "race added" 9 9; week 2026-12-14 "dashboard opened" 9 9; week 2026-12-21 "race added" 9 9; } | counted
measure
expect_status 0
[[ "$(verdict_on_main 12)" == *"- Reading: 0 runners in the week from 2026-12-14, read on 2026-12-21
- Verdict: the hypothesis did not hold" ]] || fail "expected a reading of none for the last whole week, got: $(verdict_on_main 12)"

for day in "Thursday 24 December:1798070400:2026-12-24" "Sunday 27 December, an hour before the week ends:1798412400:2026-12-27"; do
  scenario "run by hand on ${day%%:*}, it still reads the last week that has ended"
  github
  reminder | shipped
  { week 2026-12-14 "race added" 8 6; week 2026-12-21 "race added" 2 2; } | counted
  at=${day#*:}
  echo "${at%%:*}" > "$T/now"
  measure
  expect_status 0
  [[ "$(verdict_on_main 12)" == *"- Reading: 6 runners in the week from 2026-12-14, read on ${day##*:}
- Verdict: the hypothesis held" ]] || fail "expected the week from 2026-12-14 to be read, got: $(verdict_on_main 12)"
done

scenario "one runner is written as one runner"
github
reminder | shipped
week 2026-12-14 "race added" 1 1 | counted
measure
[[ "$(verdict_on_main 12)" == *"- Reading: 1 runner in the week from 2026-12-14"* ]] || fail "expected \"1 runner\", got: $(verdict_on_main 12)"

scenario "two initiatives whose dates have come reach main in one commit, and a body with Windows line ends is read"
github
{ reminder | jq -c '.body |= gsub("\n"; "\r\n")'
  initiative 15 "Connect Garmin in one step" "- Event: Garmin connected" "- Number: at least 3 times in a week" "- Date: 2026-12-01"; } | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[[ "$(verdict_on_main 15)" == *"- Verdict: the hypothesis did not hold" ]] || fail "expected a verdict on #15, got: $(verdict_on_main 15)"
[ "$(on_main rev-list --count main)" = 2 ] || fail "expected one commit for both verdicts"
[ "$(on_main log -1 --format=%s main)" = "docs: record the verdict on #12, #15" ] || fail "expected the commit to name both tickets"

scenario "an initiative whose date has not come gets no file"
github
reminder 2026-12-22 | shipped
week 2026-12-14 "race added" 8 6 | counted
tip=$(on_main rev-parse main)
measure
expect_status 0
expect_nothing_written "$tip"
expect_output "nothing to measure"

scenario "an initiative gets its file on the day its date comes"
github
reminder 2026-12-21 | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
[[ "$(verdict_on_main 12)" == *"- Verdict: the hypothesis held" ]] || fail "expected a verdict on the date, got: $(verdict_on_main 12)"

for lacking in Event Number Date; do
  scenario "an initiative whose metric lacks the line \"$lacking\", which another section holds, gets no file"
  github
  reminder | jq -c --arg lacking "- $lacking: " \
    '.body |= (split("\n") | map(select(startswith($lacking) | not)) + map(select(startswith($lacking))) | join("\n"))' | shipped
  week 2026-12-14 "race added" 8 6 | counted
  tip=$(on_main rev-parse main)
  measure
  expect_status 0
  expect_nothing_written "$tip"
done

scenario "an initiative whose number no script can compare gets no file, and one beside it is still measured"
github
{ initiative 15 "Connect Garmin in one step" "- Event: Garmin connected" "- Number: most runners" "- Date: 2026-12-01"; reminder; } | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
expect_status 0
expect_verdict 12 "$held"
[ "$(verdict_on_main 15)" = "main holds no verdict on #15" ] || fail "expected no verdict on #15"

scenario "only shipped initiatives are asked for, and a pull request that carries the labels is not measured"
github
reminder | jq -c '.pull_request = {url: "https://api.github.com/repos/owner/myapp/pulls/12"}' | shipped
tip=$(on_main rev-parse main)
measure
expect_status 0
expect_call "gh api repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100 --paginate"
expect_nothing_written "$tip"

scenario "a database with no table of usage is told that the project records no usage, and the run does not fail"
github
reminder | shipped
echo null > "$T/counts"
tip=$(on_main rev-parse main)
measure
expect_status 0
expect_nothing_written "$tip"
expect_output "Production's database holds no table of usage, so this project records no usage: nothing to measure."

scenario "an answer that holds no counts fails the run: it does not read as a week of nothing"
github
reminder | shipped
: > "$T/counts"
tip=$(on_main rev-parse main)
measure
expect_status 1
expect_nothing_written "$tip"
expect_output "Production's database answered no weekly counts, so no verdict was written."

scenario "no file of counts fails the run"
github
reminder | shipped
tip=$(on_main rev-parse main)
rm "$T/counts"
measure
expect_status 1
expect_nothing_written "$tip"
expect_output "The file of production's usage counts could not be read, so no verdict was written."

scenario "GitHub not answering fails the run"
github
reminder | shipped
touch "$T/github-down"
tip=$(on_main rev-parse main)
measure
expect_status 1
expect_nothing_written "$tip"
expect_output "The shipped initiatives could not be read from GitHub, so no verdict was written."

scenario "a checkout that is not main as GitHub holds it writes nothing, so no other commit is pushed to main"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
tip=$(on_main rev-parse main)
echo more > app.txt
git commit --quiet -am "a commit main does not hold"
measure
expect_status 1
[ "$(on_main rev-parse main)" = "$tip" ] || fail "expected main to stay at the commit it was at"
[ ! -e product/verdicts ] || fail "expected no verdict in the checkout"
expect_output "This checkout is not main as GitHub holds it, so no verdict was written."

scenario "a push that main refuses fails the run and leaves no verdict in the checkout, so the next run writes it"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
printf '#!/bin/sh\nexit 1\n' > "$T/remote.git/hooks/pre-receive"
chmod +x "$T/remote.git/hooks/pre-receive"
tip=$(on_main rev-parse main)
measure
expect_status 1
expect_nothing_written "$tip"
expect_output "The verdict on #12 could not be pushed to main, so no verdict was written."
rm "$T/remote.git/hooks/pre-receive"
measure
expect_status 0
expect_verdict 12 "$held"

scenario "a push that main refuses puts a rewritten verdict back as main holds it"
github
reminder | shipped
week 2026-12-14 "race added" 8 6 | counted
measure
week 2026-12-14 "race added" 2 2 | counted
printf '#!/bin/sh\nexit 1\n' > "$T/remote.git/hooks/pre-receive"
chmod +x "$T/remote.git/hooks/pre-receive"
tip=$(on_main rev-parse main)
measure
expect_status 1
expect_nothing_written "$tip"
[ "$(cat product/verdicts/12.md)" = "$held" ] || fail "expected the checkout to hold the verdict main holds"
