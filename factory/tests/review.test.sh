#!/usr/bin/env bash
# Tests for review.sh: both reviews as sessions side by side in the base's files, and each verdict posted after.
. "$(dirname "$0")/helpers.sh"

# reviews: pull request #7, whose commit $head changes main's instructions, settings and a script, adds a server and a
# hook, and is not what is checked out: main is. A stand-in for claude prints $T/<reviewer>.<n> for that reviewer's nth
# session. $T/fail lists the gh calls, by their first words, that fail; $T/posted keeps what was posted; $T/hold is the
# usage limit's record.
reviews() {
  : > "$T/fail"
  : > "$T/outputs"
  : > "$T/posted"
  export GITHUB_OUTPUT="$T/outputs" RUNNER_TEMP="$T/runner" GH_TOKEN=token HEAD_SHA
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=900
  export ADAM_PROMPT="You are Adam. Review pull request #7." ADAM_SCHEMA='{"for":"adam"}'
  export RYAN_PROMPT="You are Ryan. Review pull request #7." RYAN_SCHEMA='{"for":"ryan"}'
  mkdir -p "$T/runner"
  real_git=$(PATH="$_path" command -v git); export real_git
  "$real_git" init --quiet --initial-branch=main .
  mkdir -p .claude/skills/review-code
  echo "main's settings" > .claude/settings.json; echo "main's skill" > .claude/skills/review-code/SKILL.md
  echo "main's rules" > CLAUDE.md; echo "main's script" > script.sh
  "$real_git" add . && "$real_git" commit --quiet -m "main"
  "$real_git" checkout --quiet -b feat/7-change
  echo "the pull request's settings" > .claude/settings.json; echo "the pull request's skill" > .claude/skills/review-code/SKILL.md
  echo "the pull request's rules" > CLAUDE.md; echo "the pull request's script" > script.sh
  echo '{"mcpServers":{}}' > .mcp.json; mkdir .husky; echo "exit 0" > .husky/pre-commit; echo "a new skill" > .claude/skills/new.md
  "$real_git" add . && "$real_git" commit --quiet -m "the pull request"
  HEAD_SHA=$("$real_git" rev-parse HEAD); head=$HEAD_SHA
  "$real_git" checkout --quiet main
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) [ -e "$T/hold" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$T/hold" ;;
      "pr comment 7 --body-file "*) cat "$5" >> "$T/posted" ;;
      "pr comment 7 --body "*) printf "%s\n" "$5" >> "$T/posted" ;;
      "pr edit 7 --add-label needs-human") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub claude '
    case "$*" in
      *"You are Adam."*|*"--resume adam-session"*) role=adam; other=ryan ;;
      *"You are Ryan."*|*"--resume ryan-session"*) role=ryan; other=adam ;;
      *) exit 1 ;;
    esac
    n=$(($(cat "$T/$role.n" 2>/dev/null || echo 0) + 1))
    echo "$n" > "$T/$role.n"
    : > "$T/$role.started"
    { pwd; cat .claude/settings.json .claude/skills/review-code/SKILL.md CLAUDE.md script.sh; ls -A; ls .claude/skills; } > "$T/$role.here" 2>&1
    cat "$RUNNER_TEMP/pull-request/CLAUDE.md" "$RUNNER_TEMP/pull-request/script.sh" "$RUNNER_TEMP/pull-request/.mcp.json" > "$T/$role.there" 2>&1
    # With $T/together, a session ends only once the other has started: one after the other, neither would.
    if [ -e "$T/together" ]; then
      for _ in $(seq 100); do [ -e "$T/$other.started" ] && break; command -p sleep 0.1; done
      [ -e "$T/$other.started" ] || exit 1
    fi
    [ ! -f "$T/$role.$n" ] || cat "$T/$role.$n"
    [ ! -e "$T/$role.$n.fails" ] || exit 1'
  stub sleep 'exit 0'
  # This git reads the checkout and puts the pull request beside it; it reports a change to commit (the transcript),
  # which save-session.sh reads as saved.
  stub git 'case "$1" in rev-parse|worktree) exec "$real_git" "$@" ;; esac
    case "$*" in *"diff --cached --quiet") exit 1 ;; esac; exit 0'
}
# says <reviewer> <n> pass|fail|long|api-error: the messages that reviewer's nth session prints, a line each.
says() {
  local result
  case "$3" in
    pass) result='"is_error":false,"terminal_reason":"completed","structured_output":{"findings":[],"assumptions":[]}' ;;
    fail) result='"is_error":false,"terminal_reason":"completed","structured_output":{"findings":[{"file":"'"$1"'.sh","line":3,"kind":"'"$([ "$1" = adam ] && echo design || echo bug)"'","problem":"Found by '"$1"'.","fix":"Guard it."}],"assumptions":[]}' ;;
    long) result='"is_error":false,"terminal_reason":"completed","structured_output":{"findings":[{"file":"'"$1"'.sh","kind":"bug","problem":"Wrong.","fix":"'"$(printf 'word %.0s' $(seq 41))"'"}],"assumptions":[]}' ;;
    api-error) result='"is_error":true,"terminal_reason":"api_error","api_error_status":529' ;;
  esac
  printf '{"type":"system","subtype":"init","session_id":"%s-session"}\n{"type":"result","subtype":"success","session_id":"%s-session",%s}\n' "$1" "$1" "$result" > "$T/$1.$2"
}
# ended <reviewer> pass|fail|api-error [cut-short]: the transcript the sessions' job kept for that reviewer, or one cut short.
ended() {
  says "$1" 0 "$2"
  if [ -n "${3:-}" ]; then
    mkdir -p "$T/runner/reviews/cut-short-sessions"
    jq -s . "$T/$1.0" > "$T/runner/reviews/cut-short-sessions/20261120T010000Z-$1.json"
  else
    mkdir -p "$T/runner/reviews"
    jq -s . "$T/$1.0" > "$T/runner/reviews/$1.json"
  fi
}
sessions() { run "$scripts/review.sh" sessions 7 "$head" "$@" -- --model some-model --max-turns 40 --allowedTools "Read,Bash(git diff:*)"; }
verdicts() { run "$scripts/review.sh" verdicts 7 "$@"; }
expect_posted() {
  [[ "$(cat "$T/posted")" == *"$1"* ]] || fail "expected a comment to hold: $1"$'\n'"posted: $(cat "$T/posted")"
}
expect_cut_short() { grep -qx 'cut-short=true' "$T/outputs" || fail "expected the job to be marked cut short, so that no fix round starts"; }
expect_not_cut_short() { ! grep -q cut-short "$T/outputs" || fail "expected the job not to be marked cut short: that would keep the fix round from starting"; }
# The sessions' job holds no token that writes (decisions A427f).
expect_nothing_written() {
  expect_no_call "gh pr"
  expect_no_call "git commit"
  expect_no_call "git push"
  [ ! -s "$T/posted" ] || fail "expected nothing posted by the job that runs the sessions"
}
there="This directory is a checkout of the branch the pull request merges into. The pull request's files, as its commit"

scenario "sessions: each reviewer has a session with its own prompt and format, told where the pull request's files are; nothing is posted or saved"
reviews; says adam 1 pass; says ryan 1 pass
sessions adam ryan
expect_status 0
expect_call "claude -p You are Adam. Review pull request #7."
expect_call "$there $head has them, are in $T/runner/pull-request: read them there. \`git diff\` and \`git log\` know that commit from this directory. --model some-model --max-turns 40 --allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"adam\"} --output-format stream-json --verbose"
expect_call "claude -p You are Ryan. Review pull request #7."
expect_call "--allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"ryan\"} --output-format stream-json --verbose"
expect_calls 2 "claude -p"
expect_output "adam: ended with a verdict"
expect_output "ryan: ended with a verdict"
expect_nothing_written
for reviewer in adam ryan; do
  [ "$(jq -r '"\(type) \(length) \(.[0].subtype) \(.[-1].session_id)"' "$T/runner/reviews/$reviewer.json")" = "array 2 init $reviewer-session" ] \
    || fail "expected $reviewer's transcript kept as an array of its two messages"
done

scenario "sessions: the two run at the same time: each ends only once the other has started"
reviews; says adam 1 pass; says ryan 1 pass
: > "$T/together"
sessions adam ryan
expect_status 0

scenario "sessions: a session starts in main's files, with no file of the pull request in its directory, and the pull request's are beside it"
reviews; says ryan 1 pass
sessions ryan
expect_status 0
[ "$(sed -n 1,5p "$T/ryan.here")" = "$T/work"$'\n'"main's settings"$'\n'"main's skill"$'\n'"main's rules"$'\n'"main's script" ] \
  || fail "expected the session to start in the checkout of main and read main's settings, skill, rules and script there, got: $(cat "$T/ryan.here")"
! sed 1,5d "$T/ryan.here" | grep -qxE '\.mcp\.json|\.husky|new\.md|pull-request' || fail "expected nothing of the pull request in the session's directory, found: $(sed 1,5d "$T/ryan.here" | tr '\n' ' ')"
[ "$(cat "$T/ryan.there")" = "the pull request's rules"$'\n'"the pull request's script"$'\n''{"mcpServers":{}}' ] \
  || fail "expected the pull request's files outside the session's directory, got: $(cat "$T/ryan.there")"
case "$T/runner/pull-request/" in "$T/work/"*) fail "expected the pull request's files outside the checkout" ;; esac

scenario "sessions: one the model's API cut short is continued by its id, after the wait, and its transcript is kept for the job that saves it"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 2 pass
sessions adam ryan
expect_status 0
expect_call "sleep 120"
expect_call "--resume ryan-session --model some-model --max-turns 40 --allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"ryan\"} --output-format stream-json --verbose"
expect_call "claude -p Your session ended before your work was handed over: the model's API was overloaded (error 529). You have not given your result."
expect_calls 3 "claude -p"
expect_no_call "--resume adam-session"
expect_nothing_written
[ "$(ls "$T/runner/reviews/cut-short-sessions" | grep -c -- '-ryan\.json$')" = 1 ] || fail "expected the transcript cut short kept under reviews/cut-short-sessions"
[ "$(jq -r '.[-1].terminal_reason' "$T/runner/reviews/cut-short-sessions/"*-ryan.json)" = api_error ] || fail "expected the kept transcript to be the one cut short"
[ "$(jq -r '.[-1].terminal_reason' "$T/runner/reviews/ryan.json")" = completed ] || fail "expected the last transcript to be the one that gave the verdict"

scenario "sessions: one cut short three times is continued twice and no more, and the job fails, so that it is run again"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 2 api-error; says ryan 3 api-error; says ryan 4 pass
sessions adam ryan
expect_status 1
expect_calls 2 "--resume ryan-session"
expect_call "sleep 300"
expect_output "adam: ended with a verdict"
expect_output "ryan: ended with no verdict that can be posted"
expect_nothing_written

scenario "sessions: a verdict still over a limit after two continuations fails the job: it would be refused, not posted"
reviews; says ryan 1 long; says ryan 2 long; says ryan 3 long
sessions ryan
expect_status 1
expect_calls 2 "--resume ryan-session"
expect_output "ryan: ended with no verdict that can be posted"

scenario "sessions: a fail is a verdict: the job passes, and the job that posts it fails"
reviews; says adam 1 fail; says ryan 1 pass
sessions adam ryan
expect_status 0

scenario "sessions: a continued session that prints nothing leaves the transcript before it, which is looked at again"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 3 pass
sessions adam ryan
expect_status 0
expect_calls 2 "--resume ryan-session"

scenario "sessions: claude fails and prints nothing, as when it was never installed: no transcript is kept, and the job fails"
reviews
: > "$T/adam.1.fails"; : > "$T/ryan.1.fails"
sessions adam ryan
expect_status 1
expect_calls 2 "claude -p"
[ ! -e "$T/runner/reviews/adam.json" ] || fail "expected no transcript kept for a session that printed nothing"

scenario "sessions: claude fails after printing its verdict: the verdict is in what it printed"
reviews; says adam 1 pass; says ryan 1 pass
: > "$T/ryan.1.fails"
sessions adam ryan
expect_status 0

scenario "sessions: only the reviewer named reviews: the other's pass was carried"
reviews; says ryan 1 pass
sessions ryan
expect_status 0
expect_calls 1 "claude -p"
expect_no_call "You are Adam."

scenario "sessions: while the Claude usage limit holds every agent no session starts, and the job fails marked held, to be run again"
reviews; says ryan 1 pass
echo 4102444800 > "$T/hold"
sessions adam ryan
expect_status 1
expect_output "The Claude usage limit holds every agent until 2100-01-01 00:00 UTC: no review started, and this job is run again after it."
grep -qx 'held=true' "$T/outputs" || fail "expected the job to be marked held, so that the job after it keeps this run's place"
expect_no_call "claude"
expect_nothing_written

scenario "sessions: when the usage limit's record cannot be read no session starts"
reviews; says ryan 1 pass
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
sessions ryan
expect_status 2
expect_output "review.sh: whether the Claude usage limit holds every agent is not known, so no review started."
expect_no_call "claude"
! grep -q held "$T/outputs" || fail "expected the job not to be marked held: nothing is known to hold it"

scenario "sessions: the pull request's commit is not in the checkout: no session starts"
reviews
head=0123456789012345678901234567890123456789
sessions ryan
expect_status 2
expect_output "review.sh: the pull request's commit $head is not in this checkout, so its files could not be put beside it, and no review ran."
expect_no_call "claude"

scenario "sessions: the pull request's files cannot be put beside the checkout: no session starts in them"
reviews
stub git 'case "$1" in rev-parse) exec "$real_git" "$@" ;; worktree) echo "git: failed" >&2; exit 1 ;; esac; exit 0'
sessions ryan
expect_status 2
expect_output "review.sh: the files of the pull request's commit $head could not be put in $T/runner/pull-request, so no review ran."
expect_no_call "claude"

scenario "sessions: a second review in a checkout that outlived the first, whose folder of the pull request's files is gone, still runs"
reviews; says ryan 1 pass; says ryan 2 pass
sessions ryan
expect_status 0
rm -rf "$T/runner/pull-request"
sessions ryan
expect_status 0
expect_output "ryan: ended with a verdict"
[ "$(cat "$T/ryan.there")" = "the pull request's rules"$'\n'"the pull request's script"$'\n''{"mcpServers":{}}' ] \
  || fail "expected the second session to read the pull request's files, got: $(cat "$T/ryan.there")"

scenario "verdicts: both pass: two verdicts are posted, each naming the commit, both transcripts are saved, and the job passes"
reviews; ended adam pass; ended ryan pass
verdicts adam ryan
expect_status 0
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): PASS**"
[ "$(grep -c "<!-- factory:reviewed $head -->" "$T/posted")" = 2 ] || fail "expected each verdict to name the commit it was given for"
expect_output "adam: saved adam session as pr-7/"
expect_output "ryan: saved ryan session as pr-7/"
expect_no_call "claude"
expect_not_cut_short

scenario "verdicts: one passes and the other fails: both are posted, the job fails, and it is not marked cut short, so a fix round starts"
reviews; ended adam pass; ended ryan fail
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Bug:** `ryan.sh:3`: Found by ryan.'
expect_not_cut_short
expect_no_call "needs-human"

scenario "verdicts: both fail: each verdict holds its own findings"
reviews; ended adam fail; ended ryan fail
verdicts adam ryan
expect_status 1
expect_posted '1. **Design:** `adam.sh:3`: Found by adam.'
expect_posted '1. **Bug:** `ryan.sh:3`: Found by ryan.'
[ "$(grep -c 'Found by' "$T/posted")" = 2 ] || fail "expected each finding posted once"
expect_not_cut_short

scenario "verdicts: a review that ended with no verdict: a person is asked, the other verdict is posted, and no fix round starts"
reviews; ended adam pass; ended ryan api-error
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): review not finished.** Run the failed jobs again"
expect_call "gh pr edit 7 --add-label needs-human"
expect_cut_short

scenario "verdicts: one fails and the other ended with no verdict: the fail still starts a fix round"
reviews; ended adam fail; ended ryan api-error
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): FAIL**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_not_cut_short

scenario "verdicts: no transcript, as when the sessions' job failed before any session: neither review is finished, and no fix round starts"
reviews
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_posted "the agent left no result that could be read"
expect_cut_short

scenario "verdicts: a transcript cut short is saved as well as the last one, each under its own reviewer"
reviews; ended adam pass; ended ryan pass; ended ryan api-error cut-short
verdicts adam ryan
expect_status 0
[ "$(grep -c '^ryan: saved ryan session as pr-7/' <<<"$out")" = 2 ] || fail "expected Ryan's two transcripts saved"
[ "$(grep -c '^adam: saved adam session as pr-7/' <<<"$out")" = 1 ] || fail "expected Adam's one transcript saved, and not Ryan's under his name"

scenario "verdicts: only the reviewer named is given a verdict: the other's pass was carried"
reviews; ended adam pass; ended ryan pass
verdicts ryan
expect_status 0
expect_posted "**Ryan (correctness): PASS**"
[ "$(grep -c 'PASS' "$T/posted")" = 1 ] || fail "expected one verdict"
expect_no_output "saved adam session"

scenario "verdicts: GitHub refuses a verdict's comment: the job fails, not marked cut short, and the other verdict is still posted"
reviews; ended adam pass; ended ryan pass
stub gh '
  case "$*" in
    "pr comment 7 --body-file "*) ! grep -q Ryan "$5" || { echo "gh: failed" >&2; exit 1; }; cat "$5" >> "$T/posted" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
verdicts ryan adam
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_not_cut_short

scenario "verdicts: a transcript that cannot be saved fails no review"
reviews; ended adam pass; ended ryan pass
stub git 'exit 1'
verdicts adam ryan
expect_status 0
expect_output "could not save the adam session"

scenario "what the sessions' job keeps is what the other job posts and saves: a fail, and a pass given after a continuation"
reviews; says adam 1 fail; says ryan 1 api-error; says ryan 2 pass
sessions adam ryan
expect_status 0
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): FAIL**"
expect_posted '1. **Design:** `adam.sh:3`: Found by adam.'
expect_posted "**Ryan (correctness): PASS**"
[ "$(grep -c '^ryan: saved ryan session as pr-7/' <<<"$out")" = 2 ] || fail "expected the transcript cut short and the last one saved"
expect_not_cut_short

scenario "a review the sessions' job left with no verdict is one the other job does not finish: both fail, and no fix round starts"
reviews; says adam 1 pass; says ryan 1 long; says ryan 2 long; says ryan 3 long
sessions adam ryan
expect_status 1
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_posted "Its verdict was refused"
expect_cut_short

scenario "the folder to work in cannot be made: no review runs and no verdict is posted, and no fix round starts"
reviews; ended ryan fail
stub mktemp 'echo "mktemp: failed" >&2; exit 1'
sessions ryan
expect_status 2
expect_output "review.sh: could not make a folder to work in with mktemp, so no review ran and no verdict was posted."
expect_no_call "claude -p"
: > "$T/outputs"
verdicts ryan
expect_status 2
expect_no_call "gh pr comment"
expect_cut_short

scenario "no part or one it does not know, no reviewer or one it does not know, no commit, no arguments for the sessions, or a reviewer with no prompt or format: stops before anything"
reviews
run "$scripts/review.sh" 7 "$head" adam -- --model some-model
expect_status 2
expect_output "Usage: review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>"
expect_output "       review.sh verdicts <pr-number> <adam|ryan>..."
run "$scripts/review.sh" sessions 7 "$head" esme -- --model some-model
expect_status 2
run "$scripts/review.sh" sessions 7 "$head" adam ryan
expect_status 2
run "$scripts/review.sh" sessions seven "$head" adam -- --model some-model
expect_status 2
run "$scripts/review.sh" sessions 7 "$head" -- --model some-model
expect_status 2
run "$scripts/review.sh" sessions 7 origin/main adam -- --model some-model
expect_status 2
run "$scripts/review.sh" sessions 7 "$head" adam --
expect_status 2
run "$scripts/review.sh" verdicts 7
expect_status 2
run "$scripts/review.sh" verdicts 7 esme
expect_status 2
run "$scripts/review.sh" verdicts 7 adam -- --model some-model
expect_status 2
expect_output "Usage: review.sh"
unset RYAN_SCHEMA
sessions adam ryan
expect_status 2
expect_output "review.sh: ryan was given no prompt or no format, so it has nothing to review with."
expect_no_call "claude"
expect_no_call "gh"
expect_not_cut_short

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
permissions() { job "$1" | sed -n '/^    permissions:$/,/^    [a-z-]*:\( .*\)\{0,1\}$/p' | grep -E '^      [a-z-]+: ' | sed 's/ *#.*//' | tr -s ' ' | tr '\n' ';'; }
carried="\${{ steps.carry-adam.outputs.carried != 'true' && 'adam' || '' }} \${{ steps.carry-ryan.outputs.carried != 'true' && 'ryan' || '' }}"

# A change to either side must fail here: the workflow cannot run before it merges.
scenario "ci.yml runs the sessions once, in a checkout of the base, with the reviewers whose pass does not stand, their prompts and formats"
step=$(job review | sed -n '/^        id: reviews$/,/^      - name:/p')
grep -qF "factory/scripts/review.sh sessions \"\$PR\" \"\$HEAD_SHA\" $carried -- \\" <<<"$step" \
  || fail "expected the step to name each reviewer only when its pass does not stand"
[ "$(job review | grep -c 'factory/scripts/review.sh')" = 1 ] || fail "expected one step to run both reviews"
for name in ADAM RYAN; do
  grep -q "^          ${name}_SCHEMA: '{.*}'$" <<<"$step" || fail "expected the step to give ${name}_SCHEMA"
  grep -qxF "          ${name}_PROMPT: |" <<<"$step" || fail "expected the step to give ${name}_PROMPT"
done
grep -qxF '          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' <<<"$step" || fail "expected the step to sign claude in"
grep -qxF '          HEAD_SHA: ${{ github.event.pull_request.head.sha }}' <<<"$step" || fail "expected the step to be given the commit under review"
grep -qF -- '--settings "$AGENT_SETTINGS"' <<<"$step" || fail "expected each session to run with the settings every agent has"
[ "$(job review | grep -A3 -F 'uses: actions/checkout@v4' | grep -F 'ref:')" = '          ref: ${{ github.base_ref }}' ] \
  || fail "expected the job to check out the base: a session starts in its checkout"
job review | grep -qxF '        run: git fetch --quiet origin "$HEAD_SHA"' || fail "expected the job to fetch the pull request's commit, which the base's checkout lacks"
[ "$(job review | grep -c 'carry-review.sh ".*" "$PR" "$HEAD_SHA" "origin/$BASE" check$')" = 2 ] \
  || fail "expected the job to ask whether each pass stands without posting it"
! job review | grep -q 'id-token' || fail "expected the review job to ask for no token it does not use"

scenario "ci.yml gives the sessions' job no token that writes, and nothing in it posts or saves"
[ "$(permissions review)" = " contents: read; pull-requests: read; issues: read;" ] || fail "expected the review job to hold only tokens that read, got: $(permissions review)"
! job review | grep -qE 'post-verdict|save-session|post-screenshots|usage-limit.sh wait|review.sh verdicts|gh pr comment' \
  || fail "expected nothing in the review job that writes to the repo"
job review | grep -qxF '      held: ${{ steps.reviews.outputs.held }}   # the Claude usage limit holds every agent, so no session started (decisions A231b)' \
  || fail "expected the job to pass on that the usage limit held it"

scenario "ci.yml posts the verdicts in a job that checks out the base, from the transcripts the sessions' job kept"
[ "$(job verdicts | grep -A3 -F 'uses: actions/checkout@v4' | grep -F 'ref:')" = '          ref: ${{ github.base_ref }}' ] \
  || fail "expected the job that posts to check out the base: it runs none of the pull request's files"
[ "$(job verdicts | grep -c 'uses: actions/checkout@v4')" = 1 ] || fail "expected one checkout in the job that posts"
[ "$(permissions verdicts)" = " contents: write; pull-requests: write; issues: write;" ] || fail "expected the job that posts to hold the tokens that write, got: $(permissions verdicts)"
job verdicts | grep -qxF "        run: factory/scripts/review.sh verdicts \"\$PR\" $carried" \
  || fail "expected the job to post the verdict of each reviewer whose pass it did not carry"
[ "$(job verdicts | grep -c 'carry-review.sh ".*" "$PR" "$HEAD_SHA" "origin/$BASE"$')" = 2 ] || fail "expected the job to carry each pass that stands, posting it"
kept=$(job review | grep -A8 -F 'uses: actions/upload-artifact@v4')
fetched=$(job verdicts | grep -B4 -A4 -F 'name: session-review-')
for side in "$kept" "$fetched"; do
  grep -qxF '          name: session-review-${{ github.run_id }}' <<<"$side" && grep -qxF '          path: ${{ runner.temp }}/reviews' <<<"$side" \
    || fail "expected the transcripts kept and fetched under one name, in the folder review.sh reads: $side"
done
grep -qxF '          overwrite: true' <<<"$kept" || fail "expected a review job run again to replace the transcripts it kept"
grep -qxF '        if: always()' <<<"$(job review | grep -B2 -F 'uses: actions/upload-artifact@v4')" || fail "expected the transcripts kept when a review failed its job"
grep -qxF '        continue-on-error: true' <<<"$fetched" || fail "expected no transcript to fail no step: review.sh then says the review was not finished"
job verdicts | grep -qxF "        if: needs.review.outputs.held == 'true'" || fail "expected the job to keep the run's place when the usage limit held the reviews"

scenario "ci.yml posts after a failed review job, and starts a fix round only for a verdict that failed"
job verdicts | grep -qxF "    if: \${{ !cancelled() && needs.review.result != 'skipped' }}" \
  || fail "expected the job that posts to run after a failed review job, and not after a skipped one"
job verdicts | grep -qF 'cut-short: ${{ steps.limit.outputs.held || steps.verdicts.outputs.cut-short }}' \
  || fail "expected the job to pass on that a review was held or cut short"
job start-fix | grep -qF "(needs.verdicts.result == 'failure' && needs.verdicts.outputs.cut-short != 'true')" \
  || fail "expected start-fix to start no round for reviews that were only cut short"
! job start-fix | grep -qF "needs.review.result" || fail "expected a failed review job to start no fix round of its own: it holds no verdict"
