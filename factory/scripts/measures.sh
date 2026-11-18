#!/usr/bin/env bash
# Records a merged ticket's measures on the `sessions` branch, and prints a week's or a month's as a table of six.
# Usage: ticket-cost.sh --json <pr-number> | measures.sh record   writes the ticket's one line in measures.jsonl
#        measures.sh --week <yyyy>-W<ww> [sessions-dir]           the tickets merged in that ISO week (UTC)
#        measures.sh --month <yyyy-mm> [sessions-dir]             the tickets merged in that month (UTC)
#        sessions-dir is a checkout of the sessions branch; without one the record alone is downloaded.
#        Needs GH_TOKEN (contents and issues: read); record needs contents: write, and GITHUB_REPOSITORY.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
usage="Usage: measures.sh record | --week <yyyy>-W<ww> [sessions-dir] | --month <yyyy-mm> [sessions-dir]"

# naming <since>: the issues changed since then whose description names another by number (decisions H246e).
naming() {
  gh api --method GET "repos/{owner}/{repo}/issues" -f state=all -f since="$1" -f per_page=100 --paginate \
    --jq '.[] | select(.pull_request == null)
      | {number, bug: any(.labels[]; .name == "bug"), names: [(.body // "") | scan("#([0-9]+)") | .[0] | tonumber] | unique}
      | select(.names | length > 0) | tojson'
}

# Spliced in front of the jq programs that read a line; $found is what naming printed.
# shellcheck disable=SC2016
from='
  def at: sub("\\.[0-9]+Z$"; "Z") | fromdate;
  def ready: (.merged_at | at) - (.seconds // 0);
  def named($bug): . as $line
    | [$found | split("\n")[] | select(. != "") | fromjson
       | select(.number > $line.issue and any(.names[]; . == $line.issue or . == $line.pr) and (($bug | not) or .bug)) | .number];'

case "${1:-}" in
  record)
    line=$(jq -ce 'select((.pr | type) == "number" and (.issue | type) == "number" and (.merged_at | type) == "string")' 2>/dev/null) \
      || die "The figures on stdin are not those of a merged ticket, so nothing is recorded."
    pr=$(jq -r .pr <<<"$line"); issue=$(jq -r .issue <<<"$line")
    [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] \
      || die "GH_TOKEN and GITHUB_REPOSITORY are not both set, so the measures of ticket #$issue are not recorded."
    since=$(jq -r "$from"'ready | todate' --arg found "" <<<"$line")
    found=$(naming "$since") \
      || die "Could not list the issues changed since $since, so the tickets opened from ticket #$issue are not known and its measures are not recorded."
    line=$(jq -c --arg found "$found" "$from"'.opened = named(false)' <<<"$line")

    . "$script_dir/sessions-branch.sh"
    # add_line <clone>: what push_to_sessions runs in each fresh clone of the branch.
    add_line() {
      local file="$1/measures.jsonl"
      # Decisions H246b.
      if [ -f "$file" ]; then
        jq -c --argjson pr "$pr" 'select(.pr != $pr)' "$file" > "$file.kept" && mv "$file.kept" "$file" || return 1
      fi
      printf '%s\n' "$line" >> "$file"
    }
    push_to_sessions "measures: ticket #$issue" add_line \
      || die "The measures of ticket #$issue could not be written to measures.jsonl on the sessions branch, so no table will hold them."
    echo "recorded the measures of ticket #$issue in measures.jsonl on the sessions branch"
    exit 0 ;;
  --week) [[ "${2:-}" =~ ^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$ ]] || die "$usage" ;;
  --month) [[ "${2:-}" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || die "$usage" ;;
  *) die "$usage" ;;
esac
period="$2"; sessions="${3:-}"

if [ -n "$sessions" ]; then
  [ -f "$sessions/measures.jsonl" ] || die "$sessions holds no measures.jsonl, so no ticket's measures are recorded there."
  record=$(cat "$sessions/measures.jsonl")
else
  record=$(gh api "repos/{owner}/{repo}/contents/measures.jsonl?ref=sessions" -H "Accept: application/vnd.github.raw") \
    || die "Could not download measures.jsonl from the sessions branch, so the measures of $period are not known."
fi
lines=$(jq -c --arg period "$period" "$from"'
    select(.merged_at | if $period | contains("W") then (at | strftime("%G-W%V")) == $period else startswith($period) end)' \
    --arg found "" <<<"$record") \
  || die "measures.jsonl holds a line that could not be read, so the measures of $period are not known."
[ -n "$lines" ] || { echo "No recorded ticket merged in $period."; exit 0; }

# A retro opens its proposal after the merge, and a bug comes later still, so GitHub is asked again (decisions H246e).
since=$(jq -rs --arg found "" "$from"'map(ready) | min | todate' <<<"$lines")
found=$(naming "$since") \
  || die "Could not list the issues changed since $since, so the tickets opened from those merged in $period, and the bugs traced to them, are not known."

# Decisions H246f.
jq -rs --arg period "$period" --arg found "$found" "$from"'
  def plural(word): "\(.) \(word)" + (if . == 1 then "" else "s" end);
  def mean(f): (map(f) | add) / length;
  def tenth: (. * 10 | round) / 10;
  def dollars: (. * 100 | round) as $cents
    | "$\($cents / 100 | floor).\($cents % 100 | tostring | if length < 2 then "0" + . else . end)";
  def took: (. / 60 | round) as $m
    | if $m < 60 then "\($m) min" elif $m < 1440 then "\($m / 60 | floor) h \($m % 60) min"
      else "\($m / 1440 | floor) d \($m % 1440 / 60 | floor) h" end;
  map(.opened = ((.opened // []) + named(false) | unique) | .bugs = named(true)) as $all
  | ($all | length) as $n
  | ($all | map(select(.seconds != null))) as $timed
  | ($all | map(.unread // 0) | add) as $unread
  | ($all | map(select(.fix_rounds + .owner_rounds == 0)) | length) as $clean
  | "The six measures for \($period), over \($n | plural("merged ticket")):",
    "",
    "| Measure | Figure |",
    "|---|---|",
    "| Cost per ticket | \($all | mean(.cost_usd) | dollars) of Claude usage at API prices and \($all | mean(.minutes) | round) Actions minutes"
      + (if $unread == 0 then "" else "; \($unread | plural("transcript")) could not be read, so the usage is more" end) + " |",
    "| Time to merge | "
      + (if ($timed | length) == 0 then "not known: no ticket was labelled `ready`"
         else "\($timed | mean(.seconds) | took): \($timed | mean(.split.build) | took) building, \($timed | mean(.split.review) | took) in review, "
           + "\($timed | mean(.split.fix) | took) in fix rounds, \($timed | mean(.split.waiting) | took) waiting"
           + (if ($timed | length) == $n then "" else ", over the \($timed | length) labelled `ready`" end) end) + " |",
    "| Passing with no fix round | \($clean) of \($n) (\($clean * 100 / $n | round)%) |",
    "| Stops for a person per ten tickets | \($all | mean(.stops // 0) * 10 | tenth) |",
    "| Tickets opened per merge | \($all | mean(.opened | length) | tenth) |",
    "| Bugs traced to a ticket | \($all | map(.bugs | length) | add)"
      + ($all | map(select(.bugs != []) | (.bugs | map("#\(.)") | join(", ")) + " to #\(.issue)") | if . == [] then "" else ": " + join("; ") end) + " |"
' <<<"$lines"
