#!/usr/bin/env bash
# Prints the whole free-tier log: its file, with each ticket's entry from the folder beside it (decisions H130e).
# Usage: free-tier.sh [file]   (from the repo root; default: factory/free-tier.md)
set -euo pipefail

file="${1:-factory/free-tier.md}"
if [ ! -s "$file" ]; then
  echo "$file: there is no such file" >&2
  exit 1
fi
folder="${file%.md}"
# A file is named for its ticket, so the names sort as numbers: 98.md before 132.md.
names=$(for entry in "$folder"/*.md; do [ ! -f "$entry" ] || basename "$entry"; done | sort -n)
set -- "$file"
while IFS= read -r name; do
  [ -z "$name" ] || set -- "$@" "$folder/$name"
done <<<"$names"

awk -v file="$file" '
  { sub(/\r$/, "") }
  FILENAME == file {
    frame[++lines] = $0
    # The entries go where the Log section ends: at the next section, or the end of the file.
    if (/^## /) {
      if (in_log && !after) after = lines
      in_log = $0 == "## Log"
      if (in_log) found = 1
    }
    next
  }
  # A ticket'"'"'s file, without the blank lines around its text: one is printed between entries.
  FNR == 1 { held = 0; started = 0 }
  /^[ \t]*$/ { if (started) held++; next }
  {
    if (!started) entries[++count] = ""
    else while (held > 0) { entries[++count] = ""; held-- }
    started = 1
    held = 0
    entries[++count] = $0
  }
  END {
    if (!found) {
      print file ": there is no \"## Log\" section to print the entries under" > "/dev/stderr"
      exit 1
    }
    if (!after) after = lines + 1
    last = after - 1
    if (count > 0) while (last > 0 && frame[last] ~ /^[ \t]*$/) last--
    for (i = 1; i <= last; i++) print frame[i]
    for (i = 1; i <= count; i++) print entries[i]
    if (count > 0 && after <= lines) print ""
    for (i = after; i <= lines; i++) print frame[i]
  }' "$@"
