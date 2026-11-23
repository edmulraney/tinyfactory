#!/usr/bin/env bash
# Keeps facts that change by themselves out of rule files and script comments, and keeps rule files short.
# Usage: check-rule-files.sh          (from the repo root)
#        check-rule-files.sh --over   prints "<words> <budget> <file>" for each rule file over its budget, and checks
#                                     only the list; it needs no git repository
set -euo pipefail

only_over=false
[ "${1:-}" != --over ] || only_over=true

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
skills=""; scripts=""
if [ "$only_over" = false ]; then
  # A new file is listed before it is added (decisions H464).
  skills=$(git ls-files --cached --others --exclude-standard '.claude/skills/*/SKILL.md') || unlisted "skills"
  # The tests' own files are left out (decisions H172d).
  scripts=$(git ls-files --cached --others --exclude-standard 'factory/scripts/*.sh' '.claude/skills/bootstrap/scripts/*.sh') || unlisted "scripts"
fi

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
    # A private repository has no SECURITY.md, and one with no interface no DESIGN.md (decisions U563r, H501a).
    # The factory's own repository holds no app, so it has no GLOSSARY.md of domain words either.
    case "$file" in SECURITY.md | DESIGN.md | GLOSSARY.md) continue ;; esac
    echo "$list:$number: $file is not a file: take the line out, or correct its path"
    failed=1
    continue
  fi
  rule_files+="$file"$'\n'
  words=$(wc -w < "$file" | tr -d ' ')
  [ "$words" -gt "$budget" ] || continue
  if [ "$only_over" = true ]; then
    echo "$words $budget $file"
  # More than a fifth over fails; less merges, and a ticket cuts the file afterwards (decisions H172b, H476a).
  elif [ $((words * 5)) -gt $((budget * 6)) ]; then
    echo "$file: it holds $words words and its budget is $budget, and lint fails a file more than a fifth over its budget. Cut it: a line stays only when an agent needs it to do its work well, to avoid a mistake or to save tokens (TASTE.md)"
    failed=1
  else
    echo "$file: it holds $words words and its budget is $budget. This fails nothing: once the pull request merges, the factory files a ticket that cuts the file to its budget"
  fi
done < "$list"
[ "$only_over" = false ] || exit "$failed"

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
