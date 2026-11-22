#!/usr/bin/env bash
# Posts Peta's comment on an idea, and refuses one that is too long, asks the owner too much or is half a proposal.
# Usage: propose.sh <idea> <file>   (needs GH_TOKEN)
#        A comment holds 250 words at most, and three lines under its heading "Needs you" at most.
#        A proposal, a comment with the heading "## Should it be built" or "## Tickets", opens with the first, which
#        names `product/`: a file there, or that it holds nothing on the idea. Under the second it holds a numbered line.
#        Under "## Journey" it holds the journey's name, then its map: rows "- <screen>, <state>: <what a person sees>",
#        each naming "(slice <n>)", a numbered line under "## Tickets", or saying "unchanged". The map's words are not counted.
#        A refused comment is not posted, and the output says the count and the limit.
set -euo pipefail

idea="${1:?Usage: propose.sh <idea> <file>}"
file="${2:?Usage: propose.sh <idea> <file>}"
[ -f "$file" ] || { echo "propose.sh: $file is not a file." >&2; exit 1; }

# The owner reads every comment, and a script counts the same on every run (decisions A583a).
most_words=250
most_decisions=3

# A table's bars, the rule under its heads and a heading's marks are not words.
# The map has a row for each state of the journey, which Peta cannot write shorter (decisions A606b).
words=$(awk '/^## / { map = ($0 == "## Journey") } !map' "$file" | tr -s '|[:space:]' '\n' | grep -cvE '^[-:#]*$' || true)
# Each line under that heading is a decision for the owner, however it is marked, but "None".
decisions=$(awk '
  /^## / { ours = ($0 == "## Needs you"); next }
  ours && !/^[[:space:]]*$/ && !/^[[:space:]]*None\.?[[:space:]]*$/ { rows++ }
  END { print rows + 0 }' "$file")

# Every row of the map is in a slice or stays as it is, so no state of the journey is left to nobody (decisions A606a).
map_format='Write each as "- <screen>, <state>: <what a person sees>, then <where they go next> (slice 1)" or "- <screen>, <state>: unchanged".'
problems=$(awk -v format="$map_format" '
  /^## / { part = $0; next }
  part == "## Tickets" && match($0, /^[0-9]+\./) { slices[substr($0, 1, RLENGTH - 1)] = 1 }
  part == "## Journey" && !/^[[:space:]]*$/ { lines[++n] = $0 }
  END {
    if (n == 0) exit
    if (lines[1] !~ /^[a-z0-9]+(-[a-z0-9]+)*$/)
      print "The first line under \"## Journey\" is \"" lines[1] "\", which is not the journey\047s name. Name it as its file is named, product/journeys/<name>.md: lower-case words joined by hyphens."
    if (n == 1) print "The map under \"## Journey\" holds no row. " format
    for (i = 2; i <= n; i++) {
      row = lines[i]
      if (row !~ /^- [^:]+:/) { print "The line \"" row "\" under \"## Journey\" is not a row. " format; continue }
      if (match(row, /\(slice [0-9]+\)/)) {
        slice = substr(row, RSTART + 7, RLENGTH - 8)
        if (!(slice in slices)) print "The row \"" row "\" names slice " slice ", and \"## Tickets\" has no line " slice "."
      } else if (tolower(row) !~ /(^|[^a-z])unchanged([^a-z]|$)/)
        print "The row \"" row "\" under \"## Journey\" names no slice and does not say \"unchanged\". " format
    }
  }' "$file")
[ -z "$problems" ] || problems+=$'\n'
# A proposal says first whether to build the idea, and slices it whatever it says (decisions A610a, A610b).
if grep -qxE '## (Should it be built|Tickets)' "$file"; then
  shape=$(awk '
    !first && !/^[[:space:]]*$/ { first = $0 }
    /^## / { part = $0; next }
    part == "## Should it be built" && /product\// { named = 1 }
    part == "## Tickets" && /^[0-9]+\./ { slices++ }
    END {
      if (first != "## Should it be built")
        print "It proposes slices and does not open with the heading \"## Should it be built\". Say first whether the idea should be built, what should come first, and what product/ says about it."
      else if (!named)
        print "The part \"Should it be built\" does not name product/. Name each signal, decision and research note that bears on the idea by its file, or say that product/ holds nothing on it."
      if (!slices)
        print "It holds no numbered line under \"## Tickets\". Propose the slices of an idea that should not be built too: the owner decides."
    }' "$file")
  [ -z "$shape" ] || problems+="$shape"$'\n'
fi
# The decisions are counted under that heading alone, so the part written any other way would pass uncounted.
if grep -qi 'needs you' "$file" && ! grep -qx '## Needs you' "$file"; then
  problems+="It names \"Needs you\" on a line that is not the heading \"## Needs you\". Write that part under exactly that heading."$'\n'
fi
[ "$words" -le "$most_words" ] \
  || problems+="It holds $words words, and a comment on an idea holds $most_words at most. Say each thing once, and decide what you can yourself."$'\n'
[ "$decisions" -le "$most_decisions" ] \
  || problems+="It asks the owner $decisions decisions, and $most_decisions is the most. Decide the others yourself, and list each under \"Decided\" with its reason."$'\n'
if [ -n "$problems" ]; then
  printf '%s' "$problems" >&2
  echo "Nothing was posted. Correct $file and run this again." >&2
  exit 1
fi

gh issue comment "$idea" --body-file "$file" >/dev/null \
  || { echo "propose.sh: the comment could not be posted on #$idea, so the owner has not seen it." >&2; exit 1; }
echo "Posted on #$idea: $words words."
