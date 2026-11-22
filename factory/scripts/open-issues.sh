#!/usr/bin/env bash
# Lists the open issues whose titles an agent or a script may read: those the owner or the factory's own bots opened.
# Usage: open-issues.sh [<label>]          the open issues, with that label when one is given, and no pull request
#        open-issues.sh --search <words>   the open issues and pull requests that GitHub's search finds for the words
#        Prints `[{number, title, labels, pull_request}]`, lowest number first; one no account that may write opened is left out.
#        Needs GH_TOKEN (issues: read; for --search, pull-requests: read). A call to GitHub that fails stops it with
#        a message and exit 1, and prints nothing.
set -euo pipefail

usage="Usage: open-issues.sh [<label>] | open-issues.sh --search <words>"
die() { echo "$1" >&2; exit 1; }

# The owner, and the factory's two bots by full login and type, which no person's account can be (decisions A653a, U563a).
# An organisation's member or a collaborator may write, which only GitHub can say: each such author is asked once below.
ours='select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR"
    or (.user.type == "Bot" and (.user.login == "github-actions[bot]" or .user.login == "claude[bot]")))
  | {number, title, labels: [.labels[].name], pull_request: has("pull_request"),
     check: (if .author_association == "MEMBER" or .author_association == "COLLABORATOR" then .user.login else null end)}'

if [ "${1:-}" = --search ]; then
  [ $# -eq 2 ] && [ -n "$2" ] || die "$usage"
  # The search API takes the repository by name in its query, where gh fills in no placeholder.
  repo=$(gh api "repos/{owner}/{repo}" --jq .full_name) \
    || die "Could not read this repository's name from GitHub, so nothing was searched for \"$2\"."
  # Search words can name another repository, whose owner and bots are not this one's, so its results are dropped.
  found=$(gh api --method GET search/issues -f q="repo:$repo is:open $2" -f per_page=100 --paginate \
      --jq ".items[] | select(.repository_url | endswith(\"/repos/$repo\")) | $ours") \
    || die "Could not search the open issues and pull requests for \"$2\" on GitHub."
else
  [ $# -le 1 ] || die "$usage"
  # A label goes into the address, so one with a character an address would read is refused.
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]*$ ]] || die "\"$1\" is not a label this factory uses. $usage"
  # Listed: a search would miss an issue seconds old.
  found=$(gh api "repos/{owner}/{repo}/issues?state=open${1:+&labels=$1}&per_page=100" --paginate \
      --jq ".[] | select(.pull_request == null) | $ours") \
    || die "Could not list the open issues${1:+ labelled $1} on GitHub."
fi
# Kept only when trusted.sh says the author may write; a GitHub that would not say stops the list (decisions W563b).
script_dir="$(cd "$(dirname "$0")" && pwd)"
allowed=()
for login in $(jq -r 'select(.check != null) | .check' <<<"$found" | sort -u); do
  # An account that may not write is left out quietly, as a stranger is; only GitHub not answering is said.
  if "$script_dir/trusted.sh" "$login" 2>/dev/null; then allowed+=("$login")
  elif [ $? -eq 2 ]; then die "GitHub would not say whether $login may write, so no list was printed."; fi
done
jq -cs --args '[.[] | select(.check == null or (.check | IN($ARGS.positional[]))) | del(.check)] | sort_by(.number)' \
  "${allowed[@]+"${allowed[@]}"}" <<<"$found"
