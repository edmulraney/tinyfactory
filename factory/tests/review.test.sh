#!/usr/bin/env bash
# Tests for review.sh: both reviews as sessions side by side, given no GitHub token, and each verdict posted after.
. "$(dirname "$0")/helpers.sh"

# reviews: pull request #7, whose commit $head changes main's instructions, settings and a script, adds a server and a
# hook, and is not what is checked out: main is. A stand-in for claude prints $T/<reviewer>.<n> for that reviewer's nth
# session. $T/fail lists the gh calls, by their first words, that fail; $T/posted keeps what was posted. What a
# reviewer reads from GitHub is there already, as `review.sh context` leaves it.
reviews() {
  : > "$T/fail"
  : > "$T/outputs"
  : > "$T/posted"
  export GITHUB_OUTPUT="$T/outputs" RUNNER_TEMP="$T/runner" GH_TOKEN=token HEAD_SHA
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=900
  export ADAM_PROMPT="You are Adam. Review pull request #7." ADAM_SCHEMA='{"for":"adam"}'
  export RYAN_PROMPT="You are Ryan. Review pull request #7." RYAN_SCHEMA='{"for":"ryan"}'
  mkdir -p "$T/runner/github"
  echo "# Pull request #7: feat: a change" > "$T/runner/github/pull-request.md"
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
      "pr comment 7 --body-file "*) cat "$5" >> "$T/posted" ;;
      "pr comment 7 --body "*) printf "%s\n" "$5" >> "$T/posted" ;;
      "pr edit 7 --add-label needs-human") ;;
      "pr view 7 --json closingIssuesReferences "*) json "{\"closingIssuesReferences\":[$(cat "$T/closes" 2>/dev/null)]}" "$@" ;;
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
    echo "${GH_TOKEN:-}${GITHUB_TOKEN:-}" > "$T/$role.token"
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
  stub git 'case "$1" in rev-parse|worktree|config) exec "$real_git" "$@" ;; esac
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
# sessions: the step given no GitHub token; verdicts: the step after it, which is given one; review: both, as the job
# runs them, with what both printed and the exit of the second, which is the job's.
sessions() { run env -u GH_TOKEN "$scripts/review.sh" sessions 7 "$head" "$@" -- --model some-model --max-turns 40 --allowedTools "Read,Bash(git diff:*)"; }
verdicts() { run "$scripts/review.sh" verdicts 7 "$@"; }
review() {
  local said
  sessions "$@"; said=$out
  verdicts "$@"; out="$said"$'\n'"$out"
}
expect_posted() {
  [[ "$(cat "$T/posted")" == *"$1"* ]] || fail "expected a comment to hold: $1"$'\n'"posted: $(cat "$T/posted")"
}
expect_cut_short() { grep -qx 'cut-short=true' "$T/outputs" || fail "expected the job to be marked cut short, so that no fix round starts"; }
expect_not_cut_short() { ! grep -q cut-short "$T/outputs" || fail "expected the job not to be marked cut short: that would keep the fix round from starting"; }
expect_saved() {
  [ "$(grep -c "^$1: saved $1 session as pr-7/" <<<"$out")" = "$2" ] || fail "expected $2 of $1's transcripts saved, got: $out"
}
there="This directory is a checkout of the branch the pull request merges into. The pull request's files, as its commit"

scenario "both pass: each reviewer has a session with its own prompt and format, told where the pull request's files and what GitHub holds of it are; two verdicts are posted, each naming the commit, and both transcripts are saved"
reviews; says adam 1 pass; says ryan 1 pass
review adam ryan
expect_status 0
expect_call "claude -p You are Adam. Review pull request #7."
expect_call "$there $head has them, are in $T/runner/pull-request: read them there. \`git diff\` and \`git log\` know that commit from this directory."
expect_call "You have no \`gh\`. What it would print is in $T/runner/github: pull-request.md holds the pull request's title, description, comments and reviews, and ticket-<n>.md the text and comments of the ticket it closes, each without what an account with no write access to the repository wrote. For the pull request's diff, run \`git diff HEAD...$head\`. --model some-model --max-turns 40 --allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"adam\"} --output-format stream-json --verbose"
expect_call "claude -p You are Ryan. Review pull request #7."
expect_call "--allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"ryan\"} --output-format stream-json --verbose"
expect_calls 2 "claude -p"
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): PASS**"
[ "$(grep -c "<!-- factory:reviewed $head -->" "$T/posted")" = 2 ] || fail "expected each verdict to name the commit it was given for"
expect_saved adam 1
expect_saved ryan 1
expect_not_cut_short
for reviewer in adam ryan; do
  [ "$(jq -r '"\(type) \(length) \(.[0].subtype) \(.[-1].session_id)"' "$T/runner/reviews/$reviewer.json")" = "array 2 init $reviewer-session" ] \
    || fail "expected $reviewer's transcript kept as an array of its two messages"
done

scenario "the sessions' step posts and saves nothing, and no session is given a GitHub token"
reviews; says adam 1 fail; says ryan 1 api-error; says ryan 2 pass
sessions adam ryan
expect_status 0
expect_calls 3 "claude -p"
expect_no_call "gh "
expect_no_call "git commit"
expect_no_call "git push"
[ ! -s "$T/posted" ] || fail "expected nothing posted by the step that runs the sessions"
for reviewer in adam ryan; do
  [ -z "$(cat "$T/$reviewer.token")" ] || fail "expected $reviewer's session to be given no GitHub token"
done

scenario "given GH_TOKEN or GITHUB_TOKEN: no session starts, and the step fails saying which is set"
reviews; says adam 1 pass; says ryan 1 pass
for name in GH_TOKEN GITHUB_TOKEN; do
  run env -u GH_TOKEN "$name=token" "$scripts/review.sh" sessions 7 "$head" adam ryan -- --model some-model
  expect_status 1
  expect_output "review.sh: $name is set, so a session could read a GitHub token and send it out. No session started."
done
expect_no_call "claude"
expect_no_call "gh "
verdicts adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_cut_short

scenario "the checkout's git config holds a token, as actions/checkout leaves it: no session starts, and the step fails saying so"
reviews; says ryan 1 pass
"$real_git" config http.https://github.com/.extraheader "AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46dG9rZW4="
sessions ryan
expect_status 1
expect_output "review.sh: the checkout's git config holds a token, so a session could read a GitHub token and send it out. No session started."
expect_no_call "claude"
"$real_git" config --unset http.https://github.com/.extraheader
sessions ryan
expect_status 0
expect_calls 1 "claude -p"

# context: `review.sh context 7` beside a stand-in for thread.sh, which prints one line for the number it is asked for,
# and fails for the number $T/unread holds. $T/closes holds the tickets the pull request closes, as GitHub lists them.
context() {
  rm -rf "$T/scripts"
  cp -R "$scripts" "$T/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "thread.sh %s\n" "$*" >> "$T/calls"' \
    'if [ "$1" = "$(cat "$T/unread" 2>/dev/null)" ]; then echo "Could not read #$1 from GitHub, so none of its text is printed." >&2; exit 1; fi' \
    'echo "The text of #$1, with nothing a stranger wrote."' > "$T/scripts/thread.sh"
  run "$T/scripts/review.sh" context 7
}

scenario "context: the pull request and the ticket it closes are written outside the checkout, each as thread.sh prints it"
reviews; rm -rf "$T/runner/github"
echo '{"number":12}' > "$T/closes"
context
expect_status 0
[ "$(cat "$T/runner/github/pull-request.md")" = "The text of #7, with nothing a stranger wrote." ] \
  || fail "expected the pull request as thread.sh prints it, got: $(cat "$T/runner/github/pull-request.md")"
[ "$(cat "$T/runner/github/ticket-12.md")" = "The text of #12, with nothing a stranger wrote." ] \
  || fail "expected the ticket as thread.sh prints it, got: $(cat "$T/runner/github/ticket-12.md")"
case "$T/runner/github/" in "$T/work/"*) fail "expected what GitHub holds outside the checkout" ;; esac
expect_no_call "gh issue view"
expect_no_call "--json title"
expect_no_call "claude"

scenario "context: a pull request that closes no ticket has only its own file"
reviews; rm -rf "$T/runner/github"
context
expect_status 0
[ "$(ls "$T/runner/github")" = pull-request.md ] || fail "expected only pull-request.md, got: $(ls "$T/runner/github")"
expect_no_call "thread.sh 12"

scenario "context: GitHub does not answer for the pull request or for its ticket: it fails and leaves no folder, so no session starts and each review is said to be unfinished"
reviews
echo '{"number":12}' > "$T/closes"
echo 12 > "$T/unread"
context
expect_status 1
expect_output "review.sh: ticket #12 could not be read from GitHub, so a reviewer has nothing to read it from, and no review runs."
[ ! -e "$T/runner/github" ] || fail "expected no folder left when the ticket could not be read"
echo 7 > "$T/unread"
context
expect_status 1
expect_output "review.sh: pull request #7 could not be read from GitHub, so a reviewer has nothing to read it from, and no review runs."
[ ! -e "$T/runner/github" ] || fail "expected no folder left when the pull request could not be read"
rm "$T/unread"
echo "pr view" > "$T/fail"
context
expect_status 1
expect_output "review.sh: pull request #7 could not be read from GitHub, so a reviewer has nothing to read it from, and no review runs."
[ ! -e "$T/runner/github" ] || fail "expected no folder left when the tickets the pull request closes could not be listed"
: > "$T/fail"
review ryan
expect_status 1
expect_output "review.sh: $T/runner/github holds no pull-request.md, which \`review.sh context\` writes, so a reviewer could not read the pull request, and no review ran."
expect_no_call "claude"
expect_posted "**Ryan (correctness): review not finished.**"
expect_cut_short

scenario "the two sessions run at the same time: each ends only once the other has started"
reviews; says adam 1 pass; says ryan 1 pass
: > "$T/together"
review adam ryan
expect_status 0

scenario "a session starts in main's files, with no file of the pull request in its directory, and the pull request's are beside it"
reviews; says ryan 1 pass
review ryan
expect_status 0
[ "$(sed -n 1,5p "$T/ryan.here")" = "$T/work"$'\n'"main's settings"$'\n'"main's skill"$'\n'"main's rules"$'\n'"main's script" ] \
  || fail "expected the session to start in the checkout of main and read main's settings, skill, rules and script there, got: $(cat "$T/ryan.here")"
! sed 1,5d "$T/ryan.here" | grep -qxE '\.mcp\.json|\.husky|new\.md|pull-request' || fail "expected nothing of the pull request in the session's directory, found: $(sed 1,5d "$T/ryan.here" | tr '\n' ' ')"
[ "$(cat "$T/ryan.there")" = "the pull request's rules"$'\n'"the pull request's script"$'\n''{"mcpServers":{}}' ] \
  || fail "expected the pull request's files outside the session's directory, got: $(cat "$T/ryan.there")"
case "$T/runner/pull-request/" in "$T/work/"*) fail "expected the pull request's files outside the checkout" ;; esac

scenario "a session the model's API cut short is continued by its id, after the wait; the transcript cut short and the last one are saved, and its pass is posted"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 2 pass
review adam ryan
expect_status 0
expect_call "sleep 120"
expect_call "--resume ryan-session --model some-model --max-turns 40 --allowedTools Read,Bash(git diff:*) --json-schema {\"for\":\"ryan\"} --output-format stream-json --verbose"
expect_call "claude -p Your session ended before your work was handed over: the model's API was overloaded (error 529). You have not given your result."
expect_calls 3 "claude -p"
expect_no_call "--resume adam-session"
expect_posted "**Ryan (correctness): PASS**"
expect_saved ryan 2
expect_saved adam 1
[ "$(jq -r '.[-1].terminal_reason' "$T/runner/reviews/cut-short-sessions/"*-ryan.json)" = api_error ] || fail "expected a copy of the transcript cut short kept under reviews/cut-short-sessions"
[ "$(jq -r '.[-1].terminal_reason' "$T/runner/reviews/ryan.json")" = completed ] || fail "expected the last transcript to be the one that gave the verdict"

scenario "a session cut short three times is continued twice and no more: a person is asked, the other verdict is posted, and no fix round starts"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 2 api-error; says ryan 3 api-error; says ryan 4 pass
review adam ryan
expect_status 1
expect_calls 2 "--resume ryan-session"
expect_call "sleep 300"
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): review not finished.** Run the failed jobs again"
expect_call "gh pr edit 7 --add-label needs-human"
expect_cut_short

scenario "a verdict still over a limit after two continuations is refused, not posted, and no fix round starts"
reviews; says adam 1 pass; says ryan 1 long; says ryan 2 long; says ryan 3 long
review adam ryan
expect_status 1
expect_calls 2 "--resume ryan-session"
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_posted "Its verdict was refused"
expect_cut_short

scenario "one passes and the other fails: both are posted, the job fails, and it is not marked cut short, so a fix round starts"
reviews; says adam 1 pass; says ryan 1 fail
review adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Bug:** `ryan.sh:3`: Found by ryan.'
expect_not_cut_short
expect_no_call "needs-human"

scenario "both fail: each verdict holds its own findings"
reviews; says adam 1 fail; says ryan 1 fail
review adam ryan
expect_status 1
expect_posted '1. **Design:** `adam.sh:3`: Found by adam.'
expect_posted '1. **Bug:** `ryan.sh:3`: Found by ryan.'
[ "$(grep -c 'Found by' "$T/posted")" = 2 ] || fail "expected each finding posted once"
expect_not_cut_short

scenario "one fails and the other ended with no verdict: the fail still starts a fix round"
reviews; says adam 1 fail; says ryan 1 api-error; says ryan 2 api-error; says ryan 3 api-error
review adam ryan
expect_status 1
expect_posted "**Adam (architecture and taste): FAIL**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_not_cut_short

scenario "a continued session that prints nothing leaves the transcript before it, which is looked at again"
reviews; says adam 1 pass; says ryan 1 api-error; says ryan 3 pass
review adam ryan
expect_status 0
expect_calls 2 "--resume ryan-session"
expect_posted "**Ryan (correctness): PASS**"

scenario "claude fails and prints nothing, as when it was never installed: neither review is finished, and no fix round starts"
reviews
: > "$T/adam.1.fails"; : > "$T/ryan.1.fails"
review adam ryan
expect_status 1
expect_calls 2 "claude -p"
[ ! -e "$T/runner/reviews/adam.json" ] || fail "expected no transcript kept for a session that printed nothing"
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_posted "the agent left no result that could be read"
expect_cut_short

scenario "claude fails after printing its verdict: the verdict is in what it printed"
reviews; says adam 1 pass; says ryan 1 pass
: > "$T/ryan.1.fails"
review adam ryan
expect_status 0
expect_posted "**Ryan (correctness): PASS**"

scenario "only the reviewer named reviews and is given a verdict: the other's pass was carried"
reviews; says adam 1 pass; says ryan 1 pass
review ryan
expect_status 0
expect_calls 1 "claude -p"
expect_no_call "You are Adam."
expect_posted "**Ryan (correctness): PASS**"
[ "$(grep -c 'PASS' "$T/posted")" = 1 ] || fail "expected one verdict"
expect_no_output "saved adam session"

# This git also answers what stale-documents.sh asks, which the stand-in of `reviews` leaves empty.
reads_history='rev-parse|worktree|config|merge-base|diff|ls-tree|grep|show|cat-file'
scenario "each reviewer is told where the lines of documents that name what the pull request changes are, and the file holds them"
reviews; says ryan 1 pass
"$real_git" checkout --quiet feat/7-change
printf '%s\n' "Run \`script.sh\` first." "Then run another-script.sh." > guide.md
"$real_git" add . && "$real_git" commit --quiet -m "a guide"
HEAD_SHA=$("$real_git" rev-parse HEAD); head=$HEAD_SHA
"$real_git" checkout --quiet main
stub git 'case "$1" in '"$reads_history"') exec "$real_git" "$@" ;; esac
  case "$*" in *"diff --cached --quiet") exit 1 ;; esac; exit 0'
review ryan
expect_status 0
expect_call "$T/runner/stale-documents.txt holds each line of a document that names a file, label or command the pull request changes or removes, as that commit has the line. It is empty when no line does."
[ "$(cat "$T/runner/stale-documents.txt")" = "guide.md:1: Run \`script.sh\` first." ] \
  || fail "expected the one line that names the changed script, got: $(cat "$T/runner/stale-documents.txt")"
expect_posted "**Ryan (correctness): PASS**"

scenario "the lines of documents cannot be listed: the file says why, the step says it too, and the review still runs"
reviews; says ryan 1 pass
stub git 'case "$1" in rev-parse|worktree|config) exec "$real_git" "$@" ;; merge-base) exit 1 ;; esac
  case "$*" in *"diff --cached --quiet") exit 1 ;; esac; exit 0'
review ryan
expect_status 0
why="stale-documents.sh: HEAD and $head share no commit in this checkout, so the documents that name what changed are not listed."
expect_output "$why"
[ "$(cat "$T/runner/stale-documents.txt")" = "$why" ] || fail "expected the file to say why it holds no list, got: $(cat "$T/runner/stale-documents.txt")"
expect_posted "**Ryan (correctness): PASS**"

scenario "the pull request's commit is not in the checkout: no session starts, each review is said to be unfinished, and no fix round starts"
reviews
head=0123456789012345678901234567890123456789
review adam ryan
expect_status 1
expect_output "review.sh: the pull request's commit $head is not in this checkout, so its files could not be put beside it, and no review ran."
expect_no_call "claude"
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_posted "**Ryan (correctness): review not finished.**"
expect_cut_short

scenario "the pull request's files cannot be put beside the checkout: no session starts in them, and the review is said to be unfinished"
reviews
stub git 'case "$1" in rev-parse) exec "$real_git" "$@" ;; worktree) echo "git: failed" >&2; exit 1 ;; esac; exit 0'
review ryan
expect_status 1
expect_output "review.sh: the files of the pull request's commit $head could not be put in $T/runner/pull-request, so no review ran."
expect_no_call "claude"
expect_posted "**Ryan (correctness): review not finished.**"
expect_cut_short

scenario "a second review in a checkout that outlived the first, whose folder of the pull request's files is gone, still runs"
reviews; says ryan 1 pass; says ryan 2 pass
review ryan
expect_status 0
rm -rf "$T/runner/pull-request"
: > "$T/posted"
review ryan
expect_status 0
expect_posted "**Ryan (correctness): PASS**"
[ "$(cat "$T/ryan.there")" = "the pull request's rules"$'\n'"the pull request's script"$'\n''{"mcpServers":{}}' ] \
  || fail "expected the second session to read the pull request's files, got: $(cat "$T/ryan.there")"

scenario "GitHub refuses a verdict's comment: the job fails, not marked cut short, and the other verdict is still posted"
reviews; says adam 1 pass; says ryan 1 pass
stub gh '
  case "$*" in
    "pr comment 7 --body-file "*) ! grep -q Ryan "$5" || { echo "gh: failed" >&2; exit 1; }; cat "$5" >> "$T/posted" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
review ryan adam
expect_status 1
expect_posted "**Adam (architecture and taste): PASS**"
expect_not_cut_short

scenario "a transcript that cannot be saved fails no review"
reviews; says adam 1 pass; says ryan 1 pass
sessions adam ryan
stub git 'exit 1'
verdicts adam ryan
expect_status 0
expect_output "could not save the adam session"
expect_posted "**Adam (architecture and taste): PASS**"

scenario "the folder to work in cannot be made: no review runs and no verdict is posted, and no fix round starts"
reviews; says ryan 1 fail
stub mktemp 'echo "mktemp: failed" >&2; exit 1'
review ryan
expect_status 2
expect_output "review.sh: could not make a folder to work in with mktemp, so no review ran and no verdict was posted."
expect_no_call "claude -p"
expect_no_call "gh pr comment"
expect_cut_short

scenario "no part or one it does not know, no reviewer or one it does not know, no commit, no arguments for the sessions, or a reviewer with no prompt or format: stops before anything"
reviews
run "$scripts/review.sh" 7 "$head" adam -- --model some-model
expect_status 2
expect_output "Usage: review.sh context <pr-number>"
expect_output "       review.sh sessions <pr-number> <head-sha> <adam|ryan>... -- <arguments for each claude session>"
expect_output "       review.sh verdicts <pr-number> <adam|ryan>..."
for wrong in "sessions 7 $head esme -- --model some-model" "sessions 7 $head adam ryan" "sessions seven $head adam -- --model some-model" \
  "sessions 7 $head -- --model some-model" "sessions 7 origin/main adam -- --model some-model" "sessions 7 $head adam --" \
  "verdicts 7" "verdicts 7 esme" "verdicts 7 adam -- --model some-model" "context" "context seven" "context 7 adam"; do
  # shellcheck disable=SC2086
  run env -u GH_TOKEN "$scripts/review.sh" $wrong
  expect_status 2
  expect_output "Usage: review.sh"
done
unset RYAN_SCHEMA
sessions adam ryan
expect_status 2
expect_output "review.sh: ryan was given no prompt or no format, so it has nothing to review with."
expect_no_call "claude"
expect_no_call "gh"
expect_not_cut_short

scenario "given a token as an earlier ci.yml gave it, in a run whose ci.yml main no longer holds: both parts say the run is behind and fail, so that a fresh run reviews"
reviews
stub git 'exec "$real_git" "$@"'
mkdir -p .github/workflows; echo "name: ci" > .github/workflows/ci.yml
git add . && git commit --quiet -m "the workflow"
ran=$(git rev-parse HEAD)
git clone --quiet --bare . "$T/origin"; git -C "$T/origin" config uploadpack.allowAnySHA1InWant true
git remote add origin "$T/origin"
echo "name: ci, changed" > .github/workflows/ci.yml; git commit --quiet -am "ci: install ci.yml"; git push --quiet origin main
behind=(env GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/7/merge GITHUB_WORKFLOW_SHA="$ran" GITHUB_BASE_REF=main)
run "${behind[@]}" "$scripts/review.sh" sessions 7 "$head" adam ryan -- --model some-model
expect_status 1
expect_output "not reviewed. .github/workflows/ci.yml on main has changed since this run began: this run uses the workflow from before the install."
expect_no_output "GH_TOKEN is set"
expect_no_call "claude"
run "${behind[@]}" "$scripts/review.sh" verdicts 7 adam ryan
expect_status 1
expect_output "adam: Adam (architecture and taste): not reviewed. .github/workflows/ci.yml on main has changed since this run began: this run uses the workflow from before the install."
expect_no_call "needs-human"
expect_not_cut_short

scenario "given a token as an earlier ci.yml gave it, after the change merged and before its ci.yml is installed: says the run is behind, as it is about to be"
reviews
stub git 'exec "$real_git" "$@"'
mkdir -p .github/workflows factory/workflows; echo "name: ci" > .github/workflows/ci.yml; echo "name: ci, changed" > factory/workflows/ci.yml
git add . && git commit --quiet -m "the change merged"
ran=$(git rev-parse HEAD)
git clone --quiet --bare . "$T/origin"; git -C "$T/origin" config uploadpack.allowAnySHA1InWant true
git remote add origin "$T/origin"
behind=(env GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/7/merge GITHUB_WORKFLOW_SHA="$ran" GITHUB_BASE_REF=main)
run "${behind[@]}" "$scripts/review.sh" sessions 7 "$head" adam ryan -- --model some-model
expect_status 1
expect_output "not reviewed. .github/workflows/ci.yml on main is about to be installed from factory/workflows/ci.yml: this run uses the workflow from before the install. Merge main into the branch and push"
cp factory/workflows/ci.yml .github/workflows/ci.yml; git commit --quiet -am "ci: install ci.yml"; git push --quiet origin main
run "${behind[@]}" GITHUB_WORKFLOW_SHA="$(git rev-parse HEAD)" "$scripts/review.sh" sessions 7 "$head" adam ryan -- --model some-model
expect_status 1
expect_output "review.sh: GH_TOKEN is set, so a session could read a GitHub token and send it out. No session started."
expect_no_call "claude"

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
permissions() { job "$1" | sed -n '/^    permissions:$/,/^    [a-z-]*:\( .*\)\{0,1\}$/p' | grep -E '^      [a-z-]+: ' | sed 's/ *#.*//' | tr -s ' ' | tr '\n' ';'; }
carried="\${{ steps.carry-adam.outputs.carried != 'true' && 'adam' || '' }} \${{ steps.carry-ryan.outputs.carried != 'true' && 'ryan' || '' }}"
step_named() { job review | awk -v name="      - name: $1" '$0 == name { on = 1; print; next } on && /^      (- |#)/ { exit } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$1" | sed -e 1d -e 's/^          //'; }
unless_both_carried="        if: steps.carry-adam.outputs.carried != 'true' || steps.carry-ryan.outputs.carried != 'true'"

# A change to either side must fail here: the workflow cannot run before it merges.
scenario "ci.yml runs the sessions once, in a checkout of the base, with the reviewers whose pass does not stand, their prompts and formats"
step=$(job review | sed -n '/^        id: reviews$/,/^      - name:/p')
grep -qF "factory/scripts/review.sh sessions \"\$PR\" \"\$HEAD_SHA\" $carried -- \\" <<<"$step" \
  || fail "expected the step to name each reviewer only when its pass does not stand"
[ "$(job review | grep -c 'factory/scripts/review.sh sessions')" = 1 ] || fail "expected one step to run both reviews"
for name in ADAM RYAN; do
  grep -q "^          ${name}_SCHEMA: '{.*}'$" <<<"$step" || fail "expected the step to give ${name}_SCHEMA"
  grep -qxF "          ${name}_PROMPT: |" <<<"$step" || fail "expected the step to give ${name}_PROMPT"
done
grep -qxF '          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}' <<<"$step" || fail "expected the step to sign claude in"
grep -qF -- '--settings "$AGENT_SETTINGS"' <<<"$step" || fail "expected each session to run with the settings every agent has"
[ "$(job review | grep -A3 -F 'uses: actions/checkout@v4' | grep -F 'ref:')" = '          ref: ${{ github.base_ref }}' ] \
  || fail "expected the job to check out the base: a session starts in its checkout"
[ "$(job review | grep -c 'uses: actions/checkout@v4')" = 1 ] || fail "expected one checkout in the review job"
! job review | grep -q 'id-token' || fail "expected the review job to ask for no token it does not use"

scenario "ci.yml puts no GitHub token within a session's reach: none in the checkout, in the sessions' step, or for the whole job or workflow"
[ "$(job review | grep -A4 -F 'uses: actions/checkout@v4' | grep -F 'persist-credentials:' | sed 's/ *#.*//')" = '          persist-credentials: false' ] \
  || fail "expected the checkout to leave no token in .git/config"
! grep -qE 'github\.token|secrets\.GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN' <<<"$step" || fail "expected the sessions' step to be given no GitHub token, got: $(grep -E 'github\.token|GITHUB_TOKEN|GH_TOKEN' <<<"$step")"
! grep -qE 'Bash\(gh[ :]' <<<"$step" || fail "expected no \`gh\` in a reviewer's tools: it has no token to ask GitHub with"
! job review | sed -n '/^    steps:$/q;p' | grep -qE 'github\.token|secrets\.' || fail "expected the review job to give no token to every step"
! sed -n '/^jobs:$/q;p' "$root/factory/workflows/ci.yml" | grep -qE 'github\.token|secrets\.' || fail "expected the workflow to give no token to every job"
fetch=$(step_named "Fetch the pull request's commit, which a checkout of the base lacks")
grep -qxF '          GH_TOKEN: ${{ github.token }}' <<<"$fetch" || fail "expected the step that fetches the commit to be given the token"
# shellcheck disable=SC2016
grep -qxF "        run: git -c credential.helper= -c credential.helper='!f() { echo username=x-access-token; echo \"password=\$GH_TOKEN\"; }; f' fetch --quiet origin \"\$HEAD_SHA\"" <<<"$fetch" \
  || fail "expected git to be given the token for the fetch alone, written nowhere"
context=$(step_named "Write what a reviewer reads from GitHub beside the checkout")
grep -qxF '        run: factory/scripts/review.sh context "$PR"' <<<"$context" || fail "expected a step to write what a reviewer reads from GitHub"
grep -qxF '          GH_TOKEN: ${{ github.token }}' <<<"$context" || fail "expected that step to be given the token that reads"
grep -qxF "$unless_both_carried" <<<"$context" || fail "expected nothing written when both passes were carried: no session starts then"
[ "$(job review | grep -n -F 'review.sh context' | cut -d: -f1)" -lt "$(job review | grep -n -xF '        id: reviews' | cut -d: -f1)" ] \
  || fail "expected it written before the sessions"

scenario "ci.yml posts from the review job, in a step after the sessions that also runs when theirs failed: it holds the tokens that write, carries each pass that stands, and no job after it posts"
[ "$(permissions review)" = " contents: write; pull-requests: write; issues: write; actions: read;" ] || fail "expected the review job to hold the tokens that write, and to read when it started, got: $(permissions review)"
[ "$(job review | grep -c 'carry-review.sh ".*" "$PR" "$HEAD_SHA" "origin/$BASE"$')" = 2 ] || fail "expected the job to carry each pass that stands, posting it"
[ "$(job review | grep -c 'post-screenshots.sh')" = 1 ] || fail "expected the job to publish the screenshots"
[ -z "$(job verdicts)" ] || fail "expected no job after the reviews that is billed a minute to post what they found"
posts=$(step_named "Post each verdict and save each transcript")
grep -qxF "        run: factory/scripts/review.sh verdicts \"\$PR\" $carried" <<<"$posts" || fail "expected the step to give a verdict to each reviewer whose pass does not stand"
grep -qxF '        id: verdicts' <<<"$posts" || fail "expected the step to be the one the job's cut-short output reads"
grep -qxF "        if: \${{ !cancelled() && steps.reviews.outcome != 'skipped' }}" <<<"$posts" \
  || fail "expected the verdicts posted after a sessions' step that failed, and not when it never ran or the job was cancelled"
grep -qxF '          GH_TOKEN: ${{ github.token }}' <<<"$posts" || fail "expected the step to be given the token that posts each verdict"
grep -qxF '          HEAD_SHA: ${{ github.event.pull_request.head.sha }}' <<<"$posts" || fail "expected the step to be given the commit under review, which each verdict names"
[ "$(job review | grep -n -xF '        id: reviews' | cut -d: -f1)" -lt "$(job review | grep -n -xF '        id: verdicts' | cut -d: -f1)" ] \
  || fail "expected the verdicts posted after the sessions"

scenario "ci.yml starts no session while the usage limit holds every agent, and keeps the run's place"
limit=$(job review | grep -B2 -A4 -xF '        id: limit')
grep -qxF '        run: factory/scripts/usage-limit.sh wait "$PR" "the review" failed' <<<"$limit" || fail "expected the job to wait for the usage limit, failing so that it is run again"
grep -qxF "$unless_both_carried" <<<"$limit" || fail "expected no wait when both passes were carried: no session starts then"
[ "$(job review | grep -n -xF '        id: limit' | cut -d: -f1)" -lt "$(job review | grep -n -xF '        id: reviews' | cut -d: -f1)" ] \
  || fail "expected the wait before the sessions"

scenario "ci.yml asks for a person when the wait for the usage limit failed and did not keep the run's place"
asks=$(job review | awk -v name="      - name: Ask for a person when the reviews did not start and nothing starts them again" '$0 == name { on = 1; print; next } on && /^      (- |#)/ { exit } on')
grep -qxF "        if: failure() && steps.limit.outcome == 'failure' && steps.limit.outputs.kept != 'true'" <<<"$asks" \
  || fail "expected a person to be asked only when the wait failed with the run's place not kept"
reviews
# As GitHub runs a step: the first command that fails stops it.
run env PR=7 bash -eo pipefail -c "$(sed -n '/^        run: |$/,$p' <<<"$asks" | sed -e 1d -e 's/^          //')"
expect_status 0
expect_posted "**Review not finished.** Run the failed job again in https://github.com/owner/repo/actions/runs/900: each reviewer whose verdict is not on this pull request then reviews it."
expect_posted "so no review started, no fix round starts, and this pull request does not merge until it has been reviewed."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "ci.yml starts a fix round for a review that failed the pull request, and none for reviews only held or cut short"
job review | grep -qF 'cut-short: ${{ steps.limit.outputs.held || steps.verdicts.outputs.cut-short }}' \
  || fail "expected the job to pass on that a review was held or cut short"
job start-fix | grep -qF "(needs.review.result == 'failure' && needs.review.outputs.cut-short != 'true')" \
  || fail "expected start-fix to start a round for a failed review, and none for reviews that were only cut short"

scenario "ci.yml keeps a second copy of the transcripts, also when the review failed its job"
kept=$(job review | grep -B2 -A6 -F 'uses: actions/upload-artifact@v4')
grep -qxF '        if: always()' <<<"$kept" || fail "expected the transcripts kept when a review failed its job"
grep -qxF '          path: ${{ runner.temp }}/reviews' <<<"$kept" || fail "expected the folder review.sh keeps the transcripts in"
grep -qxF '          name: session-review-${{ github.run_id }}-${{ github.run_attempt }}' <<<"$kept" || fail "expected a name of its own for each attempt, so that a job run again keeps both"

scenario "ci.yml asks for a person when the review job was stopped at its time limit, and not when a person stopped it"
told=$(step_named "Tell whether this job stopped at its time limit")
grep -qx '        if: cancelled()' <<<"$told" || fail "expected the step to run only when the job was cancelled"
limit=$(sed -n 's/^          LIMIT_MINUTES: \([0-9]*\) .*/\1/p' <<<"$told")
job review | grep -qx "    timeout-minutes: $limit" || fail "expected the step's limit to be the job's timeout-minutes"
[ "$(commands "$told")" = "$(awk '/name: Tell whether this job stopped at its time limit/ { on = 1 } on && /^        run: \|$/ { run = 1; next } run && /^      (- |#)/ { exit } run' "$root/factory/workflows/fix.yml" | sed 's/^          //')" ] \
  || fail "expected the step to tell it as fix.yml's does"
asks=$(step_named "Ask for a person when the reviews were stopped at the time limit")
grep -qxF "        if: cancelled() && steps.time-limit.outputs.reached == 'true'" <<<"$asks" || fail "expected a person to be asked only for a job that ran its whole limit"
grep -qx '        id: time-limit' <<<"$told" || fail "expected the step to be the one that condition reads"
reviews
run env PR=7 bash -eo pipefail -c "$(commands "$asks")"
expect_status 0
expect_posted "**Review not finished.** Run the cancelled job again in https://github.com/owner/repo/actions/runs/900: each reviewer whose verdict is not on this pull request then reviews it."
expect_posted "The review job was stopped at its time limit, so a verdict was not posted, no fix round starts, and this pull request does not merge until it has been reviewed."
expect_call "gh pr edit 7 --add-label needs-human"
echo "pr comment" > "$T/fail"; : > "$T/calls"
run env PR=7 bash -eo pipefail -c "$(commands "$asks")"
expect_failure
expect_no_call "needs-human"
