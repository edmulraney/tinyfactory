#!/usr/bin/env bash
# Prints a ticket's or a pull request's text for an agent, without what an account that is not trusted wrote on it.
# Usage: thread.sh <number>
#        Prints the title and description, then each comment, review and review comment in the order written, each
#        headed by who wrote it and when. One by an account trusted.sh refuses is left out and counted in the last
#        line; a title and description by one are withheld, and a line says so (decisions A563i, A563j).
#        Needs GH_TOKEN (issues and pull-requests: read, and what trusted.sh needs). A call that fails stops it with
#        a message and exit 1, and nothing of the text is printed.
set -euo pipefail

usage="Usage: thread.sh <number>"
number="${1:?$usage}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
# It goes into each call's path, so anything that is not a number is refused.
[[ "$number" =~ ^[0-9]+$ ]] || die "\"$number\" is not the number of a ticket or a pull request. $usage"

# The REST API names each account in full: `gh issue view` and `gh pr view` shorten a bot's login to one a person could hold.
opening=$(gh api "repos/{owner}/{repo}/issues/$number" \
    --jq '{kind: "opening", author: (.user.login // ""), at: .created_at, number, title, body: (.body // ""), pull_request: has("pull_request"),
      state: (if .pull_request.merged_at then "merged" else .state end), draft: (.draft // false), labels: [.labels[].name]}') \
  || die "Could not read #$number from GitHub, so none of its text is printed."
comments=$(gh api "repos/{owner}/{repo}/issues/$number/comments?per_page=100" --paginate \
    --jq '.[] | {kind: "comment", author: (.user.login // ""), at: .created_at, body: (.body // "")}') \
  || die "Could not read the comments on #$number from GitHub, so none of its text is printed."
reviews=""; review_comments=""
if jq -e .pull_request <<<"$opening" >/dev/null; then
  # A pending review is not submitted yet, and one that only comments and has no summary holds nothing but its review comments.
  reviews=$(gh api "repos/{owner}/{repo}/pulls/$number/reviews?per_page=100" --paginate \
      --jq '.[] | select(.state != "PENDING" and (.state != "COMMENTED" or (.body // "") != ""))
        | {kind: "review", author: (.user.login // ""), at: .submitted_at, state, body: (.body // "")}') \
    || die "Could not read the reviews of pull request #$number from GitHub, so none of its text is printed."
  review_comments=$(gh api "repos/{owner}/{repo}/pulls/$number/comments?per_page=100" --paginate \
      --jq '.[] | {kind: "review comment", author: (.user.login // ""), at: .created_at, path, line: (.line // .original_line), body: (.body // "")}') \
    || die "Could not read the review comments of pull request #$number from GitHub, so none of its text is printed."
fi
written=$(printf '%s\n' "$opening" "$comments" "$reviews" "$review_comments")

# trusted.sh is asked once for each account, however much it wrote. An account GitHub deleted has no login, and is not asked about.
authors=$(jq -rs '[.[].author | select(. != "")] | unique | .[]' <<<"$written") \
  || die "What GitHub returned for #$number could not be read, so none of its text is printed."
trusted=""
while IFS= read -r author; do
  [ -n "$author" ] || continue
  status=0
  "$script_dir/trusted.sh" "$author" >/dev/null || status=$?
  case "$status" in
    0) trusted+="$author"$'\n' ;;
    1) ;;
    # Left out, its words would be missed with nothing to say so; printed, an agent might act on a stranger's.
    *) die "Whether every account that wrote on #$number is trusted is not known, so none of its text is printed." ;;
  esac
done <<<"$authors"

# Printed in one go, once everything is read and every account asked about, so that no part reads as the whole.
# Through stdin, as a long thread is more than one argument may hold.
text=$(jq -rs --arg trusted "$trusted" '
  ($trusted | split("\n") | map(select(. != ""))) as $logins
  | def trusted: .author as $author | $logins | index($author) != null;
  .[0] as $opening
  | (if $opening.pull_request then "Pull request" else "Ticket" end) as $what
  | "State: \($opening.state)\(if $opening.draft then ", draft" else "" end). Labels: \($opening.labels | if length > 0 then join(", ") else "none" end)." as $state
  | (if ($opening | trusted)
     then "# \($what) #\($opening.number): \($opening.title)\n\nOpened by \($opening.author), \($opening.at). \($state)\n\n\($opening.body)\n"
     else "# \($what) #\($opening.number)\n\n\($state)\n\n[Withheld: the title and description. The account that opened this has no write access to the repository, so no agent is shown its words.]\n"
     end),
    (.[1:] | map(select(trusted)) | sort_by(.at)[]
     | if .kind == "review" then "===== review by \(.author), \(.at): \(.state) =====\n\(.body)\n"
       elif .kind == "review comment" then "===== review comment by \(.author), \(.at), on \(.path)\(if .line then ", line \(.line)" else "" end) =====\n\(.body)\n"
       else "===== comment by \(.author), \(.at) =====\n\(.body)\n" end),
    (.[1:] | map(select(trusted | not)) | length | select(. > 0)
     | "[Not shown: \(.) comments or reviews by accounts with no write access to the repository.]")' <<<"$written") \
  || die "What GitHub returned for #$number could not be read, so none of its text is printed."
printf '%s\n' "$text"
