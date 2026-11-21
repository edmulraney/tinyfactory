#!/usr/bin/env bash
# Fails when a file that the "Reference feature" section of ARCHITECTURE.md names is not in the repo (decisions H572a).
# Usage: check-reference-feature.sh   (from the repo root)
set -euo pipefail

document="ARCHITECTURE.md"
heading="## Reference feature"
if [ ! -f "$document" ]; then
  echo "$document: there is no such file, so no reference feature was checked"
  exit 1
fi

# A path is a code span that holds a slash (decisions H572b). Prints "<line> <path>" for each in the section.
if ! named=$(awk -v heading="$heading" '
  { sub(/\r$/, "") }
  /^## / { inside = ($0 == heading); if (inside) found = 1; next }
  inside {
    rest = $0
    while (match(rest, /`[^`]+`/)) {
      span = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
      if (index(span, "/")) print NR " " span
    }
  }
  END { if (!found) exit 3 }' "$document"); then
  echo "$document: it has no section \"$heading\". The section lists the files of one feature that the engineer reads before a build (decisions H572a)"
  exit 1
fi
if [ -z "$named" ]; then
  echo "$document: its section \"$heading\" names no file. Name each file in a code span, by its path from the repo root (decisions H572b)"
  exit 1
fi

failed=0
count=0
while IFS= read -r entry; do
  line=${entry%% *}
  path=${entry#* }
  count=$((count + 1))
  [ -e "$path" ] && continue
  echo "$document:$line: the section \"$heading\" names $path, and the repo holds no such file. Name the file that now shows the rule, by its path from the repo root, or write words that are no path outside a code span (decisions H572b)"
  failed=1
done <<<"$named"
[ "$failed" -eq 0 ] && echo "reference feature ok: $count files"
exit "$failed"
