#!/usr/bin/env bash
# Tests for factory/scripts/continue-session.sh: whether a session that has just ended is continued in the same job.
. "$(dirname "$0")/helpers.sh"

before=5555555555555555555555555555555555555555
after=6666666666666666666666666666666666666666

# ended <how>: a session on ticket #12, with no pull request and no flag, and pull request #7 with nothing pushed.
ended() {
  local result
  case "$1" in
    api-error)    result='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"session_id":"c22ab626"}' ;;
    completed)    result='{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","api_error_status":null,"session_id":"c22ab626"}' ;;
    failed)       result='{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"model_error","api_error_status":null,"session_id":"c22ab626"}' ;;
    rate-limit)   result='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"rate_limit_error","session_id":"c22ab626"}' ;;
    usage-limit)  result='{"type":"assistant","error":"rate_limit","api_error_status":429,"api_error":"usage_limit_reached","api_error_params":{"rate_limit_info":{"status":"rejected","resetsAt":1795431600}}},{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"usage_limit_reached","result":"You'\''ve hit your Fable limit · resets Nov 23, 11am (UTC). Switch to another model to continue.","session_id":"c22ab626"}' ;;
    out-of-turns) result='{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","api_error_status":null,"session_id":"c22ab626"}' ;;
  esac
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},%s]\n' "$result" > "$T/session.json"
  echo '[{"headRefName":"feat/3-export-forecast-csv"},{"headRefName":"fix/112-other-ticket"}]' > "$T/pulls.json"
  echo '{"labels":[{"name":"in-progress"}]}' > "$T/labels.json"
  echo "$before" > "$T/head"
  : > "$T/fail"
  : > "$T/outputs"
  export GITHUB_OUTPUT="$T/outputs" RUNNER_TEMP="$T/runner" GH_TOKEN=token GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=900
  mkdir -p "$T/runner"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --json headRefName,isDraft "*) json "$(jq -c "[.[] | select(.state != \"CLOSED\" and .state != \"MERGED\")]" "$T/pulls.json")" "$@" ;;
      "issue view 12 --json labels "*) json "$(cat "$T/labels.json")" "$@" ;;
      "pr view 7 --json headRefOid "*) json "{\"headRefOid\":\"$(cat "$T/head")\"}" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep 'exit 0'
  # This git reports a change to commit (the transcript), which save-session.sh reads as saved.
  stub git 'case "$*" in *"diff --cached --quiet") exit 1 ;; esac; exit 0'
}

expect_written() {
  grep -qxF -- "$1" "$T/outputs" || fail "expected this line in the step's outputs: $1"
}
expect_not_written() {
  ! grep -q -- "$1" "$T/outputs" || fail "expected nothing like this in the step's outputs: $1"
}
expect_saved() {
  expect_call "commit --quiet -m session: $1"
  [ -n "$(ls "$T/runner/cut-short-sessions" 2>/dev/null)" ] || fail "expected a copy of the transcript in cut-short-sessions"
}
# A review's job holds no token that writes: its transcript is kept for the job that saves it (decisions A427f).
expect_kept_unsaved() {
  expect_no_call "git "
  [ -n "$(ls "$T/runner/cut-short-sessions" 2>/dev/null)" ] || fail "expected a copy of the transcript in cut-short-sessions"
}
expect_nothing_saved() {
  expect_no_call "git "
  [ ! -e "$T/runner/cut-short-sessions" ] || fail "expected no copy of the transcript"
}

scenario "a build cut short by an API error is continued, after the wait, in the same session"
ended api-error
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_call "sleep 120"
expect_output "waiting 120 seconds before continuing: the model's API was overloaded (error 529)"
expect_saved "fred issue-12"

scenario "the continued engineer is told the cause, what is missing, and not to start again"
ended api-error
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
prompt=$(sed -n 's/^prompt=//p' "$T/outputs")
[ "$(grep -c '^prompt=' "$T/outputs")" = 1 ] || fail "expected the prompt on exactly one line"
for words in "the model's API was overloaded (error 529)" "No pull request is ready for review for issue #12." \
  "do not start again" "Run every command in the foreground." "Do not end your turn until the pull request is marked ready for review" "in a comment whose first line is what a person must do, or \"Nothing to do\", then what the factory does next and when."; do
  [[ "$prompt" == *"$words"* ]] || fail "expected the prompt to hold: $words"
done

scenario "a build whose engineer ended the turn with no pull request is continued at once"
ended completed
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_no_call "sleep"
expect_saved "fred issue-12"

scenario "a build that failed for another reason is continued at once"
ended failed
run "$scripts/continue-session.sh" build "$T/session.json" 120 esme 12
expect_status 0
expect_written "continue=true"
expect_no_call "sleep"
expect_saved "esme issue-12"

scenario "a build whose pull request is ready for review is not continued, however the session ended"
ended api-error
echo '[{"headRefName":"feat/12-export-forecast-csv"}]' > "$T/pulls.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "a pull request is ready for review for issue #12"
expect_no_call "sleep"
expect_nothing_saved

scenario "a build whose pull request is still a draft is continued: a draft is not handed over"
ended completed
echo '[{"headRefName":"feat/12-export-forecast-csv","isDraft":true}]' > "$T/pulls.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"
grep -qF "No pull request is ready for review for issue #12." "$T/outputs" || fail "expected the prompt to say no pull request is ready for review"
expect_saved "fred issue-12"

scenario "another ticket's pull request is not this one's: #112 and #3 are not #12"
ended completed
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_written "continue=true"

scenario "a rebuild is continued when the ticket's only pull request was closed without merging"
ended api-error
echo '[{"headRefName":"feat/12-export-forecast-csv","state":"CLOSED"}]' > "$T/pulls.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"
expect_call "gh pr list --state open"
expect_saved "fred issue-12"

scenario "an engineer who stopped on purpose and flagged the ticket is not continued"
ended completed
echo '{"labels":[{"name":"in-progress"},{"name":"needs-human"}]}' > "$T/labels.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "stopped on purpose"
expect_nothing_saved

scenario "an engineer who left the ticket to wait for the ticket it needs is not continued"
ended completed
echo '{"labels":[{"name":"ready"}]}' > "$T/labels.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "left issue #12 to wait for the ticket it needs"
expect_nothing_saved

scenario "a build whose ticket holds ready beside in-progress is continued: nobody left it to wait"
ended completed
echo '{"labels":[{"name":"ready"},{"name":"in-progress"}]}' > "$T/labels.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"

scenario "a build that ran out of turns is not continued"
ended out-of-turns
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "the agent used all the turns it is allowed"
expect_nothing_saved

scenario "a build the Claude usage limit ended is not continued, and does not wait"
ended usage-limit
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "not continued: the Claude usage limit was reached (\"You've hit your Fable limit · resets Nov 23, 11am (UTC)\")"
expect_no_call "sleep"
expect_nothing_saved

scenario "a fix round and a review the usage limit ended are not continued either"
ended usage-limit
run "$scripts/continue-session.sh" fix "$T/session.json" 120 fred-fix 7 "$before"
expect_status 0
expect_written "continue=false"
: > "$T/outputs"
OUTPUT="" run "$scripts/continue-session.sh" answer "$T/session.json" 120 adam 7
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_no_call "sleep"

scenario "another API error with the same status, a rate limit, is still tried again after the wait"
ended rate-limit
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_call "sleep 120"

scenario "a build that left no result is not continued: there is no session to continue"
ended completed
rm "$T/session.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "the agent left no result that could be read, so there is no session to continue"
expect_nothing_saved

scenario "a build whose action never started, and named no result file, is not continued"
ended completed
run "$scripts/continue-session.sh" build "" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"

scenario "a result that names no session is not continued"
ended completed
echo '[{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed"}]' > "$T/session.json"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 0
expect_written "continue=false"
expect_output "the result names no session to continue"
expect_nothing_saved

scenario "stops, and does not continue, when the pull requests cannot be read: that is not 'none was opened'"
ended api-error
echo "pr list" > "$T/fail"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 1
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "the pull requests could not be read from GitHub"
expect_no_call "sleep"
expect_nothing_saved

scenario "stops, and does not continue, when the ticket cannot be read: that is not 'not flagged'"
ended api-error
echo "issue view" > "$T/fail"
run "$scripts/continue-session.sh" build "$T/session.json" 120 fred 12
expect_status 1
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "issue #12 could not be read from GitHub"
expect_nothing_saved

scenario "a fix round that pushed nothing is continued, and told how to say nothing needs pushing"
ended completed
run "$scripts/continue-session.sh" fix "$T/session.json" 120 esme-fix 7 "$before"
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_saved "esme-fix pr-7"
prompt=$(sed -n 's/^prompt=//p' "$T/outputs")
for words in "Nothing has been pushed to pull request #7." "Do not end your turn until the fix is pushed." "answer with one line and nothing else: what a person must do now, or \"Nothing to do\", then what the factory does next and when."; do
  [[ "$prompt" == *"$words"* ]] || fail "expected the prompt to hold: $words"
done

scenario "a fix round cut short by an API error waits, then is continued"
ended api-error
run "$scripts/continue-session.sh" fix "$T/session.json" 300 fred-fix 7 "$before"
expect_status 0
expect_written "continue=true"
expect_call "sleep 300"

scenario "a fix round that pushed is not continued"
ended api-error
echo "$after" > "$T/head"
run "$scripts/continue-session.sh" fix "$T/session.json" 120 esme-fix 7 "$before"
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "a fix was pushed to pull request #7"
expect_nothing_saved

scenario "a fix round continued once, whose engineer again ended the session without pushing, is not continued a second time"
ended completed
run "$scripts/continue-session.sh" fix "$T/session.json" 300 esme-fix 7 "$before" again
expect_status 0
expect_written "continue=false"
expect_not_written "session="
expect_output "not continued: the engineer was told nothing had been pushed, and ended the session again without pushing"
expect_nothing_saved

scenario "a fix round continued once and then cut short by an API error is continued a second time"
ended api-error
run "$scripts/continue-session.sh" fix "$T/session.json" 300 esme-fix 7 "$before" again
expect_status 0
expect_written "continue=true"
expect_call "sleep 300"

scenario "a fix round that pushed after being continued is not continued a second time"
ended completed
echo "$after" > "$T/head"
run "$scripts/continue-session.sh" fix "$T/session.json" 300 esme-fix 7 "$before" again
expect_status 0
expect_written "continue=false"
expect_output "not continued: a fix was pushed to pull request #7"

scenario "a build continued once, whose engineer again opened no pull request, is continued a second time"
ended completed
run "$scripts/continue-session.sh" build "$T/session.json" 300 esme 12 "" again
expect_status 0
expect_written "continue=true"

scenario "stops, and does not continue, when the pull request cannot be read: that is not 'nothing was pushed'"
ended completed
echo "pr view" > "$T/fail"
run "$scripts/continue-session.sh" fix "$T/session.json" 120 esme-fix 7 "$before"
expect_status 1
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "pull request #7 could not be read from GitHub"
expect_nothing_saved

scenario "a review cut short by an API error, with no verdict, waits, then is continued"
ended api-error
OUTPUT="" run "$scripts/continue-session.sh" answer "$T/session.json" 120 adam 7
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_call "sleep 120"
expect_kept_unsaved
expect_no_call "gh "
prompt=$(sed -n 's/^prompt=//p' "$T/outputs")
[[ "$prompt" == *"You have not given your result."* ]] || fail "expected the prompt to say the result is missing"

scenario "a review that gave its verdict is not continued"
ended completed
OUTPUT='{"verdict":"pass","findings":[]}' run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "the agent returned its result"
expect_nothing_saved

a_fail() { printf '{"verdict":"fail","findings":[{"file":"a.ts","problem":"Wrong.","fix":"%s"}],"assumptions":[]}' "$(printf 'word %.0s' $(seq "$1"))"; }

scenario "a review whose verdict has a field over 40 words is continued, and told which field to shorten"
ended completed
OUTPUT=$(a_fail 41) run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_no_call "sleep"
expect_kept_unsaved
prompt=$(sed -n 's/^prompt=//p' "$T/outputs")
[[ "$prompt" == *"Your verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: finding 1's \`fix\` is 41 words. Give it again"* ]] || fail "expected the prompt to name the field, got: $prompt"
[[ "$prompt" != *"You have not given your result."* ]] || fail "expected the prompt not to say the result is missing"
[ "$(grep -c '^prompt=' "$T/outputs")" = 1 ] && [ "$(wc -l < "$T/outputs" | tr -d ' ')" = 3 ] || fail "expected the prompt on one line, got: $(cat "$T/outputs")"

scenario "a review whose verdict has a fourth assumption is continued, and told to keep the three that cost most"
ended completed
OUTPUT=$(jq -nc '{findings: [], assumptions: [range(4) | {assumes: "It holds.", if_wrong: "It breaks."}]}') run "$scripts/continue-session.sh" answer "$T/session.json" 120 adam 7
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
expect_kept_unsaved
prompt=$(sed -n 's/^prompt=//p' "$T/outputs")
[[ "$prompt" == *"Your verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: it gives 4 assumptions, and 3 is the most. Give it again with each such field cut to 40 words or fewer, only the 3 assumptions whose failure would cost most, and nothing else changed."* ]] || fail "expected the prompt to say there is one too many, got: $prompt"

scenario "a review whose verdict has three assumptions is not continued"
ended completed
OUTPUT=$(jq -nc '{findings: [], assumptions: [range(3) | {assumes: "It holds.", if_wrong: "It breaks."}]}') run "$scripts/continue-session.sh" answer "$T/session.json" 120 adam 7
expect_status 0
expect_written "continue=false"
expect_output "the agent returned its result"
expect_nothing_saved

scenario "a key of the reviewer's own, with a newline in its name, writes no output of its own"
ended completed
OUTPUT=$(jq -c --arg text "$(printf 'word %.0s' $(seq 41))" '.findings[0] += {"x\nsession=stolen": $text}' <<<"$(a_fail 41)") \
  run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "session=c22ab626"
expect_not_written "session=stolen"
[ "$(wc -l < "$T/outputs" | tr -d ' ')" = 3 ] || fail "expected three outputs, got: $(cat "$T/outputs")"
[[ "$(sed -n 's/^prompt=//p' "$T/outputs")" == *"3 assumptions: finding 1's \`fix\` is 41 words. Give it again"* ]] || fail "expected the prompt to name the schema's field alone"

scenario "a review whose verdict has a field of 40 words is not continued"
ended completed
OUTPUT=$(a_fail 40) run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=false"
expect_output "the agent returned its result"
expect_nothing_saved

# past_limit <verdict>: a session that finished with this verdict after more turns than its limit (decisions A199).
past_limit() {
  ended completed
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":56,"session_id":"c22ab626","structured_output":%s}]\n' "$1" > "$T/session.json"
}

scenario "a review that ended with a verdict after more turns than the limit, which the action did not give, is not continued"
past_limit '{"findings":[],"assumptions":[]}'
OUTPUT="" run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"
expect_output "the agent returned its result"
expect_nothing_saved

scenario "such a review whose saved verdict has a field over 40 words is continued, and told which field to shorten"
past_limit "$(a_fail 41)"
OUTPUT="" run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
[[ "$(sed -n 's/^prompt=//p' "$T/outputs")" == *"3 assumptions: finding 1's \`fix\` is 41 words. Give it again"* ]] || fail "expected the prompt to name the field"

scenario "a review past the limit that ended with no verdict is continued as before"
past_limit null
OUTPUT="" run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=true"
expect_written "session=c22ab626"
[[ "$(sed -n 's/^prompt=//p' "$T/outputs")" == *"You have not given your result."* ]] || fail "expected the prompt to say the result is missing"

scenario "a review out of turns whose verdict has a field over 40 words is not continued"
ended out-of-turns
OUTPUT=$(a_fail 41) run "$scripts/continue-session.sh" answer "$T/session.json" 120 ryan 7
expect_status 0
expect_written "continue=false"
expect_not_written "continue=true"

scenario "a kind it does not know is refused"
ended completed
run "$scripts/continue-session.sh" review "$T/session.json" 120 adam 7
expect_status 2
expect_output "usage: continue-session.sh build|fix|answer"
expect_not_written "continue=true"

# Each run of the action gets a token of its own, so a continued session must ask for the same read (decisions A259, A406).
scenario "every agent step of implement.yml, fix.yml and retro.yml asks for a token that reads Actions runs"
for workflow in implement.yml fix.yml retro.yml; do
  steps=$(grep -cF 'uses: anthropics/claude-code-action@v1' "$root/factory/workflows/$workflow")
  reads=$(grep -A1 -E '^          additional_permissions: \|( +#.*)?$' "$root/factory/workflows/$workflow" | grep -cxF '            actions: read')
  [ "$steps" -gt 0 ] && [ "$steps" = "$reads" ] \
    || fail "$workflow has $steps agent steps and $reads that ask for actions: read"
  # The action warns, and the read is refused, when the job's own token may not read Actions.
  grep -qE '^      actions: write( +#.*)?$' "$root/factory/workflows/$workflow" || fail "$workflow's job may not read Actions itself"
done
