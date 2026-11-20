#!/usr/bin/env bash
# Runs a pull request's reviews as Claude sessions side by side, and posts each verdict from another job (A427a, A427f).
# Usage: review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>
#          From a checkout of the base that holds the commit <head-sha>, whose files it puts outside that checkout,
#          in $RUNNER_TEMP/pull-request. Each reviewer named is given <NAME>_PROMPT and <NAME>_SCHEMA, as ADAM_PROMPT.
#          Needs `claude` with CLAUDE_CODE_OAUTH_TOKEN, and GH_TOKEN, which only reads. Keeps the transcripts in
#          $RUNNER_TEMP/reviews: each reviewer's last as <name>.json, one cut short under cut-short-sessions/.
#          Starts no session while the Claude usage limit holds every agent: writes held=true to GITHUB_OUTPUT.
#          Exits 1 then, and when a review ended with no verdict, so that its job is run again with the failed
#          ones; exits 2 when no session could start.
#        review.sh verdicts <pr-number> <adam|ryan>...
#          Posts the verdict of each reviewer's transcript in $RUNNER_TEMP/reviews, and saves the transcripts there.
#          Needs GH_TOKEN, GITHUB_REPOSITORY and HEAD_SHA as post-verdict.sh and save-session.sh do.
#          Exits 1 when a review failed or was not finished, and writes cut-short=true to GITHUB_OUTPUT when one
#          was not finished and none failed: no fix round starts then (decisions A69e).
set -uo pipefail

usage="Usage: review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>
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
  verdicts) shift 2 ;;
  *) die "$usage" ;;
esac
roles=()
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in adam|ryan) roles+=("$1") ;; *) die "$usage" ;; esac
  [ "$mode" = verdicts ] || { [ -n "$(given "$1" PROMPT)" ] && [ -n "$(given "$1" SCHEMA)" ]; } \
    || die "review.sh: $1 was given no prompt or no format, so it has nothing to review with."
  shift
done
[ "${#roles[@]}" -gt 0 ] || die "$usage"
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

# review <role>: the session, continued twice at most; whether it ended with a verdict is left in a file.
review() {
  local role="$1" file="$kept/$1.json" wait
  mkdir -p "$work/$role"
  rm -f "$file"
  session "$role" "$(given "$role" PROMPT)

This directory is a checkout of the branch the pull request merges into. The pull request's files, as its commit $head has them, are in $files: read them there. \`git diff\` and \`git log\` know that commit from this directory."
  # The waits before continuing after an API error (decisions A69a, A69b).
  for wait in 120 300; do
    : > "$work/$role/outputs"
    # It keeps a transcript cut short beside the others, for the job that saves them (decisions A427f).
    GITHUB_OUTPUT="$work/$role/outputs" RUNNER_TEMP="$kept" "$script_dir/continue-session.sh" answer "$file" "$wait" "$role" "$pr" || true
    grep -qx 'continue=true' "$work/$role/outputs" || break
    session "$role" "$(sed -n 's/^prompt=//p' "$work/$role/outputs")" --resume "$(sed -n 's/^session=//p' "$work/$role/outputs")"
  done
  # What continue-session.sh takes for a result given; post-verdict.sh refuses any other (decisions A169b).
  OUTPUT=$("$script_dir/review-verdict.sh" "$file" 2> /dev/null)
  export OUTPUT
  if [ -n "$OUTPUT" ] && [ -z "$("$script_dir/long-fields.sh")" ]; then
    echo "ended with a verdict"
    : > "$work/$role/finished"
  else
    echo "ended with no verdict that can be posted"
  fi
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

if [ "$mode" = sessions ]; then
  # No review starts while the Claude usage limit holds every agent (decisions A231b).
  held=$("$script_dir/usage-limit.sh" held) || die "review.sh: whether the Claude usage limit holds every agent is not known, so no review started."
  if [ -n "$held" ]; then
    echo "held=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "The Claude usage limit holds every agent until $held: no review started, and this job is run again after it."
    exit 1
  fi
  # A session starts in the base's files, and the pull request's are outside its directory (decisions A427e).
  files="$temp/pull-request"
  git rev-parse --quiet --verify "$head^{commit}" > /dev/null \
    || die "review.sh: the pull request's commit $head is not in this checkout, so its files could not be put beside it, and no review ran."
  # The owner's runner keeps the checkout and empties $RUNNER_TEMP, so an earlier review's folder is recorded and gone.
  git worktree prune && git worktree add --quiet --detach "$files" "$head" \
    || die "review.sh: the files of the pull request's commit $head could not be put in $files, so no review ran."
  mkdir -p "$kept" || die "review.sh: could not make $kept, so no review ran."
  for role in "${roles[@]}"; do
    # Each line says whose it is: the two write to one log as they go.
    review "$role" 2>&1 | while IFS= read -r line; do printf '%s: %s\n' "$role" "$line"; done &
  done
  wait
  for role in "${roles[@]}"; do
    [ -e "$work/$role/finished" ] || exit 1
  done
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
