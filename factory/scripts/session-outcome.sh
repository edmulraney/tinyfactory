#!/usr/bin/env bash
# Prints how an agent's session ended, the id to continue it with, and the cause in words (decisions A69a).
# Usage: session-outcome.sh <execution-file>
#        Prints four lines, in the form a workflow step's outputs take:
#          ended=completed | api_error | usage_limit | max_turns | none | <another terminal_reason>
#          session=<the id to continue the session with, or nothing>
#          cause=<one clause for a comment: "the model's API was overloaded (error 529)">
#          resets=<when a usage limit that ended it resets, in seconds since 1970, or nothing>
set -uo pipefail

file="${1:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# `none` is an answer, so this never fails. session-ending.sh decides the word, for every workflow.
ended=$("$script_dir/session-ending.sh" "$file") || ended=none
# The word goes into comments and a prompt, so anything that is not one is no answer.
[[ "$ended" =~ ^[a-z_]+$ ]] || ended=none

# Not the action's `session_id` output: it is set only for a session that succeeded, and those continued did not.
session=""; status=""; resets=""; message=""
if [ "$ended" != none ]; then
  facts=$(jq -r '
    (if type == "array" then . else [.] end) as $all
    | ($all | map(select(type == "object" and .type == "system" and .subtype == "init")) | first) as $init
    # The name of the limit and its reset time come from the message, and only plain characters reach a comment (decisions A231b).
    | ($all | map(objects | (.api_error_params.rate_limit_info? // .rate_limit_info? // empty)
        | select(.status? == "rejected") | .resetsAt? | numbers | floor) | last // "") as $resets
    | ($all[-1].result | if type == "string" then . else "" end
        | split(". ")[0] // "" | gsub("[^A-Za-z0-9 .,:·\u0027()/+-]"; "") | .[0:120]) as $message
    | [ ($all[-1].session_id // $init.session_id // ""), ($all[-1].api_error_status // "" | tostring),
        ($resets | tostring), $message ]
    | join("|")' "$file" 2>/dev/null) || facts=""
  # A bar and not a tab: read folds neighbouring tabs into one, which would move the field after an empty one.
  IFS='|' read -r session status resets message <<<"$facts"
fi
# The id goes into the arguments of the run that continues the session, so anything unlike one is dropped.
[[ "$session" =~ ^[A-Za-z0-9-]+$ ]] || session=""
[[ "$status" =~ ^[0-9]+$ ]] || status=""
[[ "$resets" =~ ^[0-9]{1,12}$ ]] && [ "$ended" = usage_limit ] || resets=""

case "$ended" in
  none) cause="the agent left no result that could be read" ;;
  api_error)
    case "$status" in
      529) cause="the model's API was overloaded (error 529)" ;;
      429) cause="the model's API refused the request, a rate or usage limit having been reached (error 429)" ;;
      "")  cause="the model's API returned an error" ;;
      *)   cause="the model's API returned an error ($status)" ;;
    esac ;;
  usage_limit) cause="the Claude usage limit was reached${message:+ (\"$message\")}" ;;
  max_turns) cause="the agent used all the turns it is allowed" ;;
  completed) cause="the agent ended its session before the work was handed over" ;;
  *) cause="the agent's session ended with an error ($ended)" ;;
esac

printf 'ended=%s\nsession=%s\ncause=%s\nresets=%s\n' "$ended" "$session" "$cause" "$resets"
