#!/usr/bin/env bash
# Checks that the free-tier log, and each ticket's file of entries beside it, keep their shape (decisions H105c, H130e).
# Usage: check-free-tier.sh [file]   (from the repo root; default: factory/free-tier.md)
set -euo pipefail

file="${1:-factory/free-tier.md}"
if [ ! -f "$file" ]; then
  echo "$file: there is no such file"
  exit 1
fi
folder="${file%.md}"

# Main says which numbered entries are new. Unread, that one rule is skipped with a note (decisions H105b).
branch="${GITHUB_BASE_REF:-main}"
tip=""
if git rev-parse --git-dir >/dev/null 2>&1 \
  && ! tip=$(git rev-parse --quiet --verify "origin/$branch^{commit}" 2>/dev/null); then
  depth=""
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != true ] || depth="--depth=1"
  # shellcheck disable=SC2086
  git fetch --quiet $depth origin "$branch" 2>/dev/null && tip=$(git rev-parse FETCH_HEAD) || tip=""
fi
# A log main does not hold has no numbered entry: all of them are new.
held=""
if [ -n "$tip" ]; then
  held=$(git show "$tip:./$file" 2>/dev/null | awk '
    { sub(/\r$/, "") }
    /^## / { in_log = $0 == "## Log" }
    in_log && /^### [1-9][0-9]*\. / { count++ }
    END { print count + 0 }' || true)
else
  echo "origin/$branch could not be read, so the numbered entries were not checked for a new one"
fi

failed=0
# Tracked by git or not: a file an engineer has just written is checked before it is committed.
set -- "$file"
if [ -d "$folder" ]; then
  for entry in "$folder"/*; do
    if [ -f "$entry" ] && [ ! -s "$entry" ]; then
      # awk never opens an empty file, so it is refused here.
      echo "$entry: a ticket's file holds at least one entry"
      failed=1
    elif [ -f "$entry" ]; then
      set -- "$@" "$entry"
    elif [ -e "$entry" ]; then
      echo "$entry: only the files of tickets belong beside the log, and this is no file"
      failed=1
    fi
  done
fi

awk -v file="$file" -v folder="$folder" -v held="$held" -v failed="$failed" '
  function problem(line, text) { print FILENAME ":" line ": " text; bad = 1 }
  # Closes the entry being read; `next_entry` is the name of the one that follows it, if any.
  function close_entry(next_entry) {
    if (entry == "") return
    if (automated > 1) {
      print entry_file ":" start ": entry " entry " has " automated " Automated lines, and an entry has one (a merge often leaves the entry before it without its own)"
      bad = 1
    } else if (automated == 0 || last !~ /^- \*\*Automated:\*\*/) {
      print entry_file ":" start ": entry " entry " does not end with its Automated line" (next_entry == "" ? "" : " (a merge often puts the next entry, " next_entry ", in front of it)")
      bad = 1
    }
    entry = ""
  }
  # Opens the entry whose heading is this line.
  function open_entry(name) {
    if (blank != FNR - 1) problem(FNR, "the heading of entry " name " needs a blank line above it")
    entry = name
    entry_file = FILENAME
    start = FNR
    automated = 0
    last = ""
  }
  # Before the first line of each file: the entry the last file ended with, and that file itself.
  function close_file() {
    close_entry("")
    if (ticket != "" && entries == 0) { print previous_file ": a ticket'"'"'s file holds at least one entry"; bad = 1 }
  }
  { sub(/\r$/, "") }
  FNR == 1 {
    close_file()
    previous_file = FILENAME
    blank = 0
    in_log = 0
    entries = 0
    ticket = ""
    if (FILENAME != file) {
      # A file in the folder is named for the ticket whose entry it holds.
      ticket = substr(FILENAME, length(folder) + 2)
      if (ticket ~ /^[1-9][0-9]*\.md$/) sub(/\.md$/, "", ticket)
      else {
        problem(FNR, "a file here holds one ticket'"'"'s entry and is named for it, like \"62.md\"")
        ticket = "?"
      }
    }
  }

  # The log'"'"'s own file: the entries numbered in order, under "## Log".
  FILENAME == file && /^## / {
    close_entry("")
    in_log = $0 == "## Log"
    if (in_log) found = 1
  }
  FILENAME == file && in_log && /^### #[1-9][0-9]*[a-z]?\. / {
    id = $2
    sub(/\.$/, "", id)
    close_entry(id)
    number = id
    gsub(/[^0-9]/, "", number)
    problem(FNR, "entry " id " is named after its ticket, so it goes in " folder "/" number ".md, and this file holds only the entries numbered in order")
    open_entry(id)
    next
  }
  FILENAME == file && in_log && /^###/ {
    number = ""
    if ($0 ~ /^### [1-9][0-9]*\. [^ ]/) { number = $2; sub(/\.$/, "", number) }
    close_entry(number == "" ? "one with no number" : number)
    if (number == "") problem(FNR, "a heading under Log is \"### <n>. <title>\", and this is not: " substr($0, 1, 60))
    else {
      count++
      if (number != previous + 1)
        problem(FNR, "entry " number " follows " (previous == 0 ? "the Log heading" : "entry " previous) ", and should be entry " (previous + 1) ": entries count 1, 2, 3 with no gap or repeat")
      # An entry main does not hold is named after the ticket that adds it (decisions H132b).
      else if (held != "" && number + 0 > held + 0)
        problem(FNR, "entry " number " is new, and a new entry is named after the ticket that adds it: it goes in " folder "/<ticket>.md, headed \"### #<ticket>. <title>\"; decisions H132a")
      previous = number
    }
    open_entry(number == "" ? "?" : number)
    next
  }

  # A ticket'"'"'s file: its entries, and nothing else.
  FILENAME != file && /^#+ / {
    id = ""
    if ($0 ~ /^### #[1-9][0-9]*[a-z]?\. [^ ]/) { id = $2; sub(/\.$/, "", id) }
    close_entry(id == "" ? "one with no name" : id)
    if (id == "") {
      problem(FNR, "a heading in a ticket'"'"'s file is \"### #<ticket>. <title>\", and this is not: " substr($0, 1, 60))
      open_entry("?")
      next
    }
    count++
    entries++
    number = id
    gsub(/[^0-9]/, "", number)
    if (ticket != "?" && number != ticket)
      problem(FNR, "entry " id " is named after ticket #" number ", and " ticket ".md holds the entries of ticket #" ticket " (#" ticket ", or #" ticket "a, #" ticket "b for several)")
    else if (id in used) problem(FNR, "entry " id " is already at " used[id])
    else used[id] = FILENAME ":" FNR
    open_entry(id)
    next
  }

  /^[ \t]*$/ { blank = FNR; next }
  entry != "" {
    last = $0
    if ($0 ~ /^- \*\*Automated:\*\*/) automated++
    next
  }
  FILENAME != file { problem(FNR, "only entries belong in a ticket'"'"'s file, and this line is in none: " substr($0, 1, 60)) }
  END {
    close_file()
    if (!found) { print file ": there is no \"## Log\" section"; bad = 1 }
    if (!bad && !failed) print "free-tier log ok: " (count + 0) " entries"
    exit bad
  }' "$@" || failed=1
exit "$failed"
