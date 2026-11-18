#!/usr/bin/env bash
# Tests for benchmark.sh, on a repo of its own, an origin that holds its pull requests, and a stand-in for the model.
. "$(dirname "$0")/helpers.sh"

# A repo whose origin holds `main` and pull request #7, one commit ahead of it, and a ci.yml with each reviewer's job.
# The stand-in for claude answers Adam from $T/adam and Ryan from $T/ryan, and notes the commit it was run in,
# the commits it can reach and the refs it holds.
repo() {
  git init -q -b main .
  mkdir -p factory/workflows factory/benchmark
  cat > factory/workflows/ci.yml <<'CI'
# Checks.
jobs:
  checks:
    env:
      REVIEW_SCHEMA: '{"for":"nobody"}'
  adam:
    env:
      # Why.
      REVIEW_SCHEMA: '{"kinds":["design"]}'
    steps:
      - with:
          prompt: |
            You are Adam. Read .claude/skills/review-architecture/SKILL.md and follow it to review pull request #${{ github.event.pull_request.number }} in this repository.

            ${{ steps.scope.outputs.brief }}
          claude_args: |
            --model claude-fable-5-2 --effort medium --max-turns 40
            --allowedTools "Read,Glob,Bash(gh pr view:*),Bash(gh issue view:*),Bash(git diff:*),Bash(git log:*)"
      - with:
          prompt: ${{ steps.cut1.outputs.prompt }}
          claude_args: |
            --max-turns 5
            --allowedTools "Read"
  ryan:
    env:
      REVIEW_SCHEMA: '{"kinds":["bug"]}'
    steps:
      - with:
          prompt: |
            You are Ryan. Read .claude/skills/review-code/SKILL.md and follow it to review pull request #${{ github.event.pull_request.number }} in this repository.
          claude_args: |
            --model claude-fable-5-2 --effort medium --max-turns 30
            --allowedTools "Read,Grep,Bash(gh pr diff:*),Bash(git diff:*)"
CI
  git add . && git commit -q -m "main"
  base=$(git rev-parse HEAD)
  git init -q --bare "$T/origin"
  git remote add origin "$T/origin"
  git push -q origin main
  pull_request 7
  git fetch -q origin
  a_case 7 '{"problem": "The query has no time limit", "files": ["src/health.ts"], "pattern": "time limit|hangs"}'
  answer adam 1.00 60000
  answer ryan 0.50 80000
  stub claude '
    git rev-parse HEAD >> "$T/heads"
    git log --all --format=%s >> "$T/reachable"
    git for-each-ref >> "$T/refs"
    case "$*" in *"You are Adam."*) cat "$T/adam" ;; *"You are Ryan."*) cat "$T/ryan" ;; *) exit 1 ;; esac'
}
# pull_request <number>: a commit only origin's refs/pull/<number>/head holds; sets $commit.
pull_request() {
  git checkout -q --detach main
  echo "$1" > change.txt
  git add change.txt && git commit -q -m "pull request $1"
  commit=$(git rev-parse HEAD)
  git push -q origin "HEAD:refs/pull/$1/head"
  git checkout -q main
}
# a_case <pull request> <problem>...: its case, at $commit.
a_case() {
  local pr="$1"
  shift
  printf '%s\n' "$@" | jq -s --arg commit "$commit" \
    '{commit: $commit, ticket: {title: "Connect the database", body: "The health check reports the database."}, problems: .}' \
    > "factory/benchmark/$pr.json"
}
# answer <adam or ryan> <cost> <milliseconds> [finding]...: what that reviewer's session prints.
answer() {
  local who="$1" cost="$2" ms="$3"
  shift 3
  printf '%s\n' "$@" | jq -sc --argjson cost "$cost" --argjson ms "$ms" \
    '{is_error: false, total_cost_usd: $cost, duration_ms: $ms, num_turns: 9, structured_output: {findings: ., assumptions: []}}' > "$T/$who"
}
finding() {  # finding <file> <problem> [fix]
  jq -nc --arg file "$1" --arg problem "$2" --arg fix "${3:-Change it.}" '{file: $file, line: 9, kind: "bug", problem: $problem, fix: $fix}'
}
benchmark() { run "$scripts/benchmark.sh" "${1-claude-fable-5-2}" "${2-medium}"; }
# Nothing the script made is left: its checkouts are in the temporary folder.
expect_nothing_left() {
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary folder"
}

scenario "found: a finding names the problem's file and matches the case's pattern"
repo
answer ryan 0.50 80000 "$(finding src/health.ts "The query has no time limit, so the check never ends.")"
benchmark
expect_status 0
expect_output "| Pull request | Known problem | claude-fable-5-2, effort medium |"
expect_output "| #7 | The query has no time limit | found |"
expect_output "1 of 1 known problems found."
expect_nothing_left

scenario "missed: the finding matches the pattern and names another file"
repo
answer ryan 0.50 80000 "$(finding src/route.ts "The query has no time limit, so the check never ends.")"
benchmark
expect_status 0
expect_output "| #7 | The query has no time limit | missed |"
expect_output "0 of 1 known problems found."

scenario "missed: the finding names the file and does not match the pattern"
repo
answer ryan 0.50 80000 "$(finding src/health.ts "The query is not parameterised.")"
benchmark
expect_status 0
expect_output "| #7 | The query has no time limit | missed |"

scenario "missed: no reviewer has a finding"
repo
benchmark
expect_status 0
expect_output "| #7 | The query has no time limit | missed |"

scenario "found: by Adam alone, in the fix's words over two lines, in capitals, with ./ before the file"
repo
a_case 7 '{"problem": "The query has no time limit", "files": ["src/health.ts"], "pattern": "time limit|query.*hangs"}'
answer adam 1.00 60000 "$(finding ./src/health.ts "The database may be slow." "Stop a query
that HANGS.")"
benchmark
expect_status 0
expect_output "| #7 | The query has no time limit | found |"

scenario "found: in the second of a problem's files"
repo
a_case 7 '{"problem": "A heading stops the round", "files": ["collect.sh", "needs.sh"], "pattern": "heading"}'
answer adam 1.00 60000 "$(finding needs.sh "The new heading makes it answer false.")"
benchmark
expect_output "| #7 | A heading stops the round | found |"

scenario "two problems in one case and a second case: a row each, and each judged by its own pattern and its own case's findings"
repo
a_case 7 '{"problem": "An unused export", "files": ["src/out.ts"], "pattern": "export"}' \
  '{"problem": "A relative address throws", "files": ["src/out.ts"], "pattern": "relative"}'
pull_request 12
a_case 12 '{"problem": "A second unused export", "files": ["src/out.ts"], "pattern": "export"}'
answer ryan 0.50 80000 "$(finding src/out.ts "LIMIT is exported and nothing imports it.")"
stub claude '
  case "$*" in *"pull request #12 "*) cat "$T/adam" ;; *"You are Adam."*) cat "$T/adam" ;; *) cat "$T/ryan" ;; esac'
benchmark
expect_status 0
[ "$(grep -c '^| #' <<<"$out")" = 3 ] || fail "expected three rows"
expect_output "| #7 | An unused export | found |"
expect_output "| #7 | A relative address throws | missed |"
expect_output "| #12 | A second unused export | missed |"
expect_output "1 of 3 known problems found. 4 reviews:"

scenario "the cost and time: the mean of the reviews, and the cost of them all"
repo
benchmark
expect_output "0 of 1 known problems found. 2 reviews: \$0.75 and 70 s a review, \$1.50 in all."

scenario "each reviewer is given the model, the effort, the commit checked out, the diff's base and the ticket"
repo
benchmark claude-opus-5-5 high
expect_status 0
[ "$(cat "$T/heads")" = "$commit"$'\n'"$commit" ] || fail "expected both reviews to run in a checkout of the case's commit"
expect_call "run \`git diff $base HEAD\`"
expect_call "# Connect the database"
expect_call "The health check reports the database."
expect_call "--model claude-opus-5-5 --effort high --max-turns"

scenario "each reviewer is given its own job's prompt, turn limit, tools less gh and format from ci.yml"
repo
benchmark
expect_status 0
expect_call "claude -p You are Adam. Read .claude/skills/review-architecture/SKILL.md and follow it to review pull request #7 in this repository."
expect_call "claude -p You are Ryan. Read .claude/skills/review-code/SKILL.md and follow it to review pull request #7 in this repository."
expect_call '--max-turns 40 --allowedTools Read,Glob,Bash(git diff:*),Bash(git log:*) --disallowedTools Bash(gh:*)'
expect_call '--max-turns 30 --allowedTools Read,Grep,Bash(git diff:*) --disallowedTools Bash(gh:*)'
expect_call '--json-schema {"kinds":["design"]} --output-format json'
expect_call '--json-schema {"kinds":["bug"]} --output-format json'
expect_no_call "nobody"
expect_no_call "steps.scope"
expect_no_call "max-turns 5"

scenario "a review cannot reach what merged after the case's commit: the later commit on main, or any ref"
repo
echo "fixed" > fix.txt
git add fix.txt && git commit -q -m "fix: give the query a time limit"
git push -q origin main
git fetch -q origin
benchmark
expect_status 0
[ "$(sort -u "$T/reachable")" = "main"$'\n'"pull request 7" ] || fail "expected a review to reach only the case's commit and its history, not: $(sort -u "$T/reachable")"
[ ! -s "$T/refs" ] || fail "expected the review's repository to hold no ref, not: $(cat "$T/refs")"
expect_nothing_left

scenario "the model's CLI fails: stops and says which review, with nothing left behind"
repo
stub claude 'echo "API error" >&2; exit 1'
benchmark
expect_failure
expect_output "Adam's review of pull request #7 ended with no findings, so the benchmark stopped"
expect_no_output "known problems found"
expect_no_output "| #7 |"
expect_nothing_left

scenario "a review is cut short at its turn limit: stops, and the problem is not counted as missed"
repo
pull_request 12
a_case 12 '{"problem": "A second problem", "files": ["src/out.ts"], "pattern": "export"}'
stub claude '
  case "$*" in
    *"You are Ryan."*"pull request #7 "*) echo "{\"is_error\":true,\"subtype\":\"error_max_turns\",\"total_cost_usd\":2,\"duration_ms\":9}"; exit 1 ;;
    *) cat "$T/adam" ;;
  esac'
benchmark
expect_failure
expect_output "Ryan's review of pull request #7 ended with no findings, so the benchmark stopped"
expect_output "error_max_turns"
expect_no_output "| #7 |"
expect_no_output "known problems found"
expect_nothing_left

scenario "a review answers with no list of findings: stops, though its session did not fail"
repo
echo '{"is_error":false,"total_cost_usd":1,"duration_ms":9,"result":"Looks good."}' > "$T/ryan"
benchmark
expect_failure
expect_output "Ryan's review of pull request #7 ended with no findings"
expect_no_output "| #7 |"

scenario "a later case's review fails: the rows of the cases before it stand"
repo
pull_request 12
a_case 12 '{"problem": "A second problem", "files": ["src/out.ts"], "pattern": "export"}'
stub claude 'case "$*" in *"pull request #12 "*) exit 1 ;; *) cat "$T/adam" ;; esac'
benchmark
expect_failure
expect_output "| #7 | The query has no time limit | missed |"
expect_output "Adam's review of pull request #12 ended with no findings"
expect_no_output "| #12 |"
expect_nothing_left

scenario "origin does not hold a case's pull request: stops before any review"
repo
commit_of_7="$commit"
pull_request 12
commit="$commit_of_7"
a_case 13 '{"problem": "A problem", "files": ["a.sh"], "pattern": "a"}'
benchmark
expect_failure
expect_output "Could not fetch pull request #13 from origin"
expect_no_call "claude"
expect_no_output "| Pull request |"

scenario "the pull request does not hold the case's commit: stops before any review"
repo
jq '.commit = "0123456789012345678901234567890123456789"' factory/benchmark/7.json > "$T/case" && cp "$T/case" factory/benchmark/7.json
benchmark
expect_failure
expect_output "Pull request #7 does not hold the commit 0123456789012345678901234567890123456789 that factory/benchmark/7.json names."
expect_no_call "claude"

scenario "the commit shares no history with main, as in a clone cut short: stops before any review"
repo
git checkout -q --orphan apart
git commit -q --allow-empty -m "apart"
commit=$(git rev-parse HEAD)
git push -q origin "HEAD:refs/pull/12/head"
git checkout -q main
a_case 12 '{"problem": "A problem", "files": ["a.sh"], "pattern": "a"}'
benchmark
expect_failure
expect_output "shares no history with origin/main here"
expect_output "Run benchmark.sh in a full clone."
expect_no_call "claude"

scenario "a case that is not one: no pattern, a pattern jq cannot match, no problem, a short commit, no ticket"
repo
good=$(cat factory/benchmark/7.json)
for broken in 'del(.problems[0].pattern)' '.problems[0].pattern = "(time"' '.problems = []' '.problems[0].files = []' \
  '.commit = "abc123"' 'del(.ticket.body)'; do
  jq "$broken" <<<"$good" > factory/benchmark/7.json
  benchmark
  expect_failure
  expect_output "factory/benchmark/7.json is not a case"
  expect_no_call "claude"
done
echo "not json" > factory/benchmark/7.json
benchmark
expect_failure
expect_output "factory/benchmark/7.json is not a case"

scenario "a case not named after its pull request: stops before any review"
repo
mv factory/benchmark/7.json factory/benchmark/health.json
benchmark
expect_failure
expect_output "factory/benchmark/health.json is not named after its pull request"
expect_no_call "claude"

scenario "no case, as in a new project: says so"
repo
rm factory/benchmark/7.json
benchmark
expect_failure
expect_output "factory/benchmark/ holds no case, so there is nothing to review."
expect_no_call "claude"

scenario "ci.yml lacks a reviewer's format, prompt, turn limit or tools: stops before any review"
repo
cp factory/workflows/ci.yml "$T/ci"
for lacking in '"bug"' 'You are Ryan' 'max-turns 30' 'allowedTools "Read,Grep'; do
  grep -v -- "$lacking" "$T/ci" > factory/workflows/ci.yml
  benchmark
  expect_failure
  expect_output "The ryan job in factory/workflows/ci.yml does not hold a REVIEW_SCHEMA, a prompt for pull request #"
  expect_no_call "claude"
done

scenario "no model or no effort: prints the usage"
repo
run "$scripts/benchmark.sh" claude-fable-5-2
expect_failure
expect_output "Usage: benchmark.sh <model> <effort>"
benchmark claude-fable-5-2 ""
expect_failure
expect_output "Usage: benchmark.sh <model> <effort>"
expect_no_call "claude"
