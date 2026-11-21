#!/usr/bin/env bash
# Checks the shape of the free-tier log: its own file and each file of the folder beside it (decisions H105c, H483).
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
# The log main holds, in its own file or the folder: one that holds no numbered entry makes all of them new.
held=""
if [ -n "$tip" ]; then
  held=$(git grep -h -E '^### [1-9][0-9]*\. ' "$tip" -- "$file" "$folder" 2>/dev/null | awk 'END { print NR }' || true)
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
      echo "$entry: this file is empty, and a file here holds entries or a section of the log"
      failed=1
    elif [ -f "$entry" ] && [[ "$entry" != *.md ]]; then
      echo "$entry: a file here is named \"<name>.md\", and free-tier.sh prints no other, so this one would be left out of the log"
      failed=1
    elif [ -f "$entry" ]; then
      set -- "$@" "$entry"
    elif [ -e "$entry" ]; then
      echo "$entry: only files belong beside the log, and this is no file"
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
  function open_entry(name) {
    if (blank != FNR - 1) problem(FNR, "the heading of entry " name " needs a blank line above it")
    entry = name
    entry_file = FILENAME
    start = FNR
    automated = 0
    last = ""
  }
  function close_file() {
    close_entry("")
    if ((kind == "ticket" || kind == "numbered") && entries == 0) { print previous_file ": this file holds no entry"; bad = 1 }
  }
  { sub(/\r$/, "") }
  FNR == 1 {
    close_file()
    previous_file = FILENAME
    blank = 0
    entries = 0
    # A file of the folder is named for what it holds: a ticket, a numbered entry, or a section.
    name = FILENAME == file ? "" : substr(FILENAME, length(folder) + 2)
    owner = name
    gsub(/[^0-9]/, "", owner)
    if (name == "") kind = "frame"
    else if (name ~ /^[1-9][0-9]*\.md$/) kind = "ticket"
    else if (name ~ /^entry-[1-9][0-9]*\.md$/) {
      kind = "numbered"
      numbered[owner + 0] = 1
      if (owner + 0 > highest) highest = owner + 0
    } else {
      kind = "section"
      if (!($0 in sections) || $0 == "## Log")
        problem(FNR, "a file named for no ticket (\"62.md\") and no numbered entry (\"entry-8.md\") holds a section of the log other than Log, and starts with its heading, as it is in " file)
      else if ($0 in holder) problem(FNR, "the section \"" $0 "\" is already in " holder[$0])
      else holder[$0] = FILENAME
      next
    }
  }

  # The log'"'"'s own file: how an entry is written, then the headings of its sections (decisions H483).
  kind == "frame" {
    if (/^## /) { sections[$0] = 1; in_sections = 1; reported = 0 }
    else if (in_sections && !reported && $0 !~ /^[ \t]*$/) {
      problem(FNR, "this file holds only how an entry is written and the headings of the log, and this line goes in a file of " folder "/: " substr($0, 1, 60))
      reported = 1
    }
    next
  }
  kind == "section" {
    if (/^#+ /) problem(FNR, "a section'"'"'s file holds its one heading, on its first line, and this is another: " substr($0, 1, 60))
    next
  }

  /^#+ / {
    id = ""
    if ($0 ~ (kind == "ticket" ? "^### #[1-9][0-9]*[a-z]?\\. [^ ]" : "^### [1-9][0-9]*\\. [^ ]")) { id = $2; sub(/\.$/, "", id) }
    close_entry(id == "" ? "one with no name" : id)
    if (id == "") {
      if (kind == "ticket") problem(FNR, "a heading in a ticket'"'"'s file is \"### #<ticket>. <title>\", and this is not: " substr($0, 1, 60))
      else problem(FNR, "the heading in " name " is \"### " owner ". <title>\", and this is not: " substr($0, 1, 60))
      open_entry("?")
      next
    }
    count++
    entries++
    number = id
    gsub(/[^0-9]/, "", number)
    if (number != owner && kind == "ticket")
      problem(FNR, "entry " id " is named after ticket #" number ", and " name " holds the entries of ticket #" owner " (#" owner ", or #" owner "a, #" owner "b for several)")
    else if (number != owner)
      problem(FNR, "entry " id " does not belong in " name ", which is named for entry " owner)
    else if (id in used) problem(FNR, "entry " id " is already at " used[id])
    else {
      used[id] = FILENAME ":" FNR
      # An entry main does not hold is named after the ticket that adds it (decisions H132b).
      if (kind == "numbered" && held != "" && number + 0 > held + 0)
        problem(FNR, "entry " number " is new, and a new entry is named after the ticket that adds it: it goes in " folder "/<ticket>.md, headed \"### #<ticket>. <title>\"; decisions H132a")
    }
    open_entry(id)
    next
  }

  /^[ \t]*$/ { blank = FNR; next }
  entry != "" {
    last = $0
    if ($0 ~ /^- \*\*Automated:\*\*/) automated++
    next
  }
  { problem(FNR, "only entries belong in this file, and this line is in none: " substr($0, 1, 60)) }
  END {
    close_file()
    if (!("## Log" in sections)) { print file ": there is no \"## Log\" section"; bad = 1 }
    for (number = 1; number < highest; number++)
      if (!(number in numbered)) { print folder "/entry-" number ".md: there is no such file, and the numbered entries count 1, 2, 3 with no gap"; bad = 1 }
    if (!bad && !failed) print "free-tier log ok: " (count + 0) " entries"
    exit bad
  }' "$@" || failed=1
exit "$failed"
