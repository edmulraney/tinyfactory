#!/usr/bin/env bash
# Lists each line of a document that names what a pull request changes or removes, for Ryan to judge (decisions A615a).
# Usage: stale-documents.sh <base> <head>
#        Run in a checkout that holds both commits; it reads git's objects, and no file of the checkout.
#        Prints "<document>:<line>: <text>" for each line of a `*.md` file of <head>, outside the decision records,
#        that names a file <head> changed or removed since it left <base>, a label whose line in the bootstrap's
#        labels.sh it changed or removed, or `pnpm <script>` for a script of a package.json it changed or removed.
#        Prints nothing and exits 0 when no line does. A read that fails exits 1 with a message and no list.
set -euo pipefail

usage="Usage: stale-documents.sh <base> <head>"
base="${1:?$usage}"; head="${2:?$usage}"
labels=".claude/skills/bootstrap/scripts/labels.sh"
die() { echo "stale-documents.sh: $1, so the documents that name what changed are not listed." >&2; exit 1; }
# A path is printed as it is written in a document, also when it holds a letter outside ASCII.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false

full=$(git rev-parse --quiet --verify "$head^{commit}") || die "the commit $head is not in this checkout"
head="$full"
from=$(git merge-base "$base" "$head" 2>/dev/null) || die "$base and $head share no commit in this checkout"
# A renamed file is removed under its old name; a new file is named by no line written before it.
changed=$(git diff --no-renames --diff-filter=MD --name-only "$from" "$head") || die "the files changed between $from and $head could not be read"
before=$(git ls-tree -r --name-only "$from") || die "the files of $from could not be read"

# Each name is given with how it is told from a longer name: a path may not follow `/`, a word may.
names=$(mktemp) || die "a file to work in could not be made with mktemp"
trap 'rm -f "$names"' EXIT
{
  awk 'NF { print "path\t" $0 }' <<<"$changed"
  # A file name alone names the file only when no other file has it: `SKILL.md` and `page.tsx` name many (decisions A615b).
  awk -F/ 'NR == FNR { count[$NF]++; next } NF > 1 && count[$NF] == 1 { print "word\t" $NF }' <(printf '%s\n' "$before") <(printf '%s\n' "$changed")
} > "$names"

if grep -qxF "$labels" <<<"$changed"; then
  lines=$(git diff "$from" "$head" -- "$labels") || die "the change to $labels could not be read"
  # A document names a label in backticks; bare, `ready` and `bug` are words of any sentence.
  awk '/^-gh label create / { print "word\t`" $4 "`" }' <<<"$lines" >> "$names"
fi

while IFS= read -r file; do
  case "$file" in package.json|*/package.json) ;; *) continue ;; esac
  was=$(git show "$from:$file") || die "$file of $from could not be read"
  now='{}'
  if git cat-file -e "$head:$file" 2>/dev/null; then
    now=$(git show "$head:$file") || die "$file of $head could not be read"
  fi
  jq -rn --argjson was "$was" --argjson now "$now" \
      '($now.scripts // {}) as $kept | ($was.scripts // {}) | to_entries[] | select($kept[.key] != .value) | "word\tpnpm \(.key)"' >> "$names" \
    || die "the scripts of $file could not be read as JSON"
done <<<"$changed"

[ -s "$names" ] || exit 0

found=0
# The records hold what was true when each row was written, and are not corrected (the header of factory/decisions.md).
matches=$(git grep -n -I -F -f <(cut -f2- "$names") "$head" -- '*.md' ':(exclude,glob)**/decisions.md' ':(exclude,glob)**/decisions/**') || found=$?
[ "$found" -le 1 ] || die "the documents of $head could not be searched"
[ "$found" -eq 0 ] || exit 0

# `review.sh` is not named by `owner-review.sh`, nor `pnpm test` by `pnpm test:e2e`, and a sentence may end after a name.
awk -v prefix="$head:" '
  NR == FNR { tab = index($0, "\t"); kind[FNR] = substr($0, 1, tab - 1); name[FNR] = substr($0, tab + 1); count = FNR; next }
  {
    line = substr($0, length(prefix) + 1)
    colon = index(line, ":"); file = substr(line, 1, colon - 1); line = substr(line, colon + 1)
    colon = index(line, ":"); number = substr(line, 1, colon - 1); text = substr(line, colon + 1)
    for (i = 1; i <= count; i++) {
      rest = text; offset = 0
      while ((at = index(rest, name[i])) > 0) {
        start = offset + at; end = start + length(name[i])
        prev = start > 1 ? substr(text, start - 1, 1) : ""
        after = substr(text, end, 1); second = substr(text, end + 1, 1)
        longer = prev ~ /[A-Za-z0-9_-]/ || (kind[i] == "path" && prev == "/") || after ~ /[A-Za-z0-9_\/-]/ \
          || (after ~ /[.:]/ && second ~ /[A-Za-z0-9]/)
        if (!longer) { print file ":" number ": " text; next }
        offset = start; rest = substr(text, start + 1)
      }
    }
  }' "$names" <(printf '%s\n' "$matches")
