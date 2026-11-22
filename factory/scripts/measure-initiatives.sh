#!/usr/bin/env bash
# Says on each shipped initiative's ticket whether its hypothesis held, from production's weekly counts.
# Usage: measure-initiatives.sh <counts>   (by measure-initiatives.yml, each Monday or by hand; from the repo root)
#        <counts> is the file of what production's database answered: a JSON array with, for each week and event,
#        {week, event, times, users}, where week is the week's Monday in UTC; or `null` from a database with no
#        table of usage, which ends in exit 0 with nothing posted.
#        Posts the verdict as a comment on the ticket once the date it names has come, then only when the verdict changes.
#        Needs GH_TOKEN (issues: write).
#        A failed call, or a file that holds no counts, ends in exit 1. A verdict posted before a failed call stays,
#        and the next run posts only the ones it finds missing.
set -euo pipefail

die() { echo "$1, so no verdict was posted." >&2; exit 1; }

# Each answer is read on a line of its own (decisions H7).
initiatives=$(gh api "repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | {number, body: (.body // "")} | tojson') \
  || die "The shipped initiatives could not be read from GitHub"
now=$(date -u +%s) || die "The time could not be read"

# The three lines are read as check-ticket.sh asks for them (decisions T630a, T630b).
due=$(jq -c --argjson now "$now" '
  def line(pattern): [.[] | capture(pattern)] | .[0];
  . as $ticket
  | (.body | gsub("\r"; "") | split("\n")) as $lines
  | ($lines | index("## Success metric")) as $start
  | select($start != null)
  | $lines[$start + 1:]
  | (map(startswith("## ")) | index(true)) as $end
  | (if $end == null then . else .[:$end] end)
  | line("^- Event: (?<event>[^\\s].*?)\\.?\\s*$") as $event
  | line("^- Number: (?<target>at least (?<least>[0-9]+) (?<unit>user|time)s? in a week)\\.?\\s*$") as $number
  | line("^- Date: (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\\s*$") as $date
  | select($event and $number and $date)
  | select($date.date <= ($now | strftime("%Y-%m-%d")))
  | {number: $ticket.number} + $event + $number + $date
' <<<"$initiatives") || die "The metrics of the shipped initiatives could not be read"
if [ -z "$due" ]; then
  echo "No shipped initiative names an event, a number and a date that has come: nothing to measure."
  exit 0
fi

counts="${1:-}"
[ -f "$counts" ] && [ -r "$counts" ] || die "The file of production's usage counts could not be read"
if jq -e '. == null' "$counts" >/dev/null 2>&1; then
  echo "Production's database holds no table of usage, so this project records no usage: nothing to measure."
  exit 0
fi
# An answer that holds no counts is an outage, never a week in which nothing happened (decisions M631d).
jq -e 'type == "array"' "$counts" >/dev/null 2>&1 || die "Production's database answered no weekly counts"

# The reading is of the last week that has ended, Monday to Sunday in UTC (decisions M631b).
# Every week's counts are read from the file, as one argument holds no more than 128 KiB (decisions M641b).
readings=$(jq -r --argjson now "$now" --slurpfile counts "$counts" '
  ($now | gmtime | .[6]) as $weekday
  | ($now - ($now % 86400) - ((($weekday + 6) % 7) + 7) * 86400 | strftime("%Y-%m-%d")) as $week
  | . as $metric
  | ([$counts[0][] | select(.week == $week and (.event | ascii_downcase) == ($metric.event | ascii_downcase)) | .[$metric.unit + "s"]] | .[0] // 0) as $count
  | . + {week: $week, count: $count, read: ($now | strftime("%Y-%m-%d"))}
  | "\(.number) \($count >= (.least | tonumber)) \(tojson)"
' <<<"$due") || die "The counts of production's database could not be compared with the targets"

# Each verdict is a comment the workflow's own token posts on the ticket, starting with this line (decisions M631c).
marker="<!-- factory:verdict -->"
while read -r number held reading; do
  # The last verdict posted says what the ticket holds (decisions M631e).
  was=$(gh api "repos/{owner}/{repo}/issues/$number/comments?per_page=100" --paginate \
    --jq ".[] | select(.user.login == \"github-actions[bot]\" and ((.body // \"\") | startswith(\"$marker\")))
      | .body | split(\"\\n\") | index(\"- Verdict: the hypothesis held\") != null") \
    || die "The verdicts on #$number could not be read from GitHub"
  was=$(tail -n 1 <<<"$was")
  if [ "${was:-none}" = "$held" ]; then
    echo "left: #$number, whose verdict on its ticket still stands"
    continue
  fi
  verdict="the hypothesis held"
  [ "$held" = true ] || verdict="the hypothesis did not hold"
  [ "$was" != true ] || verdict="the hypothesis no longer holds"
  body=$(jq -r --arg marker "$marker" --arg verdict "$verdict" '
    $marker,
    "",
    "- Event: \(.event)",
    "- Target: \(.target)",
    "- Date: \(.date)",
    "- Reading: \(.count) \(.unit)\(if .count == 1 then "" else "s" end) in the week from \(.week), read on \(.read)",
    "- Verdict: \($verdict)"
  ' <<<"$reading") || die "The verdict on #$number could not be written"
  gh issue comment "$number" --body "$body" >/dev/null || die "The verdict on #$number could not be posted on its ticket"
  echo "posted on #$number: $verdict"
done <<<"$readings"
