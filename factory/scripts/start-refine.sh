#!/usr/bin/env bash
# Decides, in refine.yml, whether Peta runs for an idea, and writes what she reads to a file.
# Usage: start-refine.sh <issue-number> <owner-login> <file> [comment-id] [label]
#        The comment is the one that started the run; with none, the label did.
#        A `ready` label the owner added to the idea is their "go" to Peta's proposal, whatever started the run (decisions
#        A611a): it comes off the idea, and the file ends with it. On an idea with no proposal it accepts nothing, and
#        the idea is told so.
#        Writes start=true or start=false to GITHUB_OUTPUT. Needs GH_TOKEN (issues and contents: write) and GITHUB_REPOSITORY.
set -euo pipefail

usage="Usage: start-refine.sh <issue-number> <owner-login> <file> [comment-id] [label]"
issue="${1:?$usage}"; owner="${2:?$usage}"; file="${3:?$usage}"; comment="${4:-}"; label="${5:-}"
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

# The owner's "go" is the label the idea carries, by the event that last added it, whatever started the run (decisions A611a).
go=false
if jq -e 'any(.labels[]; .name == "ready")' <<<"$idea" >/dev/null; then
  added_by=$(gh api "repos/{owner}/{repo}/issues/$issue/events?per_page=100" --paginate \
      --jq '.[] | select(.event == "labeled" and .label.name == "ready") | .actor.login // ""') \
    || die "Could not read the events of issue #$issue from GitHub, so whether the owner added its ready label is not known."
  added_by=$(tail -n 1 <<<"$added_by")
  [ "$added_by" != "$owner" ] || go=true
  [ "$go" = true ] || [ "$label" != ready ] \
    || refuse "the ready label was added by ${added_by:-nobody GitHub names}, and only $owner, the repo's owner, starts Peta with it"
elif [ "$label" = ready ]; then
  refuse "the ready label that started this run is no longer on issue #$issue"
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
      | {login: .user.login, at: .created_at, body: (.body // \"\")} | @json") \
  || die "Could not read the comments on issue #$issue from GitHub, so what the owner answered is not known."

if [ "$go" = true ]; then
  # A proposal is a comment of Peta's with the heading propose.sh asks of one; the owner's that quotes it is none.
  if ! jq -es 'any(.[]; .login == "claude[bot]" and (.body | test("(^|\n)## Tickets\r?(\n|$)")))' <<<"$comments" >/dev/null; then
    # The first line says what a person must do (decisions A371a).
    gh issue comment "$issue" --body "Add the \`ready\` label again once Peta's proposal is on this idea, and she files its tickets.

The label accepted nothing, because this idea holds no proposal yet. It was taken off." >/dev/null \
      && gh issue edit "$issue" --remove-label ready >/dev/null \
      || die "The ready label on issue #$issue accepts nothing, because the idea holds no proposal yet, but the idea could not be told so and the label taken off."
    [ "$label" != ready ] || refuse "issue #$issue holds no proposal of Peta's for the ready label to accept: it was told so"
    go=false
  else
    # The label is the owner's word once, so it comes off and a later proposal can be given it again (decisions A611b).
    gh issue edit "$issue" --remove-label ready >/dev/null \
      || die "The ready label could not be taken off issue #$issue, so Peta did not run. Take it off and add it again."
  fi
fi

# Written in one go, once everything is read: a failed read leaves no file.
mkdir -p "$(dirname "$file")"
{
  jq -r '"# Idea #\(.number): \(.title)\n\n\(.body // "")\n"' <<<"$idea"
  [ -z "$comments" ] || jq -r '"===== comment by \(.login), \(.at) =====\n\(.body)\n"' <<<"$comments"
  [ "$go" != true ] || printf '===== the `ready` label, added by %s =====\ngo\n' "$owner"
} > "$file"
echo "start=true" >> "$outputs"
echo "started: the idea and $(grep -c '^===== comment by ' "$file" || true) comments are in $file"
