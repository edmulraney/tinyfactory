#!/usr/bin/env bash
# Prints the whole factory guide: factory/README.md with each list's entries from its folder (decisions H484a).
# Usage: readme.sh [file]   (from the repo root; default: factory/README.md)
set -euo pipefail

file="${1:-factory/README.md}"
if [ ! -s "$file" ]; then
  echo "$file: there is no such file" >&2
  exit 1
fi
folder="${file%.md}"
# Sorted the same on every machine, whatever its language (decisions H484c).
export LC_ALL=C
set -- "$file"
for entry in "$folder"/*; do
  [ -e "$entry" ] || continue
  if [ ! -d "$entry" ]; then
    echo "$entry: an entry is a file in the folder of its list, as $folder/known-gaps/<entry>.md is, and this is in no list's folder" >&2
    exit 1
  fi
  for inner in "$entry"/*; do
    [ -e "$inner" ] || continue
    case "$inner" in
      *.md) [ -f "$inner" ] && set -- "$@" "$inner" && continue ;;
    esac
    echo "$inner: an entry is a file named <entry>.md, and this is not one" >&2
    exit 1
  done
done

awk -v file="$file" '
  # The folder of a list is named after its heading: "## Known gaps" has known-gaps (decisions H484b).
  function folder_of(heading) {
    heading = tolower(heading)
    sub(/^## +/, "", heading)
    gsub(/[^a-z0-9]+/, "-", heading)
    gsub(/^-|-$/, "", heading)
    return heading
  }
  # Ends a list: its entries follow its last line, as rows of its table when that line is one.
  function close_list(last) {
    if (list != "" && count[list] > 0) {
      if (!table[list]) print ""
      for (i = 1; i <= count[list]; i++) print entries[list, i]
      blank = last ? 0 : 1
    }
    for (; blank > 0; blank--) print ""
  }
  { sub(/\r$/, "") }
  FILENAME == file { frame[++lines] = $0; next }
  /^[ \t]*$/ { next }
  {
    list = FILENAME
    sub(/\/[^\/]*$/, "", list)
    sub(/.*\//, "", list)
    entries[list, ++count[list]] = $0
    from[list] = FILENAME
    if ($0 ~ /^\|/) rows[list]++
  }
  END {
    for (n = 1; n <= lines; n++) {
      if (frame[n] ~ /^## /) { list = folder_of(frame[n]); known[list] = 1 }
      if (frame[n] !~ /^[ \t]*$/) { table[list] = frame[n] ~ /^\|/; last[list] = frame[n] }
    }
    for (list in count) {
      if (!(list in known)) {
        print file ": no heading has the folder " list ", which holds " from[list] ". A list is a \"## \" heading in " file ", and its folder is the heading in small letters with a hyphen for each space" > "/dev/stderr"
        lost = 1
      } else if (last[list] ~ /^(\|[^-]|[-*] )/) {
        # An entry kept in the shared file is a second place to add one (decisions H484f).
        print file ": the list with the folder " list " ends with an entry in " file " itself. Move it to a file of its own in that folder: " last[list] > "/dev/stderr"
        lost = 1
      } else if (table[list] && rows[list] != count[list]) {
        print file ": the list with the folder " list " is a table, and each line of an entry of it is a row, which begins with \"|\"" > "/dev/stderr"
        lost = 1
      }
    }
    if (lost) exit 1
    list = ""
    for (n = 1; n <= lines; n++) {
      if (frame[n] ~ /^[ \t]*$/) { blank++; continue }
      if (frame[n] ~ /^## /) {
        close_list(0)
        list = folder_of(frame[n])
      } else for (; blank > 0; blank--) print ""
      print frame[n]
    }
    close_list(1)
  }' "$@"
