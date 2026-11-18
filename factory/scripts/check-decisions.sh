#!/usr/bin/env bash
# Checks that a decision record, its file and the folder of its tickets' rows, keeps its format.
# Usage: check-decisions.sh [record...]   (from the repo root; default: both records)
set -euo pipefail

[ $# -gt 0 ] || set -- factory/decisions.md product/decisions.md

# The header every record carries under its title, word for word (decisions H11).
header='- One row per decision, and nothing else: no paragraph, list or note. This file holds only the sections; `factory/scripts/decisions.sh <this file>` prints the whole record.
- **File:** a ticket'"'"'s rows go in `decisions/<ticket>.md` beside this file (`setup.md` for a Source of `setup`), as tables with a section'"'"'s columns and no heading. A pull request adds its own file and edits no shared one.
- **ID:** the section'"'"'s letter and the number of the ticket adding the row (`T62`), with a letter after it when the ticket adds several to one section (`A69a`, `A69b`); never renumbered or reused. Rows numbered in order (`T4`) came first and keep their IDs. Everything cites a decision by its ID.
- **Decision:** what is true now, in one present-tense sentence of 25 words or fewer. **Why:** the one reason to keep it, in one sentence of 30 or fewer.
- **Rejected:** each alternative turned down, with its reason, in 30 words or fewer; never empty, or the row is a description and belongs in a comment.
- **Source:** the tickets that hold the story (`#47`), or `setup`. The row alone gives the reason; a row over a limit is several decisions, so split it.
- A changed decision is rewritten in the file it lives in and keeps its ID; its old choice moves to Rejected. "To revisit" rows (Idea, Parked because, Revisit when) keep the same limits.'

# main is fetched where the checkout holds none, and --depth would cut a full clone short (decisions H105b).
branch="${GITHUB_BASE_REF:-main}"
tip=""
if git rev-parse --git-dir >/dev/null 2>&1 \
  && ! tip=$(git rev-parse --quiet --verify "origin/$branch^{commit}" 2>/dev/null); then
  depth=""
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != true ] || depth="--depth=1"
  # shellcheck disable=SC2086
  git fetch --quiet $depth origin "$branch" 2>/dev/null && tip=$(git rev-parse FETCH_HEAD) || tip=""
fi
[ -n "$tip" ] || echo "origin/$branch could not be read, so new rows were not checked for their ticket's number"

failed=0
rows=0
records=$#
for record in "$@"; do
  if [ ! -f "$record" ]; then
    echo "$record: there is no such decision record"
    failed=1
    continue
  fi
  if [ ! -s "$record" ]; then
    echo "$record: the record is empty"
    failed=1
    continue
  fi
  folder="${record%.md}"
  # Untracked files too: a file an engineer has just written is checked before it is committed.
  set -- "$record"
  if [ -d "$folder" ]; then
    for file in "$folder"/*; do
      if [ -f "$file" ] && [ ! -s "$file" ]; then
        # awk never opens an empty file, so it is refused here.
        echo "$file: a ticket's file holds at least one row"
        failed=1
      elif [ -f "$file" ]; then
        set -- "$@" "$file"
      elif [ -e "$file" ]; then
        echo "$file: only the files of tickets belong beside a record, and this is no file"
        failed=1
      fi
    done
  fi
  # The rows main holds were in the record's own file before they had a folder (decisions H130a).
  on_main=""
  if [ -n "$tip" ]; then
    on_main=$(git grep -h -e '^|' "$tip" -- "./$record" "./$folder" 2>/dev/null \
      | awk -F'|' '{ gsub(/[ \t\r]/, "", $2); print $2 }' || true)
  fi
  status=0
  report=$(HEADER="$header" ON_MAIN="$on_main" awk -v record="$record" -v folder="$folder" -v compare="${tip:+1}" '
    function problem(text) { print FILENAME ":" FNR ": " text; bad = 1 }
    function trim(text) { gsub(/^[ \t]+|[ \t]+$/, "", text); return text }
    function words(text,   parts) { return split(trim(text), parts, /[ \t]+/) }
    BEGIN {
      lines = split(ENVIRON["HEADER"], expected, "\n")
      columns["| ID | Decision | Why | Rejected | Source |"] = "Decision|Why|Rejected"
      columns["| ID | Idea | Parked because | Revisit when | Source |"] = "Idea|Parked because|Revisit when"
      starts = "\"| ID | Decision | Why | Rejected | Source |\" or \"| ID | Idea | Parked because | Revisit when | Source |\""
      limit[2] = 25; limit[3] = 30; limit[4] = 30
      ids = split(ENVIRON["ON_MAIN"], held, "\n")
      for (i = 1; i <= ids; i++) on_main[held[i]] = 1
    }
    { sub(/\r$/, "") }
    FNR == 1 {
      table = 0
      if (FILENAME != record) {
        # A file in the folder is named for the ticket whose rows it holds.
        ticket = substr(FILENAME, length(folder) + 2)
        if (ticket ~ /^([1-9][0-9]*|setup)\.md$/) sub(/\.md$/, "", ticket)
        else {
          problem("a file here holds one ticket'"'"'s rows and is named for it, like \"62.md\", or \"setup.md\"")
          ticket = ""
        }
        files[FILENAME] = 0
      }
    }

    # The record'"'"'s own file: the title, the header, and each section with its empty table.
    FILENAME == record && FNR == 1 {
      if ($0 !~ /^# [^ ]/) problem("the first line is the title, \"# ...\"")
      next
    }
    /^[ \t]*$/ { table = 0; next }
    FILENAME == record && seen < lines && !/^## / && !/^\|/ {
      seen++
      if ($0 != expected[seen]) problem("line " seen " of the header must read: " expected[seen])
      next
    }
    FILENAME == record && seen < lines {
      problem("the header is missing its line " (seen + 1) ": " expected[seen + 1])
      seen = lines
    }
    FILENAME == record && /^## / {
      table = 0
      letter = ""
      if ($0 !~ /^## [A-Z]: [^ ]/) problem("a section heading is its letter and its name, like \"## T: Tickets and state\"")
      else if (substr($0, 4, 1) in home) problem("the letter " substr($0, 4, 1) " already belongs to \"" home[substr($0, 4, 1)] "\"")
      else { letter = substr($0, 4, 1); home[letter] = $0 }
      headed = 1
      next
    }
    FILENAME == record && !/^\|/ {
      problem("only the header, headings and their tables belong in a record, and this is none of them: " substr($0, 1, 60))
      next
    }
    FILENAME == record && table == 0 {
      if (!headed) problem("a table needs a \"## \" heading above it")
      if (!($0 in columns)) problem("a table starts with " starts)
      else if (letter != "") kind[letter] = $0
      table = 1
      next
    }
    FILENAME == record && table == 1 {
      if ($0 != "|---|---|---|---|---|") problem("the line under a table'"'"'s column names is \"|---|---|---|---|---|\"")
      table = 2
      next
    }
    FILENAME == record {
      problem("a row goes in the file of the ticket that adds it, " folder "/<ticket>.md, and this file holds only the sections")
      next
    }

    # A ticket'"'"'s file: tables of rows, and nothing else.
    !/^\|/ {
      problem("only tables of rows belong in a ticket'"'"'s file, and this is none of them: " substr($0, 1, 60))
      next
    }
    table == 0 {
      if (!($0 in columns)) {
        problem("a table starts with " starts)
        heads = ""
        split("Decision|Why|Rejected", name, "|")
      } else {
        heads = $0
        split(columns[$0], name, "|")
      }
      table = 1
      next
    }
    table == 1 {
      if ($0 != "|---|---|---|---|---|") problem("the line under a table'"'"'s column names is \"|---|---|---|---|---|\"")
      table = 2
      next
    }
    {
      count++
      files[FILENAME]++
      row = $0
      # An escaped bar is text inside a cell, as GitHub reads it.
      gsub(/\\\|/, "\001", row)
      sub(/^\|/, "", row)
      if (row !~ /\|[ \t]*$/) { problem("a table row ends with \"|\""); next }
      sub(/\|[ \t]*$/, "", row)
      cells = split(row, cell, "|")
      if (cells != 5) { problem("a row has 5 cells, and this one has " cells); next }
      for (i = 1; i <= 5; i++) cell[i] = trim(cell[i])
      id = cell[1]
      row_name = id == "" ? "this row" : id
      named = 0
      if (id == "") problem(row_name ": ID is empty")
      # Both forms of ID: a row numbered in order (T4), and one named after its ticket (T62, A69a; decisions H95a).
      else if (id !~ /^[A-Z][1-9][0-9]*[a-z]?$/) problem(row_name ": ID is a capital letter and a number, with at most one small letter after it, like T4 or A69a")
      else {
        named = 1
        # Across every file of the record: two tickets that both rewrote a row, or took one ID.
        if (id in used) problem(row_name ": ID is already used at " used[id])
        else used[id] = FILENAME ":" FNR
        initial = substr(id, 1, 1)
        if (!(initial in home))
          problem(row_name ": ID starts with the letter of its section, and " record " has no section with the letter " initial)
        else if (heads != "" && (initial in kind) && kind[initial] != heads)
          problem(row_name ": rows of \"" home[initial] "\" go in a table that starts with \"" kind[initial] "\"")
      }
      for (i = 2; i <= 4; i++) {
        if (cell[i] == "") problem(row_name ": " name[i - 1] " is empty")
        else if (words(cell[i]) > limit[i]) problem(row_name ": " name[i - 1] " is " words(cell[i]) " words, and the limit is " limit[i])
      }
      if (cell[5] == "") problem(row_name ": Source is empty")
      else if (cell[5] !~ /^(setup|#[1-9][0-9]*(, #[1-9][0-9]*)*)$/) problem(row_name ": Source is ticket numbers (\"#47\" or \"#39, #47\") or \"setup\"")
      else if (ticket != "") {
        # A row lives in the file of a ticket its Source names: the one that added it, or one
        # that has since rewritten it and moved it (decisions H130c).
        if (ticket == "setup") {
          if (cell[5] != "setup") problem(row_name ": setup.md holds the rows whose Source is \"setup\", and this one goes in the file of a ticket in its Source (" cell[5] ")")
        } else if (cell[5] == "setup") problem(row_name ": a row whose Source is \"setup\" goes in setup.md")
        else if (!index(", " cell[5] ",", ", #" ticket ",")) problem(row_name ": " ticket ".md holds the rows of ticket #" ticket ", and the Source of this one (" cell[5] ") does not name it")
        if (compare && named && !(id in on_main)) {
          # A row main does not hold is named after the ticket that adds it, which is its file'"'"'s
          # (decisions H105a).
          number = id
          gsub(/[^0-9]/, "", number)
          initial = substr(id, 1, 1)
          if (ticket == "setup")
            problem(row_name ": a new row goes in the file of the ticket that adds it and is named after it, and setup.md takes no new row; decisions H95a")
          else if (number != ticket)
            problem(row_name ": a new row is named after the ticket that adds it (it is in " ticket ".md, so " initial ticket ", or " initial ticket "a, " initial ticket "b for several); decisions H95a")
        }
      }
    }
    END {
      if (seen < lines) { print record ": the header is missing its line " (seen + 1) ": " expected[seen + 1]; bad = 1 }
      for (file in files) if (files[file] == 0) { print file ": a ticket'"'"'s file holds at least one row"; bad = 1 }
      print "rows " (count + 0)
      exit bad
    }' "$@") || status=$?
  if [ "$status" -ne 0 ]; then
    grep -v '^rows ' <<<"$report" || true
    failed=1
  fi
  # The count is absent when awk itself broke, and its exit code has already failed the check.
  rows=$((rows + $(sed -n 's/^rows //p' <<<"$report" | grep . || echo 0)))
done
[ "$failed" -eq 0 ] && echo "decision records ok: $rows rows in $records records"
exit "$failed"
