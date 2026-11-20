#!/usr/bin/env bash
# Prints the whole free-tier log: its own file, with each file of the folder beside it (decisions H130e, H483).
# Usage: free-tier.sh [file]   (from the repo root; default: factory/free-tier.md)
set -euo pipefail

file="${1:-factory/free-tier.md}"
if [ ! -s "$file" ]; then
  echo "$file: there is no such file" >&2
  exit 1
fi
folder="${file%.md}"
# The entries numbered in order come first, then each ticket's, both sorted as numbers: 98.md before 132.md.
names=$(for entry in "$folder"/*.md; do [ ! -f "$entry" ] || basename "$entry"; done \
  | awk '{ number = $0; first = sub(/^entry-/, "", number) ? 0 : 1; print first, number + 0, $0 }' \
  | sort -k1,1n -k2,2n | cut -d' ' -f3-)
set -- "$file"
while IFS= read -r name; do
  [ -z "$name" ] || set -- "$@" "$folder/$name"
done <<<"$names"

awk -v file="$file" '
  { sub(/\r$/, "") }
  FILENAME == file { frame[++lines] = $0; next }
  # A file of the folder, without the blank lines around its text: one is printed between files.
  FNR == 1 { section = "## Log"; first = 1; started = 0; held = 0 }
  /^[ \t]*$/ { if (started) held++; next }
  # A file that starts with a heading of the log holds that section; any other holds entries.
  first && /^## / { section = $0; from[section] = FILENAME; first = 0; next }
  {
    first = 0
    if (!(section in from)) from[section] = FILENAME
    if (!started && count[section] > 0) text[section, ++count[section]] = ""
    while (held > 0) { text[section, ++count[section]] = ""; held-- }
    started = 1
    text[section, ++count[section]] = $0
  }
  END {
    for (i = 1; i <= lines; i++) if (frame[i] ~ /^## /) known[frame[i]] = 1
    for (section in from)
      if (!(section in known)) {
        print file ": there is no \"" section "\" section to print " from[section] " under" > "/dev/stderr"
        lost = 1
      }
    if (lost) exit 1
    # A section'"'"'s files follow what this file holds of it, one blank line before them and one after.
    for (i = 1; i <= lines + 1; i++) {
      ends = i > lines || frame[i] ~ /^## /
      if (ends && count[current] > 0) {
        print ""
        for (j = 1; j <= count[current]; j++) print text[current, j]
        blank = i <= lines
      }
      if (i > lines) break
      if (frame[i] ~ /^[ \t]*$/) { blank++; continue }
      while (blank > 0) { print ""; blank-- }
      print frame[i]
      if (ends) current = frame[i]
    }
  }' "$@"
