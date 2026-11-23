#!/usr/bin/env bash
# Tests for flag-unfinished.sh: what a build or fix round that handed nothing over leaves behind, says and exits with.
. "$(dirname "$0")/helpers.sh"

branch=feat/12-export-forecast-csv

# ended <api-error|rate-limit|usage-limit|max-turns|none|completed>; $T/fail holds one line per gh call, by its first words, that should fail.
# $T/timeline.json holds the comments and label events of ticket #12, none when absent.
# $T/pulls.json holds the pull requests, open unless `state` says not; $T/pulls.later.json answers from the third ask.
# What start-waiting.sh reads is as waiting_on_github says. The hold of the usage limit is read from the sessions branch
# of the repo the pushes go to; $resets_at is the reset time a session the usage limit ended holds.
ended() {
  local result
  case "$1" in
    api-error) result='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"session_id":"c22ab626"}' ;;
    usage-limit) result='{"type":"assistant","error":"rate_limit","api_error_status":429,"api_error":"usage_limit_reached","api_error_params":{"rate_limit_info":{"status":"rejected","resetsAt":'"${resets_at:-1795431600}"'}}},{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"api_error":"usage_limit_reached","result":"You'\''ve hit your Fable limit · resets Nov 23, 11am (UTC). Switch to another model to continue.","session_id":"c22ab626"}' ;;
    rate-limit) result='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"session_id":"c22ab626"}' ;;
    max-turns) result='{"type":"result","subtype":"error_max_turns","is_error":true,"terminal_reason":"max_turns","session_id":"c22ab626"}' ;;
    none) result='{"type":"assistant"}' ;;
    completed) result='{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","api_error_status":null,"session_id":"c22ab626"}' ;;
  esac
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},%s]\n' "$result" > "$T/session.json"
  echo '[{"headRefName":"feat/3-export-forecast-csv"},{"headRefName":"fix/112-other-ticket"}]' > "$T/pulls.json"
  echo '{"labels":[{"name":"in-progress"}]}' > "$T/labels.json"
  : > "$T/fail"
  : > "$T/posted"
  export GH_TOKEN=token GITHUB_REPOSITORY=owner/repo GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=900
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --json number,headRefName,isDraft,mergeable "*)
        pulls="$T/pulls.json"
        if [ -f "$T/pulls.later.json" ] && [ "$(grep -c "^gh pr list" "$T/calls")" -ge 3 ]; then pulls="$T/pulls.later.json"; fi
        json "$(jq -c "[.[] | select(.state != \"CLOSED\" and .state != \"MERGED\")]" "$pulls")" "$@" ;;
      "pr view 9 --json isDraft,labels "*) json "{\"isDraft\":false,\"labels\":[]}" "$@" ;;
      "api repos/{owner}/{repo}/issues/9/comments?per_page=100 --paginate --jq "*) json "[]" "$@" ;;
      "api repos/{owner}/{repo}/issues/12/timeline?per_page=100 --paginate --jq "*) json "$(cat "$T/timeline.json" 2>/dev/null || echo "[]")" "$@" ;;
      "workflow run fix.yml -f pr=9"|"workflow run retro.yml -f pr=7") echo "created workflow_dispatch event" ;;
      "issue view 12 --json labels "*) json "$(cat "$T/labels.json")" "$@" ;;
      "pr view 7 --json headRefOid,labels "*) json "{\"headRefOid\":\"$(cat "$T/head")\",\"labels\":$(cat "$T/pr-labels.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "pr view 7 --json body "*) json "{\"body\":\"Closes #12\"}" "$@" ;;
      "api repos/{owner}/{repo}/actions/workflows/ci.yml/runs?per_page=100&head_sha="*) ci_runs "$(cat "$T/runs.json" 2>/dev/null || echo "[]")" "$@" ;;
      "issue comment 12 --body "*|"pr comment 7 --body "*|"issue comment 7 --body "*) printf "%s\n" "$5" >> "$T/posted" ;;
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*)
        git -C "$T/github.git" show sessions:usage-limit 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
      "issue edit 12 "*|"pr edit 7 --add-label needs-human") ;;
      *) waiting_on_github "$@" ;;
    esac'
  stub sleep ':'
  git init -q --bare -b main "$T/github.git"
  git init -q -b main "$T/seed"
  echo "# myapp" > "$T/seed/README.md"
  git -C "$T/seed" add -A
  git -C "$T/seed" commit -q -m "chore: start"
  git -C "$T/seed" push -q "$T/github.git" main
  git clone -q "$T/github.git" .
  # For every repo: usage-limit.sh pushes the hold from a clone of its own.
  pushes_go_to github
  git checkout -q -b "$branch"
}
fix_ended() {
  ended "$1"
  echo "export" > export.ts
  git add -A && git commit -q -m "feat: export forecast as CSV"
  git push -q origin "$branch"
  before=$(git rev-parse HEAD)
  echo "$before" > "$T/head"
}
on_github() { git -C "$T/github.git" "$@"; }
pushes_go_to() {
  printf '[url "%s/%s.git"]\n  insteadOf = https://x-access-token:token@github.com/owner/repo.git\n' "$T" "$1" > "$T/gitconfig"
  export GIT_CONFIG_GLOBAL="$T/gitconfig"
}
no_pushing() { pushes_go_to nowhere; }
expect_posted() {
  [[ "$(cat "$T/posted")" == *"$1"* ]] || fail "expected the comment to hold: $1"$'\n'"it was: $(cat "$T/posted")"
}
expect_not_posted() {
  [[ "$(cat "$T/posted")" != *"$1"* ]] || fail "expected the comment not to hold: $1"
}
expect_silence() {
  [ ! -s "$T/posted" ] || fail "expected no comment, got: $(cat "$T/posted")"
  expect_no_call "--add-label needs-human"
}

scenario "a build whose pull request is ready for review is left alone: no comment, no flag, nothing pushed"
ended completed
echo '[{"headRefName":"feat/12-export-forecast-csv"}]' > "$T/pulls.json"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_silence
expect_no_call "gh issue edit"
[ -z "$(on_github branch --list 'feat/*')" ] || fail "expected nothing to be pushed"

scenario "a build whose pull request is ready for review and in conflict gets a fix round, and the job passes"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"CONFLICTING"},{"number":8,"headRefName":"fix/112-other-ticket","mergeable":"CONFLICTING"}]' > "$T/pulls.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_call "gh workflow run fix.yml -f pr=9"
expect_output "a fix round was started for pull request #9"
expect_no_call "pr=8"
expect_silence
expect_no_call "gh issue edit"

scenario "a build whose pull request is ready for review and mergeable gets no fix round"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"MERGEABLE"}]' > "$T/pulls.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "gh pr view"
[ "$(grep -c '^gh pr list' "$T/calls")" = 1 ] || fail "expected GitHub to be asked once"
expect_silence

scenario "a draft in conflict gets no fix round: it is not handed over"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","isDraft":true,"mergeable":"CONFLICTING"}]' > "$T/pulls.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_no_call "gh workflow run"

scenario "a mergeable GitHub has not worked out yet is asked again, and the conflict it then reports gets a fix round"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"UNKNOWN"}]' > "$T/pulls.json"
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"CONFLICTING"}]' > "$T/pulls.later.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
[ "$(grep -c '^gh pr list' "$T/calls")" = 3 ] || fail "expected GitHub to be asked until it answered, three times"
expect_call "gh workflow run fix.yml -f pr=9"

scenario "a mergeable GitHub never works out is asked six times, and then said to be unknown: no fix round, and the job passes"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"UNKNOWN"}]' > "$T/pulls.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
[ "$(grep -c '^gh pr list' "$T/calls")" = 6 ] || fail "expected GitHub to be asked six times"
expect_output "GitHub has not said whether pull request #9 conflicts with its base"
expect_no_call "gh workflow run"

scenario "stops when a later asking cannot be read: that is not 'mergeable'"
ended completed
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"UNKNOWN"}]' > "$T/pulls.json"
stub sleep 'echo "pr list" > "$T/fail"'
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "The pull requests could not be read from GitHub"
expect_no_call "gh workflow run"

while IFS='|' read -r words message; do
  scenario "ready in conflict: stops with a message when this fails: gh $words"
  ended completed
  echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"CONFLICTING"}]' > "$T/pulls.json"
  echo "$words" > "$T/fail"
  run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
  expect_status 1
  expect_output "$message"
  expect_output "Pull request #9 is ready for review and conflicts with its base, and no fix round could be started for it"
  expect_no_output "a fix round was started"
done <<'CALLS'
pr view 9|No fix round was started for pull request #9: GitHub did not say whether it is a draft.
api repos/{owner}/{repo}/issues/9/comments|No fix round was started for pull request #9: its fix rounds could not be counted.
workflow run fix.yml|The fix round for pull request #9 could not be started: GitHub did not start fix.yml.
CALLS

scenario "another ticket's pull request is not this one's: #112 and #3 are not #12"
ended completed
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_posted "The build ended with no pull request ready for review"

scenario "an engineer who stopped on purpose is not spoken over: in-progress comes off and the job passes"
ended completed
echo '{"labels":[{"name":"in-progress"},{"name":"needs-human"}]}' > "$T/labels.json"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_call "gh issue edit 12 --remove-label in-progress"
[ ! -s "$T/posted" ] || fail "expected no comment"
[ -z "$(on_github branch --list 'feat/*')" ] || fail "expected nothing to be pushed"

scenario "an engineer who left the ticket to wait for another is not spoken over: no comment, no flag, and the place goes to a ticket that waits"
ended completed
echo '{"labels":[{"name":"factory"},{"name":"ready"}]}' > "$T/labels.json"
echo '[{"number":20},{"number":21},{"number":28},{"number":29}]' > "$T/issues"
echo '[{"number":30}]' > "$T/ready"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_output "the engineer stopped on purpose and left issue #12 to wait for the ticket it needs"
expect_silence
expect_no_call "gh issue edit 12"
expect_call "gh workflow run implement.yml -f issue=30"
[ -z "$(on_github branch --list 'feat/*')" ] || fail "expected nothing to be pushed"

scenario "ready added while the build ran is no stop on purpose: the build that ended unfinished asks for a person"
ended completed
echo '{"labels":[{"name":"in-progress"},{"name":"ready"}]}' > "$T/labels.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_posted "The build ended with no pull request ready for review"

scenario "a build that ends with needs-human and no pull request, while a ticket waits with ready, starts that ticket's build"
ended completed
echo '[{"number":20},{"number":21},{"number":28},{"number":29}]' > "$T/issues"
echo '[{"number":31},{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_call "gh workflow run implement.yml -f issue=30"
expect_no_call "issue=31"
expect_output "started the build of issue #30, which waited with ready"
[ "$(grep -n 'workflow run' "$T/calls" | cut -d: -f1)" -gt "$(grep -n 'issue edit 12' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the place was given back"

scenario "an engineer who stopped on purpose gives the place to the ticket that waits with ready"
ended completed
echo '{"labels":[{"name":"in-progress"},{"name":"needs-human"}]}' > "$T/labels.json"
echo '[{"number":20},{"number":21},{"number":28},{"number":29}]' > "$T/issues"
echo '[{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_call "gh issue edit 12 --remove-label in-progress"
expect_call "gh workflow run implement.yml -f issue=30"
[ "$(grep -n 'workflow run' "$T/calls" | cut -d: -f1)" -gt "$(grep -n 'issue edit 12' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the place was given back"

scenario "a build that ended at a draft still holds its place: the ticket that waits is not started"
ended completed
echo '[{"number":20},{"number":21},{"number":28},{"number":29}]' > "$T/issues"
echo '[{"number":40,"headRefName":"feat/12-export-forecast-csv","author":{"login":"app/claude"},"labels":[],"isDraft":true}]' > "$T/pulls"
echo '[{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "5 tickets are being built or checked, so no waiting ticket was started"
expect_no_call "gh workflow run"

scenario "a build that used all its turns gives the place to the ticket that waits"
ended max-turns
echo '[{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_call "gh workflow run implement.yml -f issue=30"

# An ending that is not the ticket's own would meet the next build too (decisions T297b).
for how in api-error rate-limit none; do
  scenario "a build ended by $how starts no waiting ticket: its build could end the same way"
  ended "$how"
  echo '[{"number":30}]' > "$T/ready"
  run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
  expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
  expect_output "no waiting ticket was started: its build could end the same way"
  expect_no_call "labels=ready"
  expect_no_call "gh workflow run"
done

scenario "a build that handed over frees no place, and starts no waiting ticket"
ended completed
echo '[{"number":30}]' > "$T/ready"
echo '[{"number":9,"headRefName":"feat/12-export-forecast-csv","mergeable":"MERGEABLE"}]' > "$T/pulls.json"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

scenario "the owner's round that pushed nothing flags a ticket whose pull request holds its place: no waiting ticket is started"
fix_ended completed
echo '[{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" false
expect_status 0
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_no_call "labels=ready"
expect_no_call "gh workflow run"

while IFS='|' read -r words message; do
  scenario "a build that ended unfinished, its ticket flagged: says the waiting were not started when this fails: gh $words"
  ended completed
  echo '[{"number":30}]' > "$T/ready"
  echo "$words" > "$T/fail"
  run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
  expect_status 1
  expect_output "$message"
  expect_output "Issue #12 gave its place back, and the tickets that wait with ready were not all started"
  expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
  expect_posted "The build ended with no pull request ready for review"

  scenario "an engineer who stopped on purpose: stops with a message, the place given back, when this fails: gh $words"
  ended completed
  echo '{"labels":[{"name":"in-progress"},{"name":"needs-human"}]}' > "$T/labels.json"
  echo '[{"number":30}]' > "$T/ready"
  echo "$words" > "$T/fail"
  run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
  expect_status 1
  expect_output "$message"
  expect_output "Issue #12 gave its place back, and the tickets that wait with ready were not all started"
  expect_call "gh issue edit 12 --remove-label in-progress"
done <<'CALLS'
api repos/{owner}/{repo}/issues?state=open&labels=ready|the tickets labelled ready could not be read from GitHub
api repos/{owner}/{repo}/issues?state=open&labels=in-progress|what is in flight could not be read from GitHub
api repos/{owner}/{repo}/issues/30/events|when issue #30 was labelled ready could not be read from GitHub
workflow run implement.yml|the build of these waiting tickets could not be started: #30
CALLS

scenario "a build cut short has its work pushed, and the ticket is told the cause and the branch"
ended api-error
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"
expect_posted "The build ended with no pull request ready for review: the model's API was overloaded (error 529)."
expect_first_line "gh issue comment 12 --body" "Add the \`ready\` label again: the next build starts from the branch \`$branch\`."
expect_posted "What the engineer had is on the branch \`$branch\`, unfinished and unverified; its pull request, if it has one, is still a draft."
expect_posted "See https://github.com/owner/repo/actions/runs/900"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a build cut short with its pull request still a draft is kept and flagged: a draft is not handed over"
ended api-error
echo '[{"headRefName":"feat/12-export-forecast-csv","isDraft":true}]' > "$T/pulls.json"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"
expect_posted "The build ended with no pull request ready for review: the model's API was overloaded (error 529)."
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a rebuild cut short is kept and flagged when the ticket's only pull request was closed without merging"
ended api-error
echo '[{"headRefName":"feat/12-export-forecast-csv","state":"CLOSED"}]' > "$T/pulls.json"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_call "gh pr list --state open"
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"
expect_posted "The build ended with no pull request ready for review: the model's API was overloaded (error 529)."
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a build whose engineer ended early with everything pushed is told the branch too"
ended completed
echo "export" > export.ts
git add -A && git commit -q -m "feat: export forecast as CSV"
git push -q origin "$branch"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_posted "the agent ended its session before the work was handed over. What the engineer had is on the branch \`$branch\`"

scenario "a build the usage limit ended keeps the work, holds every agent until the reset time and waits with ready, and the job passes"
ended usage-limit
echo "export" > export.ts
echo '[{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 0
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"
[ "$(on_github show sessions:usage-limit 2>&1)" = 1795431600 ] || fail "expected the reset time on the sessions branch, got: $(on_github show sessions:usage-limit 2>&1)"
expect_first_line "gh issue comment 12 --body" "Nothing to do: after the Claude usage limit resets on 2026-11-23 11:00 UTC, the next build starts from the branch \`$branch\`."
expect_posted "The build ended with no pull request ready for review: the Claude usage limit was reached (\"You've hit your Fable limit · resets Nov 23, 11am (UTC)\"). What the engineer had is on the branch \`$branch\`"
[ "$(grep -c "^gh issue comment" "$T/calls")" = 1 ] || fail "expected one comment"
expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"
expect_no_call "--add-label needs-human"
expect_output "no waiting ticket was started: its build could end the same way"
expect_no_call "gh workflow run"

scenario "a build the usage limit ended, whose reset time and work cannot be pushed, asks for a person and fails the job"
ended usage-limit
echo "export" > export.ts
no_pushing
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "that could not be written to the sessions branch, so nothing holds the other agents until then"
expect_first_line "gh issue comment 12 --body" "Add the \`ready\` label again: the build starts again from the beginning."
expect_posted "could not be pushed, and is lost with the runner."
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a build cut short by anything else holds no agent"
ended api-error
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
! on_github show sessions:usage-limit >/dev/null 2>&1 || fail "expected no hold on the sessions branch"

# 99999999999 is a reset time that stays ahead: a round waits only while the limit holds.
scenario "a fix round the usage limit ended keeps its place and asks for no person, and the job passes"
resets_at=99999999999 fix_ended usage-limit
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
[ "$(on_github show sessions:usage-limit 2>&1)" = "99999999999"$'\n'"run 900" ] || fail "expected the reset time and run 900 on the sessions branch, got: $(on_github show sessions:usage-limit 2>&1)"
expect_first_line "gh issue comment 7 --body" "Nothing to do: a new fix round starts after the Claude usage limit resets on 5138-11-16 09:46 UTC."
[ "$(wc -l < "$T/posted")" -eq 3 ] || fail "expected one comment, got: $(cat "$T/posted")"
expect_no_call "needs-human"
expect_output "the fix round pushed nothing: the Claude usage limit was reached"

scenario "the owner's fix round the usage limit ended leaves its ticket in progress"
resets_at=99999999999 fix_ended usage-limit
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" false
expect_status 0
expect_no_call "needs-human"
expect_no_call "gh pr view 7 --json body"

scenario "a fix round the usage limit ended, which cannot be told that it waits, stops with what a person must run"
resets_at=99999999999 fix_ended usage-limit
echo "issue comment 7" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_output "its place could not be kept: run \`gh workflow run fix.yml -f pr=7\` after 5138-11-16 09:46 UTC."

scenario "a fix round ended by a usage limit that has already reset asks for a person as before"
resets_at=1000000000 fix_ended usage-limit
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_first_line "gh pr comment 7 --body" "Run \`gh workflow run fix.yml -f pr=7\` after 2001-09-09 01:46 UTC: a new fix round starts."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "a build with nothing to keep says so, and still fails the job"
ended api-error
git checkout -q main
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_first_line "gh issue comment 12 --body" "Add the \`ready\` label again: the build starts again from the beginning."
expect_posted "the model's API was overloaded (error 529). There was no work to keep: the engineer had not started a branch, or had changed nothing on it."
expect_not_posted "is on the branch"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a build whose work could not be pushed says it is lost"
ended api-error
no_pushing
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_first_line "gh issue comment 12 --body" "Add the \`ready\` label again: the build starts again from the beginning."
expect_posted "What the engineer had could not be pushed, and is lost with the runner."
expect_not_posted "is on the branch"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a build with no readable result still keeps the work and says why nothing is known"
ended completed
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 ""
expect_status 1
expect_posted "The build ended with no pull request ready for review: the agent left no result that could be read."
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"

# A job stopped at its time limit leaves no result, and its build starts again (decisions A467a, A467b).
scenario "a build stopped at its time limit keeps the work, names the limit and starts again with nobody asked"
ended none
echo '[{"number":12}]' > "$T/ready"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "" true
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"
expect_first_line "gh issue comment 12 --body" "Nothing to do: the factory builds this ticket again when a place is free, and the next build starts from the branch \`$branch\`."
expect_posted "The build ended with no pull request ready for review: the job reached its time limit."
expect_not_posted "no result that could be read"
expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"
expect_no_call "--add-label needs-human"
expect_call "gh workflow run implement.yml -f issue=12"
[ "$(grep -n 'workflow run' "$T/calls" | cut -d: -f1)" -gt "$(grep -n 'issue edit 12' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the build to be started after the ticket was labelled ready"
at_limit=$(cat "$T/posted")

scenario "a second build in a row stopped at its time limit asks for the ticket to be split, and gives no command"
ended none
jq -n --arg body "$at_limit" '[{event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: $body}, {event: "labeled", label: {name: "ready"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: "Waiting: 5 tickets are being built or checked."}, {event: "labeled", label: {name: "in-progress"}}]' > "$T/timeline.json"
echo '[{"number":30}]' > "$T/ready"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_status 1
expect_first_line "gh issue comment 12 --body" "Split this ticket into smaller tickets: two builds in a row reached the job's time limit, so it is too large for one session."
expect_posted "The build ended with no pull request ready for review: the job reached its time limit. What the engineer had is on the branch \`$branch\`"
expect_not_posted "label"
expect_not_posted "gh "
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_no_call "issue=12"
expect_call "gh workflow run implement.yml -f issue=30"
split=$(cat "$T/posted")

scenario "a build stopped at its time limit after the ticket was asked to be split asks again"
ended none
jq -n --arg first "$at_limit" --arg second "$split" '[{event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: $first}, {event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: $second}, {event: "labeled", label: {name: "in-progress"}}]' > "$T/timeline.json"
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_first_line "gh issue comment 12 --body" "Split this ticket into smaller tickets: two builds in a row reached the job's time limit, so it is too large for one session."
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

for login in stranger github-actions; do
  scenario "a build stopped at its time limit starts again when the marker before it is in a comment by $login, not the factory"
  ended none
  jq -n --arg body "$at_limit" --arg login "$login" '[{event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: $login}, body: $body}, {event: "labeled", label: {name: "in-progress"}}]' > "$T/timeline.json"
  echo '[{"number":12}]' > "$T/ready"
  run "$scripts/flag-unfinished.sh" build 12 "" true
  expect_first_line "gh issue comment 12 --body" "Nothing to do: the factory builds this ticket again when a place is free, and the build starts again from the beginning."
  expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"
  expect_no_call "--add-label needs-human"
done

scenario "a build stopped at its time limit starts again when the build before it ended another way"
ended none
jq -n --arg body "$at_limit" '[{event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: $body}, {event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: "Add the `ready` label again.\n\nThe build ended with no pull request ready for review: the model'"'"'s API was overloaded (error 529)."}, {event: "labeled", label: {name: "in-progress"}}]' > "$T/timeline.json"
echo '[{"number":12}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_first_line "gh issue comment 12 --body" "Nothing to do: the factory builds this ticket again when a place is free, and the build starts again from the beginning."
expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"
expect_call "gh workflow run implement.yml -f issue=12"

scenario "a build stopped at its time limit starts again when the engineer stopped the build before it on purpose"
ended none
jq -n --arg body "$at_limit" '[{event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: $body}, {event: "labeled", label: {name: "in-progress"}}, {event: "commented", user: {login: "github-actions[bot]"}, body: "This ticket cannot be built as written."}, {event: "labeled", label: {name: "in-progress"}}]' > "$T/timeline.json"
echo '[{"number":12}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_first_line "gh issue comment 12 --body" "Nothing to do: the factory builds this ticket again when a place is free, and the build starts again from the beginning."
expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"

scenario "a build stopped at its time limit whose draft holds its place starts again beside four others in flight"
ended none
echo '[{"number":20},{"number":21},{"number":28},{"number":29}]' > "$T/issues"
echo '[{"number":40,"headRefName":"feat/12-export-forecast-csv","author":{"login":"app/claude"},"labels":[],"isDraft":true}]' > "$T/pulls"
echo '[{"number":12},{"number":30}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_call "gh workflow run implement.yml -f issue=12"
expect_no_call "issue=30"

scenario "a build stopped at its time limit that cannot be started keeps ready, and the job says so"
ended none
echo '[{"number":12}]' > "$T/ready"
echo "workflow run implement.yml" > "$T/fail"
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_status 1
expect_call "gh issue edit 12 --add-label ready --remove-label in-progress"
expect_output "the tickets that wait with ready were not all started; each is started when a place next frees"

scenario "a build stopped before its time limit, with no result, asks for a person as before"
ended none
echo '[{"number":12}]' > "$T/ready"
run "$scripts/flag-unfinished.sh" build 12 "" ""
expect_status 1
expect_posted "The build ended with no pull request ready for review: the agent left no result that could be read."
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_no_call "issues/12/timeline"
expect_no_call "gh workflow run"

scenario "a build the usage limit ended in a job stopped at its time limit waits for the reset, not for a rebuild"
ended usage-limit
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json" true
expect_posted "Nothing to do: after the Claude usage limit resets on"
expect_posted "the Claude usage limit was reached"
expect_no_call "issues/12/timeline"
expect_no_call "gh workflow run"

scenario "stops when the ticket's timeline cannot be read: that is not 'the build before ended another way'"
ended none
echo "api repos/{owner}/{repo}/issues/12/timeline" > "$T/fail"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "" true
expect_status 1
expect_output "The timeline of issue #12 could not be read from GitHub"
expect_silence
expect_no_call "gh issue edit"
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"

scenario "the build's job tells the script whether it stopped at its time limit, having worked that out first"
workflow="$root/factory/workflows/implement.yml"
# shellcheck disable=SC2016
grep -qF '/flag-unfinished.sh" build "$ISSUE" "$FILE" "${{ steps.limit.outputs.reached }}"' "$workflow" \
  || fail "expected the job to pass what its time-limit step found to flag-unfinished.sh"
[ "$(grep -n -E '^      - name: (Tell whether this job stopped at its time limit|Keep the work and flag the ticket)' "$workflow" | head -n 1 | grep -c 'Tell whether')" = 1 ] \
  || fail "expected the time-limit step to come before the step that flags the ticket"

scenario "stops when the pull requests cannot be read: that is not 'none was opened'"
ended api-error
echo "pr list" > "$T/fail"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "The pull requests could not be read from GitHub"
expect_silence
[ -z "$(on_github branch --list 'feat/*')" ] || fail "expected nothing to be pushed"

scenario "stops when the ticket cannot be read: that is not 'not flagged'"
ended api-error
echo "issue view" > "$T/fail"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "Issue #12 could not be read from GitHub"
expect_silence

scenario "stops with a message when the ticket cannot be commented on, the work already kept"
ended api-error
echo "issue comment" > "$T/fail"
echo "export" > export.ts
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "Could not comment on issue #12"
[ "$(on_github show "$branch:export.ts" 2>&1)" = export ] || fail "expected the work on GitHub"

scenario "stops with a message when the ticket cannot be flagged"
ended api-error
echo "issue edit" > "$T/fail"
run "$scripts/flag-unfinished.sh" build 12 "$T/session.json"
expect_status 1
expect_output "Could not add needs-human to issue #12"

scenario "a fix round that pushed is left alone"
fix_ended completed
echo 6666666666666666666666666666666666666666 > "$T/head"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_silence

scenario "a round to start the checks that pushed nothing, and left a ci run of the head running its jobs, is left alone"
fix_ended completed
echo '[{"databaseId":902,"conclusion":""},{"databaseId":901,"conclusion":"skipped"}]' > "$T/runs.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" start-checks
expect_status 0
expect_output "handed over: the checks of pull request #7 were started"
expect_silence
expect_no_call "retro.yml"

scenario "a round to start the checks that left only a skipped ci run asks a person to start them, whatever the engineer answered"
fix_ended completed
jq -c '.[-1].result = "Nothing to do: the checks of this pull request are running."' "$T/session.json" > "$T/answered.json"
echo '[{"databaseId":901,"conclusion":"skipped"}]' > "$T/runs.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/answered.json" "$before" start-checks
expect_status 0
expect_first_line "gh pr comment 7 --body" "Convert this pull request to a draft, then mark it ready for review: that starts its checks."
expect_posted "The fix round to start the checks started none: no ci run of ${before:0:7}, the last commit of this pull request, ran its jobs."
expect_not_posted "the checks of this pull request are running"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "any other round that pushed nothing is not taken for handed over by a ci run of the head"
fix_ended completed
echo '[{"databaseId":902,"conclusion":"failure"}]' > "$T/runs.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" true
expect_status 0
expect_posted "The fix round pushed nothing"
expect_no_call "gh api repos/{owner}/{repo}/actions/workflows/ci.yml/runs"

scenario "a round to start the checks stops with a message when the ci runs cannot be listed"
fix_ended completed
echo "api repos/{owner}/{repo}/actions/workflows/ci.yml/runs" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" start-checks
expect_status 1
expect_output "The ci runs for ${before:0:7}, the head of pull request #7, could not be listed, so it is not known whether its checks were started."
expect_silence

scenario "a fix round that changed nothing on purpose is not reported as unverified work or as cut short"
fix_ended completed
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_posted "The fix round pushed nothing: the engineer ended the session with no change to the pull request, which is as the checks and reviews last saw it."
expect_first_line "gh pr comment 7 --body" "Read the engineer's comment above, then submit a \"Request changes\" review saying what to change: that starts a fix round that is not one of the three."
expect_posted "the reasons are in the comments above. See https://github.com/owner/repo/actions/runs/900"
expect_not_posted "unverified"
expect_not_posted "is on the branch"
expect_not_posted "before the work was handed over"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"
[ "$(on_github rev-parse "$branch")" = "$before" ] || fail "expected the branch on GitHub to be left alone"

scenario "a fix round whose engineer stopped for a person starts a retro: the job passes, so no failed job starts one"
fix_ended completed
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "a fix round whose engineer stopped for a person stops with a message when the retro cannot be started"
fix_ended completed
echo "workflow run retro.yml" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_output "The fix round on pull request #7 pushed nothing and a person was asked, but the retro could not be started."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "a fix round whose engineer answered what it needs starts its comment with the first line of that answer"
fix_ended completed
jq -c '.[-1].result = "Switch Magic Link on in Neon for branch `main`, then run the `e2e` job again.\n\nThe rest."' "$T/session.json" > "$T/answered.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/answered.json" "$before"
expect_status 0
expect_first_line "gh pr comment 7 --body" "Switch Magic Link on in Neon for branch \`main\`, then run the \`e2e\` job again."
expect_posted "The fix round pushed nothing"
expect_not_posted "The rest."
expect_not_posted "Read the engineer's comment above"

scenario "a fix round whose engineer labelled the pull request waits-for-main says the next merge tests it, and asks for no person"
fix_ended completed
echo '[{"name":"waits-for-main"}]' > "$T/pr-labels.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_first_line "gh pr comment 7 --body" "Nothing to do: the next merge to \`main\` tests this pull request again."
expect_posted "The fix round pushed nothing: the engineer labelled this pull request \`waits-for-main\`, as what failed lies outside it, and the comment above says what it waits for. See https://github.com/owner/repo/actions/runs/900"
expect_not_posted "gh workflow run fix.yml"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"
expect_no_call "gh workflow run retro.yml"

scenario "a labelled pull request whose fix round was cut short is told the cause, and that it needs a person"
fix_ended api-error
echo '[{"name":"waits-for-main"}]' > "$T/pr-labels.json"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_first_line "gh pr comment 7 --body" "Run \`gh workflow run fix.yml -f pr=7\`: a new fix round starts."
expect_posted "The fix round ended without pushing a fix: the model's API was overloaded (error 529)."

scenario "the owner's round that pushed nothing flags the ticket it had unflagged, with the pull request"
fix_ended completed
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" false
expect_status 0
expect_posted "The fix round pushed nothing"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_no_call "gh workflow run retro.yml"

scenario "the owner's round that pushed leaves the ticket in progress: the checks have it now"
fix_ended completed
echo 6666666666666666666666666666666666666666 > "$T/head"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" false
expect_status 0
expect_silence
expect_no_call "gh issue edit"

scenario "a round counted, or said nothing about, leaves the ticket alone: fix.yml as it was before it said"
fix_ended completed
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" true
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" ""
expect_status 0
expect_no_call "gh issue edit"

while IFS='|' read -r words message; do
  scenario "the owner's round that pushed nothing: stops with a message when this fails: gh $words"
  fix_ended completed
  echo "$words" > "$T/fail"
  run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before" false
  expect_status 1
  expect_output "$message"
  expect_call "gh pr edit 7 --add-label needs-human"
done <<'CALLS'
pr view 7 --json body|The ticket pull request #7 closes could not be read, so it was not flagged for a person.
issue edit 12|Could not add needs-human to issue #12, which pull request #7 closes.
CALLS

scenario "a fix round cut short with nothing changed says the cause, reports no work, and fails the job"
fix_ended api-error
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_first_line "gh pr comment 7 --body" "Run \`gh workflow run fix.yml -f pr=7\`: a new fix round starts."
expect_posted "The fix round ended without pushing a fix: the model's API was overloaded (error 529). The engineer left no work to keep"
expect_not_posted "unverified"
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh workflow run retro.yml"

scenario "a fix round cut short with uncommitted work has it pushed, and says it is unverified"
fix_ended api-error
echo "more" >> export.ts
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
[ "$(on_github log -1 --format=%s "$branch")" = "chore: keep the unfinished work on pull request #7" ] || fail "expected the work on GitHub"
expect_first_line "gh pr comment 7 --body" "Submit a \"Request changes\" review saying what is left to do: the engineer carries on from the branch in a fix round that is not one of the three."
expect_posted "The fix round ended without handing over a fix: the model's API was overloaded (error 529). What the engineer had is on the branch \`$branch\`, unfinished and unverified; no checks ran on it."

scenario "a fix round the usage limit ended with work kept asks for the review after the reset time: its head has no failed check to begin from"
fix_ended usage-limit
echo "more" >> export.ts
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
[ "$(on_github show sessions:usage-limit 2>&1)" = 1795431600 ] || fail "expected the reset time on the sessions branch, and no run that waits"
expect_first_line "gh pr comment 7 --body" "Submit a \"Request changes\" review after 2026-11-23 11:00 UTC saying what is left to do: the engineer carries on from the branch in a fix round that is not one of the three."
expect_no_call "gh workflow run retro.yml"

scenario "a fix the engineer committed, never pushed, and ended the session on is pushed and said to be unverified"
fix_ended completed
echo "more" >> export.ts
git add -A && git commit -q -m "fix: quote the fields"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 0
[ "$(on_github log -1 --format=%s "$branch")" = "fix: quote the fields" ] || fail "expected the commit on GitHub"
expect_posted "What the engineer had is on the branch \`$branch\`, unfinished and unverified; no checks ran on it."
expect_call "gh workflow run retro.yml -f pr=7"

scenario "an engineer who never checked the pull request out left no work"
fix_ended api-error
git checkout -q --detach
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_posted "The engineer left no work to keep"

scenario "a fix round whose work could not be pushed says it is lost, and fails the job however the session ended"
fix_ended completed
no_pushing
echo "more" >> export.ts
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_first_line "gh pr comment 7 --body" "Run \`gh workflow run fix.yml -f pr=7\`: a new fix round starts."
expect_posted "What the engineer had could not be pushed, and is lost with the runner."
expect_not_posted "is on the branch"
expect_no_call "gh workflow run retro.yml"

scenario "stops when the pull request cannot be read: that is not 'nothing was pushed'"
fix_ended completed
echo "pr view" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_output "Pull request #7 could not be read from GitHub"
expect_silence

scenario "stops with a message when the pull request cannot be commented on or flagged"
fix_ended completed
echo "pr comment" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_output "Could not comment on pull request #7"
echo "pr edit" > "$T/fail"
run "$scripts/flag-unfinished.sh" fix 7 "$T/session.json" "$before"
expect_status 1
expect_output "Could not add needs-human to pull request #7"

scenario "a kind it does not know is refused"
ended completed
run "$scripts/flag-unfinished.sh" retro 7 "$T/session.json"
expect_status 2
expect_output "usage: flag-unfinished.sh"
