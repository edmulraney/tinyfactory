#!/usr/bin/env bash
# Posts Peta's comment on an idea, and refuses one that is too long or asks the owner too much (decisions A583a).
# Usage: propose.sh <idea> <file>   (needs GH_TOKEN)
#        A comment holds 250 words at most, and three lines under its heading "Needs you" at most.
#        A refused comment is not posted, and the output says the count and the limit.
set -euo pipefail

idea="${1:?Usage: propose.sh <idea> <file>}"
file="${2:?Usage: propose.sh <idea> <file>}"
[ -f "$file" ] || { echo "propose.sh: $file is not a file." >&2; exit 1; }

most_words=250
most_decisions=3

# A table's bars, the rule under its heads and a heading's marks are not words.
words=$(tr -s '|[:space:]' '\n' < "$file" | grep -cvE '^[-:#]*$' || true)
# Each line under that heading is a decision for the owner, however it is marked, but "None".
decisions=$(awk '
  /^## / { ours = ($0 == "## Needs you"); next }
  ours && !/^[[:space:]]*$/ && !/^[[:space:]]*None\.?[[:space:]]*$/ { rows++ }
  END { print rows + 0 }' "$file")

problems=""
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
