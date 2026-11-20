#!/usr/bin/env bash
# Decides whether an agent's session, which has just ended, is continued in the same job (decisions A69a).
# Usage: continue-session.sh build  <execution-file> <wait-seconds> <role> <issue-number>
#        continue-session.sh fix    <execution-file> <wait-seconds> <role> <pr-number> <head-before> [again]
#        OUTPUT='<json>' continue-session.sh answer <execution-file> <wait-seconds> <role> <pr-number>
#        Needs GH_TOKEN (build, fix: to read, and contents write, to save the transcript).
set -euo pipefail

kind="$1"; file="$2"; wait="$3"; role="$4"; number="$5"; before="${6:-}"; retried="${7:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
outputs="${GITHUB_OUTPUT:-/dev/null}"

skip() {
  echo "continue=false" >> "$outputs"
  echo "not continued: $1"
  exit "${2:-0}"
}

case "$kind" in
  build)
    key="issue-$number"
    # Open ones only: one closed without merging before a rebuild is not this build's work.
    opened=$(gh pr list --state open --json headRefName,isDraft --jq "[.[] | select(.isDraft | not) | select(.headRefName | test(\"^[a-z]+/$number-\"))] | length") \
      || skip "the pull requests could not be read from GitHub, so it is not known whether one is ready for review" 1
    [ "$opened" -eq 0 ] || skip "a pull request is ready for review for issue #$number"
    flagged=$(gh issue view "$number" --json labels --jq '[.labels[].name] | index("needs-human") != null') \
      || skip "issue #$number could not be read from GitHub, so it is not known whether the engineer stopped on purpose" 1
    [ "$flagged" != true ] || skip "the engineer stopped on purpose and flagged issue #$number"
    missing="No pull request is ready for review for issue #$number."
    finish="Do not end your turn until the pull request is marked ready for review, or until you have added the needs-human label and said on the issue why it cannot be, in a comment whose first line is what a person must do, or \"Nothing to do\", then what the factory does next and when."
    ;;
  fix)
    key="pr-$number"
    head=$(gh pr view "$number" --json headRefOid --jq .headRefOid) \
      || skip "pull request #$number could not be read from GitHub, so it is not known whether a fix was pushed" 1
    [ "$head" = "$before" ] || skip "a fix was pushed to pull request #$number"
    missing="Nothing has been pushed to pull request #$number."
    finish="Do not end your turn until the fix is pushed. If nothing needs pushing, because you rebutted every finding or stopped on purpose, and you have said so on the pull request, answer with one line and nothing else: what a person must do now, or \"Nothing to do\", then what the factory does next and when."
    # flag-unfinished.sh puts that line first in its comment (decisions A371b).
    ;;
  answer)
    key="pr-$number"
    missing="You have not given your result."
    finish="Do not end your turn until you have given it."
    # A verdict the action did not give is not asked for again (decisions A199).
    OUTPUT=$("$script_dir/review-verdict.sh" "$file"); export OUTPUT
    if [ -n "$OUTPUT" ]; then
      # A verdict post-verdict.sh would refuse is sent back to its reviewer (decisions A169b).
      long=$("$script_dir/long-fields.sh")
      [ -n "$long" ] || skip "the agent returned its result"
      missing="Your verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: $long. Give it again with each such field cut to 40 words or fewer, only the 3 assumptions whose failure would cost most, and nothing else changed."
    fi
    ;;
  *) echo "usage: continue-session.sh build|fix|answer <execution-file> <wait-seconds> <role> <number> [<head-before> [again]]" >&2; exit 2 ;;
esac

ended=""; session=""; cause=""
while IFS='=' read -r name value; do
  case "$name" in ended) ended=$value ;; session) session=$value ;; cause) cause=$value ;; esac
done < <("$script_dir/session-outcome.sh" "$file")

# Decisions A69c.
case "$ended" in
  none) skip "$cause, so there is no session to continue" ;;
  max_turns) skip "$cause" ;;
  # Decisions A231a.
  usage_limit) skip "$cause" ;;
esac
[ -n "$session" ] || skip "the result names no session to continue"
# Decisions A69g.
if [ "$kind" = fix ] && [ "$retried" = again ] && [ "$ended" = completed ]; then
  skip "the engineer was told nothing had been pushed, and ended the session again without pushing: nothing is taken to need pushing"
fi

# Saved before the wait, so that a job cancelled while it waits has kept the transcript. A review's session is
# given no GitHub token, so the step that posts its verdict saves the copy kept below (decisions A541d).
[ "$kind" = answer ] || "$script_dir/save-session.sh" "$role" "$key" "$file"
if [ -n "${RUNNER_TEMP:-}" ]; then
  mkdir -p "$RUNNER_TEMP/cut-short-sessions"
  cp "$file" "$RUNNER_TEMP/cut-short-sessions/$(date -u +%Y%m%dT%H%M%SZ)-$role.json"
fi

# Decisions A69b.
if [ "$ended" = api_error ]; then
  echo "waiting $wait seconds before continuing: $cause"
  sleep "$wait"
fi

{
  echo "continue=true"
  echo "session=$session"
  echo "prompt=Your session ended before your work was handed over: $cause. $missing The files and this conversation are as you left them, so carry on from the step you had reached and do not start again. Run every command in the foreground. $finish"
} >> "$outputs"
echo "continuing session $session: $cause"
