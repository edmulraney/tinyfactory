#!/usr/bin/env bash
# Writes whether each shipped initiative's hypothesis held, from production's weekly counts, and pushes it to main.
# Usage: measure-initiatives.sh <counts>   (by measure-initiatives.yml, each Monday or by hand; from the repo root, on main)
#        <counts> is the file of what production's database answered: a JSON array with, for each week and event,
#        {week, event, times, runners}, where week is the week's Monday in UTC; or `null` from a database with no
#        table of usage, which ends in exit 0 with nothing written.
#        Writes product/verdicts/<ticket>.md once the date its ticket names has come, then only when the verdict changes.
#        Needs GH_TOKEN (issues: read) and a checkout that may push to main.
#        A failed call, or a file that holds no counts, ends in exit 1 with no file changed here or on main.
set -euo pipefail

die() { echo "$1, so no verdict was written." >&2; exit 1; }

# Each answer is read on a line of its own (decisions H7).
initiatives=$(gh api "repos/{owner}/{repo}/issues?state=all&labels=initiative,deployed&per_page=100" --paginate \
  --jq '.[] | select(.pull_request == null) | {number, title, body: (.body // "")} | tojson') \
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
  | line("^- Number: (?<target>at least (?<least>[0-9]+) (?<unit>runner|time)s? in a week)\\.?\\s*$") as $number
  | line("^- Date: (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})\\s*$") as $date
  | select($event and $number and $date)
  | select($date.date <= ($now | strftime("%Y-%m-%d")))
  | {number: $ticket.number, title: $ticket.title} + $event + $number + $date
' <<<"$initiatives") || die "The metrics of the shipped initiatives could not be read"
if [ -z "$due" ]; then
  echo "No shipped initiative names an event, a number and a date that has come: nothing to measure."
  exit 0
fi

# What is pushed is this checkout's commit, so the checkout is main as GitHub holds it (decisions M631c).
tip=$(git ls-remote origin refs/heads/main) || die "The commit main is at could not be read from GitHub"
[ "${tip%%[[:space:]]*}" = "$(git rev-parse HEAD)" ] || die "This checkout is not main as GitHub holds it"

counts=$(cat -- "${1:-}") || die "The file of production's usage counts could not be read"
if [ "$counts" = null ]; then
  echo "Production's database holds no table of usage, so this project records no usage: nothing to measure."
  exit 0
fi
# An answer that holds no counts is an outage, never a week in which nothing happened (decisions M631d).
jq -e 'type == "array"' <<<"$counts" >/dev/null 2>&1 || die "Production's database answered no weekly counts"

# The reading is of the last week that has ended, Monday to Sunday in UTC (decisions M631b).
readings=$(jq -r --argjson now "$now" --argjson counts "$counts" '
  ($now | gmtime | .[6]) as $weekday
  | ($now - ($now % 86400) - ((($weekday + 6) % 7) + 7) * 86400 | strftime("%Y-%m-%d")) as $week
  | . as $metric
  | ([$counts[] | select(.week == $week and (.event | ascii_downcase) == ($metric.event | ascii_downcase)) | .[$metric.unit + "s"]] | .[0] // 0) as $count
  | . + {week: $week, count: $count, read: ($now | strftime("%Y-%m-%d"))}
  | "\(.number) \($count >= (.least | tonumber)) \(tojson)"
' <<<"$due") || die "The counts of production's database could not be compared with the targets"

written=""
while read -r number held reading; do
  file="product/verdicts/$number.md"
  was=none
  if [ -f "$file" ]; then
    was=false
    ! grep -qx -- '- Verdict: the hypothesis held' "$file" || was=true
  fi
  # The file holds the verdict, not each week's reading (decisions M631e).
  if [ "$was" = "$held" ]; then
    echo "left: #$number, whose verdict is as $file says"
    continue
  fi
  verdict="the hypothesis held"
  [ "$held" = true ] || verdict="the hypothesis did not hold"
  [ "$was" != true ] || verdict="the hypothesis no longer holds"
  mkdir -p product/verdicts
  jq -r --arg verdict "$verdict" '
    "# Verdict on #\(.number): \(.title)",
    "",
    "- Event: \(.event)",
    "- Target: \(.target)",
    "- Date: \(.date)",
    "- Reading: \(.count) \(.unit)\(if .count == 1 then "" else "s" end) in the week from \(.week), read on \(.read)",
    "- Verdict: \($verdict)"
  ' <<<"$reading" > "$file"
  echo "written: $file, $verdict"
  written+="${written:+, }#$number"
done <<<"$readings"
[ -n "$written" ] || exit 0

# A runner has no committer identity, and git commits nothing without one.
git add product/verdicts
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit --quiet -m "docs: record the verdict on $written" -- product/verdicts
if ! git push --quiet origin HEAD:refs/heads/main; then
  # The next run finds no verdict written and writes it, so this one leaves none in the checkout (decisions M631f).
  git reset --quiet --soft HEAD~1
  git restore --quiet --source=HEAD --staged --worktree -- product/verdicts
  die "The verdict on $written could not be pushed to main"
fi
echo "pushed to main: the verdict on $written"
