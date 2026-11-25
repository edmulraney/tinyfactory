#!/usr/bin/env bash
# Checks that a Markdown file links each decision and free-tier entry it cites to its file (decisions H531a).
# Usage: check-citations.sh         (from the repo root)
#        check-citations.sh --fix   writes each missing or wrong link, and fails nothing it could write
set -euo pipefail

fix=0
[ "${1:-}" != --fix ] || fix=1

# A listing that failed is not a repo with no document in it (decisions H106). A new file is listed before it is added (decisions H464).
# git lists a file in conflict three times, and --fix would write it while reading it again.
if ! documents=$(git -c core.quotePath=false ls-files --cached --others --exclude-standard '*.md' | sort -u); then
  echo "check-citations.sh must be run inside a git repository: it could not list the Markdown files with git ls-files, so nothing was checked."
  exit 1
fi
# git still lists a file deleted in the working tree.
present=""
while IFS= read -r document; do
  [ ! -f "$document" ] || present+="$document"$'\n'
done <<<"$documents"
rows=$(grep -E '^(factory|product|architecture)/decisions/[^/]+\.md$' <<<"$present" || true)
entries=$(grep -E '^factory/free-tier/[^/]+\.md$' <<<"$present" || true)

# Each record's rows are read first, then every document; with no document, awk would wait for one typed in.
# No \b and no {n,m}: any awk runs this.
# shellcheck disable=SC2086
(IFS=$'\n'; ENTRIES="$entries" awk -v fix="$fix" '
  function trim(text) { gsub(/^[ \t]+|[ \t]+$/, "", text); return text }
  function folder_of(path) { return match(path, /\/[^\/]*$/) ? substr(path, 1, RSTART - 1) : "" }
  # The path of `target` as a link in the file `from` writes it, both given from the repo root.
  function relative(from, target,   a, b, depth, parts, i, same, path) {
    depth = split(folder_of(from), a, "/")
    parts = split(target, b, "/")
    same = 0
    while (same < depth && a[same + 1] == b[same + 1]) same++
    path = ""
    for (i = same; i < depth; i++) path = path "../"
    for (i = same + 1; i < parts; i++) path = path b[i] "/"
    return path b[parts]
  }
  # The file that holds what these words cite, or "" when they cite nothing the repo holds.
  function holder(words,   name) {
    if (words in row_file) return row_file[words]
    if (words !~ /^[Ee]ntry #?[1-9][0-9]*[a-z]?$/) return ""
    name = words
    sub(/^[Ee]ntry /, "", name)
    if (name ~ /^#/) { gsub(/[^0-9]/, "", name); name = "factory/free-tier/" name ".md" }
    else name = "factory/free-tier/entry-" name ".md"
    return name in entry_file ? name : ""
  }
  # Whether a citation can start after this character, and end before these two: not inside a word, a path or a file name.
  function starts(character) { return character !~ /[A-Za-z0-9_\/.=-]/ }
  function ends(two) { return two !~ /^([A-Za-z0-9_\/-]|\.[A-Za-z0-9]|\]\[)/ }
  # The line with each citation made a link; in a check, the line as it is, and each one reported.
  function linked(line,   out, rest, before, run, close_at, words, target, wanted, file, at) {
    out = ""
    rest = line
    before = ""
    while (rest != "") {
      if (!match(rest, /[`\[A-Ze]/)) { out = out rest; break }
      if (RSTART > 1) {
        out = out substr(rest, 1, RSTART - 1)
        before = substr(rest, RSTART - 1, 1)
        rest = substr(rest, RSTART)
      }
      words = ""
      if (rest ~ /^`/) {
        # A code span, which can hold no link, ends at the next run of as many backticks.
        match(rest, /^`+/)
        run = substr(rest, 1, RLENGTH)
        close_at = index(substr(rest, RLENGTH + 1), run)
        at = close_at ? RLENGTH + close_at + RLENGTH - 1 : RLENGTH
      } else if (match(rest, /^\[[^\]\[]*\]\([^()]*\)/)) {
        at = RLENGTH
        words = substr(rest, 2, index(rest, "](") - 2)
        target = substr(rest, index(rest, "](") + 2, at - index(rest, "](") - 2)
        # An image shows a file of its own.
        file = before == "!" ? "" : holder(words)
        wanted = file == "" ? target : relative(place, file)
        if (target != wanted) {
          found++
          if (fix) { out = out "[" words "](" wanted ")"; before = ")"; rest = substr(rest, at + 1); continue }
          print FILENAME ":" FNR ": the link of \"" words "\" names " target ", and from this file the file that holds it is " wanted
        } else if (file != "") links++
        words = ""
      } else if (starts(before) && match(rest, /^([A-Z][1-9][0-9]*[a-z]?|[Ee]ntry #?[1-9][0-9]*[a-z]?)/) \
        && ends(substr(rest, RLENGTH + 1, 2)) && holder(substr(rest, 1, RLENGTH)) != "") {
        at = RLENGTH
        words = substr(rest, 1, at)
        wanted = relative(place, holder(words))
        found++
        if (fix) { out = out "[" words "](" wanted ")"; before = ")"; rest = substr(rest, at + 1); continue }
        print FILENAME ":" FNR ": \"" words "\" is not a link: write [" words "](" wanted ")"
      } else at = 1
      out = out substr(rest, 1, at)
      before = substr(rest, at, 1)
      rest = substr(rest, at + 1)
    }
    return out
  }
  function close_file(   i) {
    if (changed) {
      printf "" > current
      for (i = 1; i <= count; i++) print lines[i] > current
      close(current)
      written++
    }
    changed = 0
    count = 0
  }
  BEGIN {
    total = split(ENVIRON["ENTRIES"], names, "\n")
    for (i = 1; i <= total; i++) entry_file[names[i]] = 1
  }
  phase == "rows" {
    sub(/\r$/, "")
    if (!/^\|/ || /^\| ID \|/ || /^\|---/) next
    split($0, cell, "|")
    id = trim(cell[2])
    if (id !~ /^[A-Z][1-9][0-9]*[a-z]?$/) next
    if ((id in row_file) && folder_of(row_file[id]) != folder_of(FILENAME)) {
      print FILENAME ":" FNR ": " id " is also a row in " row_file[id] ", so a citation of it could mean either: give one of them another ID"
      bad = 1
    }
    row_file[id] = FILENAME
    next
  }
  FNR == 1 {
    close_file()
    current = FILENAME
    fence = 0
    files++
    # A seed is linked from the place scaffold.sh copies it to (decisions H531c).
    place = FILENAME
    sub(/^\.claude\/skills\/bootstrap\/templates\//, "", place)
    holds_rows = place ~ /^(factory|product|architecture)\/decisions\/[^\/]+\.md$/
  }
  {
    ending = ""
    if (sub(/\r$/, "")) ending = "\r"
    line = $0
    if (line ~ /^[ \t]*(```|~~~)/) fence = !fence
    else if (!fence) {
      start = ""
      # The first cell of a row is the ID it defines, and cites nothing; so is that of a seed copied to a folder of rows (decisions H705).
      if (holds_rows && match(line, /^\|[^|]*\|/)) {
        start = substr(line, 1, RLENGTH - 1)
        line = substr(line, RLENGTH)
      }
      line = start linked(line)
    }
    if (line != $0) changed = 1
    lines[++count] = line ending
  }
  END {
    close_file()
    if (fix && found) print "check-citations.sh linked " found " citations in " written " files"
    else if (found) {
      print "A decision or a free-tier entry cited in a Markdown file is a link to the file that holds it (decisions H531a). `factory/scripts/check-citations.sh --fix` writes each link. A word that only reads like one (\"S3\", the store) goes in a code span."
      bad = 1
    }
    if (!bad) print "citations ok: " (links + (fix ? found : 0)) " links in " (files + 0) " Markdown files"
    exit bad
  }' phase=rows $rows phase=documents $present < /dev/null)
