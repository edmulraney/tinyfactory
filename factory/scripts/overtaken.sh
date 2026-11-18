#!/usr/bin/env bash
# Says which workflow sources a pull request changes that its base has changed since the pull request left it.
# Usage: overtaken.sh <pr-number> <base-branch> <head-sha>
#        Needs GH_TOKEN (contents and pull-requests: read).
#        Prints one sentence for each such source, naming what changed it on the base; nothing when there is none.
#        A read GitHub does not answer stops it with a message and exit 1.
set -euo pipefail

usage="Usage: overtaken.sh <pr-number> <base-branch> <head-sha>"
pr="${1:?$usage}"; base="${2:?$usage}"; head="${3:?$usage}"
folder=factory/workflows

die() { echo "$1, so whether \`$base\` has overtaken a workflow change in pull request #$pr is not known." >&2; exit 1; }

# Each answer is read on a line of its own (decisions H7). The installer reads a rename as two changed sources.
files=$(gh api "repos/{owner}/{repo}/pulls/$pr/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)') \
  || die "GitHub did not list the files pull request #$pr changes"
# What GitHub lists in the folder itself: a source, or a folder that holds one.
entries=$(sed -n "s|^\($folder/[^/]*\).*|\1|p" <<<"$files" | sort -u)
[ -n "$entries" ] || exit 0

ends=$(gh api "repos/{owner}/{repo}/compare/$base...$head" --jq '"\(.merge_base_commit.sha) \(.base_commit.sha)"') \
  || die "GitHub did not say where ${head:0:7} left \`$base\`"
read -r fork tip <<<"$ends"
[[ "$fork" =~ ^[0-9a-f]{40,64}$ ]] && [[ "$tip" =~ ^[0-9a-f]{40,64}$ ]] \
  || die "GitHub named no commit at which ${head:0:7} left \`$base\`"
[ "$fork" != "$tip" ] || exit 0

# The ids git gives the folder's entries, not a list of changed files, which GitHub cuts at 300 (decisions W281a).
listing() { gh api --method GET "repos/{owner}/{repo}/contents/$folder" -f ref="$1" --jq '.[] | "\(.sha)\t\(.path)"'; }
at_fork=$(listing "$fork") || die "GitHub did not list \`$folder\` as it was at ${fork:0:7}"
now=$(listing "$tip") || die "GitHub did not list \`$folder\` as it is on \`$base\`"
id() { awk -F'\t' -v path="$2" '$2 == path { print $1 }' <<<"$1"; }

while IFS= read -r entry; do
  [ "$(id "$at_fork" "$entry")" != "$(id "$now" "$entry")" ] || continue
  last=$(gh api --method GET "repos/{owner}/{repo}/commits" -f sha="$tip" -f path="$entry" -f per_page=1 \
      --jq '.[0] | "\(.sha) \(.commit.message | split("\n")[0])"') \
    || die "GitHub did not say which commit last changed \`$entry\` on \`$base\`"
  # GitHub titles a squash commit "<title> (#<pr>)".
  if [[ "$last" =~ \ \(#([0-9]+)\)$ ]]; then by="pull request #${BASH_REMATCH[1]}"; else by="commit ${last:0:7}"; fi
  echo "\`$entry\` on \`$base\` was changed by $by after this pull request's diff of it was made."
done <<<"$entries"
