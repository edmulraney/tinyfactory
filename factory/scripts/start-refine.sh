#!/usr/bin/env bash
# Decides, in refine.yml, whether Peta runs for an idea, and writes what she reads to a file.
# Usage: start-refine.sh <issue-number> <owner-login> <file> [comment-id]
#        The comment is the one that started the run; with none, the `idea` label did.
#        Writes start=true or start=false to GITHUB_OUTPUT. Needs GH_TOKEN (issues and contents: write) and GITHUB_REPOSITORY.
set -euo pipefail

usage="Usage: start-refine.sh <issue-number> <owner-login> <file> [comment-id]"
issue="${1:?$usage}"; owner="${2:?$usage}"; file="${3:?$usage}"; comment="${4:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
outputs="${GITHUB_OUTPUT:-/dev/null}"

# A refusal exits 0: the workflow runs no later step and ends green.
refuse() { echo "start=false" >> "$outputs"; echo "not started: $1"; exit 0; }
die() { echo "start=false" >> "$outputs"; echo "$1" >&2; exit 1; }

# Each goes into a call or a filter, so anything that is not a number or a login is refused.
[[ "$issue" =~ ^[0-9]+$ ]] || die "\"$issue\" is not an issue number."
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || die "\"$owner\" is not a GitHub login."
[[ "$comment" =~ ^[0-9]*$ ]] || die "\"$comment\" is not a comment's id."

idea=$(gh api "repos/{owner}/{repo}/issues/$issue") \
  || die "Could not read issue #$issue from GitHub, so whether it is an idea is not known."
jq -e 'has("pull_request") | not' <<<"$idea" >/dev/null || refuse "#$issue is a pull request"
[ "$(jq -r .state <<<"$idea")" = open ] || refuse "issue #$issue is closed"
jq -e 'any(.labels[]; .name == "idea")' <<<"$idea" >/dev/null || refuse "issue #$issue is not labelled idea"

# An idea is its author's to edit, so Peta reads one only a trusted account opened; a refusal writes nothing to it (decisions A563e).
author=$(jq -r '.user.login // ""' <<<"$idea")
trusted=0
"$script_dir/trusted.sh" "$author" || trusted=$?
[ "$trusted" -ne 1 ] || refuse "issue #$issue was opened by ${author:-an account GitHub no longer names}, and Peta runs only for an idea opened by an account that may write to this repository"
[ "$trusted" -eq 0 ] || die "Whether $author, who opened issue #$issue, may write to this repository is not known, so Peta did not run."

# Peta acts on nobody's comment but the owner's (decisions A353c), and on none that asks the mention agent (decisions A372h).
# In lower case, because GitHub's `contains`, which starts the mention agent, ignores case.
if [ -n "$comment" ]; then
  started_by=$(gh api "repos/{owner}/{repo}/issues/comments/$comment") \
    || die "Could not read comment $comment from GitHub, so whether the owner wrote it is not known."
  author=$(jq -r .user.login <<<"$started_by")
  [ "$author" = "$owner" ] || refuse "the comment is by $author, and only one by $owner, the repo's owner, starts Peta"
  jq -e '(.body // "") | ascii_downcase | contains("@claude") | not' <<<"$started_by" >/dev/null \
    || refuse "the comment holds @claude, which the mention agent answers"
fi

# Peta does not run while the Claude usage limit holds every agent: usage-limit.sh runs this run again (decisions A231b, A395b).
limit=$("$script_dir/usage-limit.sh" wait "$issue" "Peta's run on this idea") \
  || die "Whether the Claude usage limit holds every agent is not known, so Peta did not run for issue #$issue."
[ -z "$limit" ] || refuse "$limit"

# Her own comments, and each `Filed #<n>` file-slice.sh writes in her session, are the Claude app's (decisions A563e).
# Anyone else's is left out, so she cannot act on it (decisions A353c), as is the owner's that holds @claude (decisions A372h).
comments=$(gh api "repos/{owner}/{repo}/issues/$issue/comments?per_page=100" --paginate \
    --jq ".[] | select((.user.login == \"$owner\" and ((.body // \"\") | ascii_downcase | contains(\"@claude\") | not))
        or (.user.login == \"claude[bot]\" and .user.type == \"Bot\"))
      | \"===== comment by \(.user.login), \(.created_at) =====\n\(.body // \"\")\n\"") \
  || die "Could not read the comments on issue #$issue from GitHub, so what the owner answered is not known."

# Written in one go, once everything is read: a failed read leaves no file.
mkdir -p "$(dirname "$file")"
{
  jq -r '"# Idea #\(.number): \(.title)\n\n\(.body // "")\n"' <<<"$idea"
  [ -z "$comments" ] || printf '%s\n' "$comments"
} > "$file"
echo "start=true" >> "$outputs"
echo "started: the idea and $(grep -c '^===== comment by ' "$file" || true) comments are in $file"
