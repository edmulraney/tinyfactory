#!/usr/bin/env bash
# Says whether a commit merges into another once the lines both added to a list .gitattributes marks are kept.
# Usage: settle-conflict.sh <into> <commit>   (in a repo that holds both; needs no token)
#        Prints nothing when they merge with no conflict as GitHub merges them, which reads no .gitattributes.
#        Prints the tree of the merge when every conflict was lines that both added to a file <into> marks
#        `merge=list`, which this merge alone keeps (decisions M485a).
#        Exit 1, having printed the files in conflict, when an engineer must fit them; exit 2 when git could not say.
set -euo pipefail

usage="Usage: settle-conflict.sh <into> <commit>"
die() { echo "$1" >&2; exit 2; }
into=$(git rev-parse --verify --quiet "${1:?$usage}^{commit}") || die "git holds no commit $1, so whether it conflicts is not known."
commit=$(git rev-parse --verify --quiet "${2:?$usage}^{commit}") || die "git holds no commit $2, so whether it conflicts is not known."

# merged <tree whose .gitattributes are read>: prints the tree of the merge, then the files left in conflict.
merged() {
  local found code=0
  # Git knows no `list` driver but the one named here, so no other merge keeps both versions of a line (decisions M485b).
  found=$(git -c merge.list.driver='git merge-file --union %A %O %B' --attr-source="$1" merge-tree --write-tree --name-only --no-messages "$into" "$commit" 2>&1) || code=$?
  # git exits 1 for a conflict and for a merge it refuses, and only a merge it made prints a tree.
  [ "$code" -le 1 ] && [[ "$(head -n 1 <<<"$found")" =~ ^[0-9a-f]{40,64}$ ]] \
    || die "git could not merge ${commit:0:7} into ${into:0:7}, so whether they conflict is not known: $found"
  echo "$found"
}

plain=$(merged "$(git hash-object -t tree /dev/null)")
files=$(sed 1d <<<"$plain")
[ -n "$files" ] || exit 0

# The marks are read from <into>, so a pull request cannot mark a file to settle its own conflict (README principle 12).
kept=$(merged "$into")
left=$(sed 1d <<<"$kept")
if [ -n "$left" ]; then
  echo "$left"
  exit 1
fi

# The driver also keeps both versions of a line both changed, so a conflict that began with a line is no list's (decisions M485b).
base=$(git merge-base "$into" "$commit") || die "git found no commit that ${commit:0:7} and ${into:0:7} both began from, so what each changed is not known."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A marker no line of a document is taken for.
bar=$(printf '%040d' 0 | tr 0 '|')
rule=$(printf '%040d' 0 | tr 0 '=')
changed=""
while IFS= read -r file; do
  for side in "$into" "$base" "$commit"; do
    # A file one of them does not hold began empty there.
    if git cat-file -e "$side:$file" 2>/dev/null; then
      git cat-file -p "$side:$file" > "$work/$side" || die "git could not read $file at ${side:0:7}, so what changed in it is not known."
    else
      : > "$work/$side"
    fi
  done
  conflicts=0
  git merge-file -p --diff3 --marker-size=40 "$work/$into" "$work/$base" "$work/$commit" > "$work/merged" 2>/dev/null || conflicts=$?
  [ "$conflicts" -le 127 ] || die "git could not merge $file, so what conflicts in it is not known."
  awk -v bar="$bar" -v rule="$rule" '
    index($0, bar) == 1 { began = 1; next }
    $0 == rule { began = 0; next }
    began { changed = 1 }
    END { exit changed }' "$work/merged" || changed+="$file"$'\n'
done <<<"$files"
if [ -n "$changed" ]; then
  printf '%s' "$changed"
  exit 1
fi
head -n 1 <<<"$kept"
