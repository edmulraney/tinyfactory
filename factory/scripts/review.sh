#!/usr/bin/env bash
# Runs a pull request's reviews as Claude sessions side by side, and posts each verdict after (decisions A427a, A541d).
# Usage: review.sh context <pr-number>
#          Writes what a reviewer reads from GitHub to $RUNNER_TEMP/github, as thread.sh prints it: the pull request's
#          title, description, comments and reviews as pull-request.md, and the text and comments of each ticket it
#          closes as ticket-<n>.md, with nothing an account that is not trusted wrote (decisions A563i, A563k).
#          Needs GH_TOKEN, to read. If GitHub cannot be read it exits 1 and leaves no folder.
#        review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>
#          From a checkout of the base that holds the commit <head-sha>, whose files it puts outside that checkout,
#          in $RUNNER_TEMP/pull-request. Each reviewer named is given <NAME>_PROMPT and <NAME>_SCHEMA, as ADAM_PROMPT.
#          Needs `claude` with CLAUDE_CODE_OAUTH_TOKEN, and no GitHub token: with GH_TOKEN or GITHUB_TOKEN set, or
#          a token in the checkout's git config, it starts no session and exits 1 (decisions A541d), with
#          workflow-behind.sh's sentence in a run whose ci.yml main no longer holds or is about to replace, which
#          gives it a token as an earlier ci.yml did (decisions A541a). Keeps the transcripts in
#          $RUNNER_TEMP/reviews: each reviewer's last as <name>.json, one cut short under cut-short-sessions/.
#          When no session could start it says why, and keeps none.
#        review.sh verdicts <pr-number> <adam|ryan>...
#          Posts the verdict of each reviewer's transcript in $RUNNER_TEMP/reviews, and saves the transcripts there;
#          a reviewer with no transcript is said to be unfinished.
#          Needs GH_TOKEN, GITHUB_REPOSITORY and HEAD_SHA as post-verdict.sh and save-session.sh do.
#          Exits 1 when a review failed or was not finished, and writes cut-short=true to GITHUB_OUTPUT when one
#          was not finished and none failed: no fix round starts then (decisions A69e).
#        Wrong arguments stop it before anything, with exit 2.
set -uo pipefail

usage="Usage: review.sh context <pr-number>
       review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>
       review.sh verdicts <pr-number> <adam|ryan>..."
die() { echo "$1" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"

# given <role> PROMPT|SCHEMA: what that reviewer was given, as ADAM_PROMPT.
given() {
  local name
  name="$(tr '[:lower:]' '[:upper:]' <<<"$1")_$2"
  printf '%s' "${!name:-}"
}

mode="${1:-}"; pr="${2:-}"
[[ "$pr" =~ ^[0-9]+$ ]] || die "$usage"
head=""
case "$mode" in
  sessions) head="${3:-}"; [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "$usage"; shift 3 ;;
  context|verdicts) shift 2 ;;
  *) die "$usage" ;;
esac
roles=()
while [ "$mode" != context ] && [ $# -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in adam|ryan) roles+=("$1") ;; *) die "$usage" ;; esac
  [ "$mode" = verdicts ] || { [ -n "$(given "$1" PROMPT)" ] && [ -n "$(given "$1" SCHEMA)" ]; } \
    || die "review.sh: $1 was given no prompt or no format, so it has nothing to review with."
  shift
done
[ "$mode" = context ] || [ "${#roles[@]}" -gt 0 ] || die "$usage"
if [ "$mode" = sessions ]; then
  [ "${1:-}" = -- ] && [ $# -gt 1 ] || die "$usage"
  shift
  session_args=("$@")
else
  [ $# -eq 0 ] || die "$usage"
fi

temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
kept="$temp/reviews"
# No reviewer failed the pull request, so no fix round starts (decisions A69e).
work=$(mktemp -d) || {
  echo "cut-short=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  die "review.sh: could not make a folder to work in with mktemp, so no review ran and no verdict was posted."
}
trap 'rm -rf "$work"' EXIT
# What a reviewer reads from GitHub, which a session has no token to ask (decisions A541d).
github="$temp/github"

if [ "$mode" = context ]; then
  unread() {
    rm -rf "$github"
    echo "review.sh: $1 could not be read from GitHub, so a reviewer has nothing to read it from, and no review runs." >&2
    exit 1
  }
  rm -rf "$github"
  mkdir -p "$github" || { echo "review.sh: could not make $github, so no review runs." >&2; exit 1; }
  "$script_dir/thread.sh" "$pr" > "$github/pull-request.md" || unread "pull request #$pr"
  # The tickets it closes are numbers GitHub worked out, and none of the description's words.
  tickets=$(gh pr view "$pr" --json closingIssuesReferences --jq '.closingIssuesReferences[].number') || unread "pull request #$pr"
  for ticket in $tickets; do
    "$script_dir/thread.sh" "$ticket" > "$github/ticket-$ticket.md" || unread "ticket #$ticket"
  done
  exit 0
fi

if [ "$mode" = sessions ]; then
  # A session reads files and the web, so text it reads could have it send out a token it can read (decisions A541d).
  reach=""
  [ -z "${GITHUB_TOKEN:-}" ] || reach="GITHUB_TOKEN is set"
  [ -z "${GH_TOKEN:-}" ] || reach="GH_TOKEN is set"
  if [ -z "$reach" ] && git config --local --list 2>/dev/null | grep -qiE 'extraheader|authorization|x-access-token|gh[pousr]_[a-z0-9]|github_pat_'; then
    reach="the checkout's git config holds a token"
  fi
  if [ -n "$reach" ]; then
    behind=$("$script_dir/workflow-behind.sh") || behind=""
    [ -z "$behind" ] || { echo "not reviewed. $behind"; exit 1; }
    echo "review.sh: $reach, so a session could read a GitHub token and send it out. No session started." >&2
    exit 1
  fi
fi

# session <role> <prompt> [--resume <id>]: one session, its messages kept as the array the Claude action saved.
session() {
  local role="$1" prompt="$2"
  shift 2
  claude -p "$prompt" "$@" "${session_args[@]}" --json-schema "$(given "$role" SCHEMA)" --output-format stream-json --verbose \
    < /dev/null > "$work/$role/messages" || true
  # A session that printed nothing leaves the transcript before it, as the action's missing output did.
  if jq -es 'length > 0' "$work/$role/messages" > /dev/null 2>&1; then
    jq -s . "$work/$role/messages" > "$kept/$role.json"
  fi
}

# review <role>: the session, continued twice at most.
review() {
  local role="$1" file="$kept/$1.json" wait
  mkdir -p "$work/$role"
  rm -f "$file"
  session "$role" "$(given "$role" PROMPT)

This directory is a checkout of the branch the pull request merges into. The pull request's files, as its commit $head has them, are in $files: read them there. \`git diff\` and \`git log\` know that commit from this directory.

You have no \`gh\`. What it would print is in $github: pull-request.md holds the pull request's title, description, comments and reviews, and ticket-<n>.md the text and comments of the ticket it closes, each without what an account with no write access to the repository wrote. For the pull request's diff, run \`git diff HEAD...$head\`."
  # The waits before continuing after an API error (decisions A69a, A69b).
  for wait in 120 300; do
    : > "$work/$role/outputs"
    # It keeps a transcript cut short beside the others, for the step that saves them.
    GITHUB_OUTPUT="$work/$role/outputs" RUNNER_TEMP="$kept" "$script_dir/continue-session.sh" answer "$file" "$wait" "$role" "$pr" || true
    grep -qx 'continue=true' "$work/$role/outputs" || break
    session "$role" "$(sed -n 's/^prompt=//p' "$work/$role/outputs")" --resume "$(sed -n 's/^session=//p' "$work/$role/outputs")"
  done
}

# verdict <role>: its verdict posted and its transcripts saved; its outcome is left in a file.
verdict() {
  local role="$1" name file status=0
  case "$role" in
    adam) name="Adam (architecture and taste)" ;;
    ryan) name="Ryan (correctness)" ;;
  esac
  mkdir -p "$work/$role"
  : > "$work/$role/outputs"
  GITHUB_OUTPUT="$work/$role/outputs" "$script_dir/post-verdict.sh" "$name" "$pr" "$kept/$role.json" || status=$?
  for file in "$kept"/cut-short-sessions/*-"$role".json "$kept/$role.json"; do
    [ ! -f "$file" ] || "$script_dir/save-session.sh" "$role" "pr-$pr" "$file"
  done
  if [ "$status" -eq 0 ]; then echo pass
  elif grep -qx 'cut-short=true' "$work/$role/outputs"; then echo cut-short
  else echo fail
  fi > "$work/$role/outcome"
}

# sessions: each reviewer's session, at the same time. When none can start it says why, and no transcript is kept.
sessions() {
  local role
  # A session starts in the base's files, and the pull request's are outside its directory (decisions A427e).
  files="$temp/pull-request"
  git rev-parse --quiet --verify "$head^{commit}" > /dev/null || {
    echo "review.sh: the pull request's commit $head is not in this checkout, so its files could not be put beside it, and no review ran." >&2
    return
  }
  # The owner's runner keeps the checkout and empties $RUNNER_TEMP, so an earlier review's folder is recorded and gone.
  git worktree prune && git worktree add --quiet --detach "$files" "$head" || {
    echo "review.sh: the files of the pull request's commit $head could not be put in $files, so no review ran." >&2
    return
  }
  [ -f "$github/pull-request.md" ] || {
    echo "review.sh: $github holds no pull-request.md, which \`review.sh context\` writes, so a reviewer could not read the pull request, and no review ran." >&2
    return
  }
  mkdir -p "$kept" || { echo "review.sh: could not make $kept, so no review ran." >&2; return; }
  for role in "${roles[@]}"; do
    # Each line says whose it is: the two write to one log as they go.
    review "$role" 2>&1 | while IFS= read -r line; do printf '%s: %s\n' "$role" "$line"; done &
  done
  wait
}

if [ "$mode" = sessions ]; then
  sessions
  exit 0
fi

failed=""; cut_short=""
for role in "${roles[@]}"; do
  verdict "$role" 2>&1 | while IFS= read -r line; do printf '%s: %s\n' "$role" "$line"; done
  case "$(cat "$work/$role/outcome" 2>/dev/null)" in
    pass) ;;
    cut-short) cut_short=yes ;;
    # A verdict that left no outcome counts as failed, as a failed step of its job did.
    *) failed=yes ;;
  esac
done
[ -n "$failed" ] || [ -z "$cut_short" ] || echo "cut-short=true" >> "${GITHUB_OUTPUT:-/dev/null}"
[ -z "$failed$cut_short" ]
