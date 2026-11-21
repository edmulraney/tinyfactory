#!/usr/bin/env bash
# Prints a decision record, each ticket's rows under their section, or only the rows asked for (decisions H130a, H579).
# Usage: decisions.sh [record]                    (from the repo root; default: factory/decisions.md)
#        decisions.sh <record> <ID or word>...    the rows with those IDs and the rows that hold a word, in any case
set -euo pipefail

record="${1:-factory/decisions.md}"
if [ ! -s "$record" ]; then
  echo "$record: there is no such decision record" >&2
  exit 1
fi
[ $# -eq 0 ] || shift
wanted=""
for term in "$@"; do
  if [ -z "$term" ] || [[ "$term" == *$'\n'* ]]; then
    echo "$record: an ID or word to look for is empty or holds a line break" >&2
    exit 1
  fi
  wanted+="$term"$'\n'
done
export wanted
folder="${record%.md}"
set -- "$record"
for file in "$folder"/*.md; do
  [ ! -f "$file" ] || set -- "$@" "$file"
done

awk -F'|' -v record="$record" '
  # before(a, b): whether the row with ID a comes before the one with ID b: T9, T10, T50a, T50b.
  function before(a, b) {
    if (number[a] != number[b]) return number[a] < number[b]
    return a < b
  }
  { sub(/\r$/, "") }
  FILENAME == record { frame[++lines] = $0; next }
  !/^\|/ || /^\| ID \|/ || /^\|---/ { next }
  {
    id = $2
    gsub(/[ \t]/, "", id)
    digits = id
    gsub(/[^0-9]/, "", digits)
    number[id] = digits + 0
    letter = substr(id, 1, 1)
    # Kept in order as they arrive: an insertion sort, on the few rows one section holds.
    at = ++rows[letter]
    while (at > 1 && before(id, ids[letter, at - 1])) {
      ids[letter, at] = ids[letter, at - 1]
      text[letter, at] = text[letter, at - 1]
      at--
    }
    ids[letter, at] = id
    text[letter, at] = $0
    from[letter] = FILENAME
  }
  END {
    for (i = 1; i <= lines; i++)
      if (frame[i] ~ /^## [A-Z]: /) section[substr(frame[i], 4, 1)] = 1
    for (letter in rows)
      if (!(letter in section)) {
        print record ": no section has the letter " letter ", which " ids[letter, 1] " in " from[letter] " starts with" > "/dev/stderr"
        lost = 1
      }
    if (lost) exit 1
    terms = split(ENVIRON["wanted"], term, "\n") - 1
    if (terms > 0) {
      for (i = 1; i <= lines; i++) {
        if (frame[i] !~ /^## [A-Z]: /) continue
        current = substr(frame[i], 4, 1)
        for (at = 1; at <= rows[current]; at++) {
          keep = 0
          for (t = 1; t <= terms; t++) {
            if (term[t] ~ /^[A-Z][0-9]+[a-z]?$/) match_found = ids[current, at] == term[t]
            else match_found = index(tolower(text[current, at]), tolower(term[t])) > 0
            if (match_found) keep = found[t] = 1
          }
          if (keep) picked[++picks] = text[current, at]
        }
      }
      for (t = 1; t <= terms; t++)
        if (!(t in found)) {
          if (term[t] ~ /^[A-Z][0-9]+[a-z]?$/) {
            print record ": no row has the ID " term[t] > "/dev/stderr"
            lost = 1
          } else print record ": no row holds \"" term[t] "\"" > "/dev/stderr"
        }
      if (lost) exit 1
      for (i = 1; i <= picks; i++) print picked[i]
      exit 0
    }
    for (i = 1; i <= lines; i++) {
      print frame[i]
      if (frame[i] ~ /^## [A-Z]: /) current = substr(frame[i], 4, 1)
      else if (frame[i] ~ /^\|---/ && current != "") {
        for (at = 1; at <= rows[current]; at++) print text[current, at]
        printed[current] = 1
        current = ""
      }
    }
    for (letter in rows)
      if (!(letter in printed)) {
        print record ": the section with the letter " letter " has no table for its rows" > "/dev/stderr"
        lost = 1
      }
    exit lost
  }' "$@"
