#!/usr/bin/env bash
# Keeps facts that change by themselves out of rule files and script comments, and keeps rule files short.
# Usage: check-rule-files.sh   (from the repo root)
set -euo pipefail

# Each rule file and its word budget (decisions H172b).
list="factory/rule-files.txt"
if [ ! -f "$list" ]; then
  echo "$list: there is no such file, so no rule file was checked"
  exit 1
fi

# Each listing is on a line of its own, so a failed one is not taken for a repo with no files (decisions H106).
unlisted() {
  echo "check-rule-files.sh must be run inside a git repository: it could not list the $1 with git ls-files, so nothing was checked."
  exit 1
}
skills=$(git ls-files '.claude/skills/*/SKILL.md') || unlisted "skills"
# The tests' own files are left out (decisions H172d).
scripts=$(git ls-files 'factory/scripts/*.sh' '.claude/skills/bootstrap/scripts/*.sh') || unlisted "scripts"

failed=0
rule_files=""
number=0
while IFS= read -r line || [ -n "$line" ]; do
  number=$((number + 1))
  line=${line%$'\r'}
  case "$line" in '' | '#'*) continue ;; esac
  budget=${line%% *}
  file=${line#* }
  case "$budget" in
    '' | *[!0-9]*)
      echo "$list:$number: a line is \"<words> <path>\", and this is not: $line"
      failed=1
      continue
      ;;
  esac
  if [ ! -f "$file" ]; then
    # A project with no interface has no DESIGN.md (decisions H501a).
    [ "$file" != DESIGN.md ] || continue
    echo "$list:$number: $file is not a file: take the line out, or correct its path"
    failed=1
    continue
  fi
  rule_files+="$file"$'\n'
  words=$(wc -w < "$file" | tr -d ' ')
  if [ "$words" -gt "$budget" ]; then
    echo "$file: it holds $words words and its budget is $budget. Cut it: a sentence stays only when removing it changes what a reader does (TASTE.md). Raising the budget in $list is a decision, with a row in this ticket's file in factory/decisions/"
    failed=1
  fi
done < "$list"

while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  if ! grep -qxF "$skill" <<<"$rule_files"; then
    echo "$skill: $list does not name it. Add a line with its word budget: every skill is a rule file"
    failed=1
  fi
done <<<"$skills"

# Of a script, only the comments (decisions H172a). For any awk: no \b, no {n,m}, and a lowered copy of the line.
scan() {
  local comments_only="$1"
  shift
  awk -v comments_only="$comments_only" '
    # Says what was found and the words themselves, trimmed of the character either side that
    # only marked where they begin and end.
    function found(what, line, pattern) {
      if (!match(line, pattern)) return
      words = substr(line, RSTART, RLENGTH)
      gsub(/^[^#A-Za-z0-9]+|[^A-Za-z0-9]+$/, "", words)
      print FILENAME ":" FNR ": " what ": \"" words "\""
      bad = 1
    }
    BEGIN {
      months = "(January|February|March|April|May|June|July|August|September|October|November|December)"
      states = "(open|closed|merged|unmerged|deployed|shipped|done|in progress|in-progress|in flight|in review)"
      phrases = "(currently|so far|not yet)"
    }
    { sub(/\r$/, "") }
    comments_only && !/^[ \t]*#/ { next }
    {
      lower = tolower($0)
      found("the state of a ticket beside its number", lower, "#[0-9]+[,:]? ?[(]?(is |was |still |now )*" states "([^a-z]|$)")
      found("the state of a ticket beside its number", lower, "(^|[^a-z])" states " (ticket |issue |pull request |pr )?#[0-9]+")
      found("a date", $0, "(^|[^0-9])[0-9][0-9]?(st|nd|rd|th)? " months "([^a-z]|$)")
      found("a date", $0, "(^|[^A-Za-z])" months " [0-9]+")
      found("a date", $0, "(^|[^0-9])20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)")
      found("a phrase that is true only for now", lower, "(^|[^a-z])" phrases "([^a-z]|$)")
    }
    END { exit bad }' "$@"
}

report=""
if [ -n "$rule_files" ]; then
  # shellcheck disable=SC2086
  report=$(IFS=$'\n'; scan 0 $rule_files) || failed=1
fi
if [ -n "$scripts" ]; then
  # shellcheck disable=SC2086
  comments=$(scan 1 $scripts) || failed=1
  report+=${report:+${comments:+$'\n'}}$comments
fi
if [ -n "$report" ]; then
  printf '%s\n' "$report"
  echo "Each of these is true only for now, and is wrong once a ticket merges or the day passes. A rule file holds what stays true until someone edits it (TASTE.md): write the rule, and leave what happened to the ticket, a decision row or a free-tier entry."
fi
[ "$failed" -eq 0 ] && echo "rule files ok: $(grep -c . <<<"$rule_files") files and the comments of $(wc -w <<<"$scripts" | tr -d ' ') scripts"
exit "$failed"
