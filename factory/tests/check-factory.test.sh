#!/usr/bin/env bash
# Tests for factory/scripts/check-factory.sh, on small repos of scripts that parse and that do not.
. "$(dirname "$0")/helpers.sh"

# repo_with <file> <bash>...: a repo whose factory/tests/ holds these files.
repo_with() {
  git init -q -b main .
  mkdir -p factory/tests factory/scripts
  while [ $# -gt 0 ]; do
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "factory/tests/$1"
    shift 2
  done
  git add .
}

scenario "passes scripts that parse, and prints how many it checked"
repo_with one.test.sh 'echo "ok - first"' helpers.sh 'true'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok: 2 checked"

scenario "runs no test: a failing test file that parses passes, unrun"
repo_with one.test.sh 'echo "not ok - lets TASTE.md through"; touch "$T/ran"; exit 1'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok: 1 checked"
expect_no_output "lets TASTE.md through"
expect_no_output "factory tests ok"
[ ! -e "$T/ran" ] || fail "expected the test file not to be run"

scenario "fails on a script that does not parse"
repo_with one.test.sh 'echo "ok - first"'
printf '#!/usr/bin/env bash\nif true; then\n' > factory/scripts/broken.sh
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "broken.sh"
expect_no_output "factory scripts ok"

scenario "fails on a test file that does not parse"
repo_with one.test.sh 'if true; then'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "one.test.sh"
expect_no_output "factory scripts ok"

# Put together from two halves, so this file does not hold the construct itself (decisions H22).
open='${'

scenario "fails on a substitution with a quote inside it, naming the file and the line"
repo_with one.test.sh 'echo "ok - first"'
printf '%s\n' '#!/usr/bin/env bash' "echo \"${open}good/'old text'/new}\"" > factory/scripts/quoted.sh
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/scripts/quoted.sh: a \${name/old/new} substitution holds a quote or spans lines"
expect_output "  2:echo"
expect_no_output "factory scripts ok"

scenario "fails on a substitution that spans lines, in a test file too"
repo_with one.test.sh "echo \"ok - first\"
x=\"${open}good//old text/new
text}\""
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/tests/one.test.sh: a \${name/old/new} substitution holds a quote or spans lines"

scenario "passes a substitution on one line with no quote inside it"
repo_with one.test.sh 'echo "ok - first"'
printf '%s\n' '#!/usr/bin/env bash' 'types="feat|fix"' "echo \"one of: ${open}types//|/, }.\"" > factory/scripts/plain.sh
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

# Put together from its parts for the same reason (decisions H121).
list='{id: .a, name: .b}'

scenario "fails on a brace list in quotes inside a quoted command substitution, naming the file and the line"
repo_with one.test.sh 'echo "ok - first"'
printf '%s\n' '#!/usr/bin/env bash' "echo \"\$(jq \"$list\" \"\$1\")\"" > factory/scripts/listed.sh
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/scripts/listed.sh: a brace list in double quotes, inside a command substitution in double quotes"
expect_output "  2:echo"
expect_no_output "factory scripts ok"

scenario "fails on one in the body of a stand-in, with escaped quotes or a range in it, in a test file too"
repo_with one.test.sh "stub gh 'json \"\$(echo \"{\\\"id\\\":1,\\\"name\\\":2}\")\"'
x=\"page \$(echo \"{1..3}\")\""
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/tests/one.test.sh: a brace list in double quotes"
expect_output "  2:stub gh"
expect_output "  3:x="

scenario "passes a brace list that both versions leave alone"
repo_with one.test.sh 'echo "ok - first"'
{
  echo '#!/usr/bin/env bash'
  # In single quotes inside the quoted substitution.
  echo "echo \"\$(jq '$list' \"\$1\")\""
  # In a substitution that is not in quotes.
  echo "x=\$(jq \"$list\" \"\$1\")"
  # In quotes of its own, beside a quoted substitution.
  echo "echo \"\$(cat \"\$1\")\" \"$list\""
  # Two variables with a comma between them.
  echo "echo \"\$(echo \"\${1}, \${2}\")\""
} > factory/scripts/plain.sh
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

# Put together from two halves for the same reason (decisions H684).
amp='&'
pairs='-A'
builtin='readarray'

scenario "fails on each construct a Mac's bash 3.2 lacks, naming the file, the line and the replacement"
for line in 'declare -A seen' "f() { local $pairs seen; }" "x=\$(declare -g${pairs#-} seen)" 'mapfile -t lines < "$1"' "if true; then $builtin -t lines; fi" \
    'coproc cat' "echo \"${open}name,,}\"" "echo \"${open}names[@]^^}\"" "echo \"${open}name^}\"" "make ${amp}>> log" "make |${amp} tee log"; do
  repo_with one.test.sh 'echo "ok - first"'
  printf '%s\n' '#!/usr/bin/env bash' "$line" > factory/scripts/new.sh
  git add .
  run "$scripts/check-factory.sh"
  expect_status 1
  expect_output "factory/scripts/new.sh: a construct that the bash 3.2 of a Mac lacks and bash 5 runs"
  expect_output "a newline-separated string and read it with grep"
  expect_output "  2:$line"
  expect_no_output "factory scripts ok"
  rm -rf .git factory
done

scenario "fails on one in a test file too, and names only the lines that hold one"
repo_with one.test.sh "true
declare -a list
declare $pairs seen"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/tests/one.test.sh: a construct that the bash 3.2 of a Mac lacks"
expect_output "  4:declare -A seen"
expect_no_output "declare -a list"

scenario "passes what bash 3.2 has, and a comment or a message that names what it lacks"
repo_with one.test.sh 'echo "ok - first"'
printf '%s\n' '#!/usr/bin/env bash' 'declare -a list' 'f() { local -r A=1; }' 'mapfile=lines.txt' '# mapfile needs bash 4, and so does declare -A.' \
  'echo "use tr, not readarray or coproc"' 'echo "${1:-a,b}" "${list[0]}, ^"' 'tr "[:upper:]" "[:lower:]" <<<"$1"' \
  'make >> log 2>&1' "make ${amp}> log" 'make 2>&1 | tee log' "sed 's|old|${amp}, new|' \"\$1\"" 'true || make &' > factory/scripts/plain.sh
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

# Put together from two halves for the same reason (decisions H696).
perl='P'
long='--perl'

scenario "fails on each grep called with the Perl flag a Mac's BSD grep lacks, naming the file, the line and the replacement"
for line in "grep -$perl 'a(?=b)' \"\$1\"" "x=\$(grep -o$perl 'a\\Kb' \"\$1\")" "cat \"\$1\" | grep -${perl}o 'a'" "if ! grep -q -$perl 'a' \"\$1\"; then true; fi" \
    "grep -m 1 -c$perl 'a' \"\$1\"" "grep $long-regexp 'a' \"\$1\"" "ls | xargs grep -l $long-regexp 'a'" \
    "LC_ALL=C grep -o$perl 'a' \"\$1\"" "find . -print0 | xargs -0 -n 1 grep -l$perl 'a'" "command grep -$perl 'a' \"\$1\"" "grep -e 'a b' -$perl \"\$1\"" "grep -E \"a\" -$perl \"\$1\""; do
  repo_with one.test.sh 'echo "ok - first"'
  printf '%s\n' '#!/usr/bin/env bash' "$line" > factory/scripts/new.sh
  git add .
  run "$scripts/check-factory.sh"
  expect_status 1
  expect_output "factory/scripts/new.sh: a grep called with \`-P\` or \`--perl-regexp\`, which the BSD grep of a Mac lacks and GNU grep runs"
  expect_output "use \`grep -E\` with the following character inside the match, and strip that character with sed"
  expect_output "  2:$line"
  expect_no_output "factory scripts ok"
  rm -rf .git factory
done

scenario "fails on a grep with the Perl flag in a test file too, and names only the lines that hold one"
repo_with one.test.sh "true
grep -oE 'a' file
grep -o$perl 'a' file"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/tests/one.test.sh: a grep called with"
expect_output "  4:grep -oP 'a' file"
expect_no_output "grep -oE"

scenario "passes the grep flags both greps have, another command's -P, and a comment or a message that names the flag"
repo_with one.test.sh 'echo "ok - first"'
printf '%s\n' '#!/usr/bin/env bash' "grep -oE 'a' \"\$1\"" "grep -E 'a' \"\$1\" | sort -$perl" "grep -c 'PATH' \"\$1\"" \
  "grep -q -- '-$perl' \"\$1\"" "# BSD grep has no grep -$perl." "echo \"write grep -E, not grep -$perl or grep $long-regexp\"" \
  "mkdir -p out && cp -$perl \"\$1\" out" "pgrep -$perl 1 bash" > factory/scripts/plain.sh
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

scenario "stops with a message outside a git repository: that is not a repo with no script in it"
mkdir -p factory/scripts
printf '#!/usr/bin/env bash\nif true; then\n' > factory/scripts/broken.sh
# The ceiling keeps git from finding a repository above the scenario, wherever TMPDIR points.
run env GIT_CEILING_DIRECTORIES="$T" "$scripts/check-factory.sh"
expect_status 1
expect_output "check-factory.sh must be run inside a git repository"
expect_output "nothing was checked"
expect_no_output "factory scripts ok"

long=$(printf 'x%.0s' {1..118})

scenario "passes a header of one line and its usage, in a script, a test file and a workflow"
repo_with one.test.sh '# Tests for one.sh.
true'
printf '%s\n' '#!/usr/bin/env bash' "# $long" '# Usage: one.sh <pr-number>' '#        one.sh --all' '#   Needs GH_TOKEN.' 'set -eu' '# Why, further down.' '# And a second reason.' 'true' > factory/scripts/one.sh
mkdir -p factory/workflows
printf '%s\n' '# Runs the checks.' 'name: ci' '# Why this event.' '# And why not that one.' 'on: push' > factory/workflows/ci.yml
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok: 2 checked"

scenario "fails on a header of two lines, naming the file and the line"
repo_with one.test.sh 'true'
printf '%s\n' '#!/usr/bin/env bash' '# Ships a pull request.' '# It lives in one place because two things ship.' '# Usage: ship.sh <pr-number>' 'true' > factory/scripts/ship.sh
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/scripts/ship.sh: its header is one line of 120 characters or fewer"
expect_output "  line 3 is neither: # It lives in one place because two things ship."
expect_no_output "factory scripts ok"

scenario "fails on a first line over 120 characters, in a test file too"
repo_with one.test.sh "# xx$long
true"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/tests/one.test.sh: its header is one line"
expect_output "  its first line is 122 characters"

scenario "fails on a new script and a new workflow not yet added to git, and reads no ignored file"
repo_with one.test.sh 'true'
printf '%s\n' '#!/usr/bin/env bash' "# xx$long" 'true' > factory/scripts/new.sh
mkdir -p factory/workflows
printf '%s\n' '# Every pull request: checks, then reviews.' '# A draft runs nothing.' 'name: ci' > factory/workflows/new.yml
printf '%s\n' '#!/usr/bin/env bash' "# xx$long" 'true' > factory/scripts/ignored.sh
echo 'factory/scripts/ignored.sh' > .gitignore
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/scripts/new.sh: its header is one line"
expect_output "  its first line is 122 characters"
expect_output "factory/workflows/new.yml: its header is one line"
expect_no_output "ignored.sh"

scenario "fails on a line under the usage that is not indented under it"
repo_with one.test.sh 'true'
printf '%s\n' '#!/usr/bin/env bash' '# Ships a pull request.' '# Usage: ship.sh <pr-number>' '# It never ends in silence.' 'true' > factory/scripts/ship.sh
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "  line 4 is neither: # It never ends in silence."

scenario "fails on a workflow's header of two lines"
repo_with one.test.sh 'true'
mkdir -p factory/workflows
printf '%s\n' '# Every pull request: checks, then reviews.' '# A draft runs nothing.' 'name: ci' > factory/workflows/ci.yml
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/ci.yml: its header is one line"
expect_output "  line 2 is neither: # A draft runs nothing."

scenario "fails on a workflow with no opening comment, which events.sh prints as what it does"
repo_with one.test.sh 'true'
mkdir -p factory/workflows
printf '%s\n' 'name: ci' '# Runs the checks.' 'on: push' > factory/workflows/ci.yml
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/ci.yml: its header is one line"
expect_output "  it has no opening comment"
expect_no_output "factory scripts ok"

scenario "leaves a bootstrap script's header alone: the rule is for the factory's three folders"
repo_with one.test.sh 'true'
mkdir -p .claude/skills/bootstrap/scripts
printf '%s\n' '#!/usr/bin/env bash' '# Sets up a project.' '# In four steps.' 'true' > .claude/skills/bootstrap/scripts/setup.sh
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok: 2 checked"

scenario "stops with a message when the workflows cannot be listed: that is not a repo with none"
repo_with one.test.sh 'true'
real_git=$(command -v git)
stub git "case \"\$*\" in *workflows*) exit 1 ;; *) exec $real_git \"\$@\" ;; esac"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "could not list the workflows"
expect_no_output "factory scripts ok"

# reviewers <Bash entries>: a ci.yml whose checks job runs a script, and whose review job holds these tools.
reviewers() {
  repo_with one.test.sh 'true'
  mkdir -p factory/workflows
  printf '%s\n' '# Runs the checks.' 'jobs:' '  checks:' '          claude_args: |' '            --allowedTools "Read,Bash(factory/scripts/events.sh:*),Bash"' \
    '  review:' '        run: |' '            --max-turns 40 \' "            --allowedTools \"Read,Grep,$1\"" > factory/workflows/ci.yml
  git add .
}

scenario "passes reviewers whose tools run only gh and git, whatever another job's tools run"
reviewers 'Bash(gh pr view:*),Bash(git diff:*),Bash(gh issue view:*),Bash(git log:*)'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

scenario "fails on a reviewer's tool that runs a script from the repo, naming the line, the job and the entry"
reviewers 'Bash(gh pr view:*),Bash(factory/scripts/events.sh:*),Bash(git log:*)'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/ci.yml: a reviewer's tools run no script from the repo (H293d)"
expect_output "  line 9, in the job review: Bash(factory/scripts/events.sh:*)"
expect_no_output "Bash(gh pr view:*)"
expect_no_output "in the job checks"
expect_no_output "factory scripts ok"

scenario "fails on Bash with no command and on a command that only starts like git"
reviewers 'Bash(git diff:*),Bash(gh pr diff:*),Bash,Bash(gitleaks:*),Bash(bash factory/scripts/events.sh)'
run "$scripts/check-factory.sh"
expect_status 1
# The newline ends the line: without it, the gitleaks line below would meet this too.
expect_output $'  line 9, in the job review: Bash\n'
expect_output "  line 9, in the job review: Bash(gitleaks:*)"
expect_output "  line 9, in the job review: Bash(bash factory/scripts/events.sh)"
expect_no_output "Bash(git diff:*)"

scenario "leaves another workflow's tools alone: only ci.yml's reviewers check out a pull request to judge it"
reviewers 'Bash(git diff:*),Bash(git log:*)'
printf '%s\n' '# Builds a ticket.' 'jobs:' '  review:' '            --allowedTools "Bash(pnpm:*)"' > factory/workflows/implement.yml
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

# says <line>...: a script of the factory's that holds these lines.
says() {
  [ -d .git ] || repo_with one.test.sh 'true'
  { echo '#!/usr/bin/env bash'; echo '# Tells a pull request what happened.'; printf '%s\n' "$@"; } > factory/scripts/tell.sh
  git add .
}

scenario "fails on a script whose comment to the owner holds a gh command, naming the line"
says 'gh pr comment "$pr" --body "Run \`gh workflow run fix.yml -f pr=$pr\`: a new fix round starts."'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/scripts/tell.sh: words the factory writes hold a \`gh\` command in backticks"
expect_output '  3:gh pr comment "$pr" --body "Run \`gh workflow run fix.yml -f pr=$pr\`: a new fix round starts."'
expect_no_output "factory scripts ok"

scenario "fails on a workflow step that writes a gh command for a person, and passes the commands an agent's prompt names"
repo_with one.test.sh 'true'
mkdir -p factory/workflows
printf '%s\n' '# Fixes a pull request.' 'jobs:' '  fix:' '    steps:' '      - uses: anthropics/claude-code-action@v1' '        with:' \
  '          prompt: |' '            Read the pull request with `gh pr view <n>`.' '' '            Then reply with `gh issue comment <n>`.' \
  '          claude_args: --max-turns 5' '      - run: |' \
  "          printf 'Start it again: \`gh workflow run fix.yml -f pr=%s\`' \"\$PR\" > body.md" > factory/workflows/fix.yml
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/fix.yml: words the factory writes hold a \`gh\` command in backticks"
expect_output "  13:          printf 'Start it again: \`gh workflow run fix.yml -f pr=%s\`'"
expect_no_output "gh pr view <n>"
expect_no_output "gh issue comment <n>"

scenario "passes a script that runs gh itself, links a workflow's page, and names a gh command only in a comment of its own"
says 'set -euo pipefail' '# The files endpoint, not `gh pr diff` (decisions H7).' 'gh workflow run fix.yml -f pr="$pr"' \
  'page=$("$script_dir/workflow-page.sh" fix.yml pr="$pr")' 'gh pr comment "$pr" --body "Start the fix round on $page. Its tools begin \`gh \` or \`git \`."'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

# started_by <on>... -- <job line>...: a workflow those lines of `on:` start, with one job, build, of these lines.
started_by() {
  [ -d .git ] || repo_with one.test.sh 'true'
  mkdir -p factory/workflows
  {
    echo '# Builds a ticket.'
    while [ "$1" != -- ]; do echo "$1"; shift; done
    shift
    printf '%s\n' 'jobs:' '  build:' "$@"
  } > factory/workflows/build.yml
  git add .
}
asks='      - run: factory/scripts/trusted.sh "$SENDER"'
vouched="    if: github.event.label.name == 'ready' && github.event.issue.author_association == 'OWNER'"

scenario "fails on a job an issue's label starts whose if: names no account, naming the file and the job"
started_by 'on:' '  issues:' '    types: [labeled]' -- "    if: github.event.label.name == 'ready'" '    steps:' "$asks"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/build.yml: \`issues\`, \`issue_comment\`, \`pull_request_review\`, \`pull_request_review_comment\` or \`pull_request_target\` starts it"
expect_output "  the job build: its \`if:\` names no account the event vouches for"
expect_no_output "no step runs"
expect_no_output "factory scripts ok"

scenario "fails on such a job with no if: at all, and on one whose only condition is on a step"
started_by 'on:' '  issues:' -- '    steps:' "$asks"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "  the job build: its \`if:\` names no account the event vouches for"
started_by 'on:' '  issues:' -- '    steps:' "$asks" "        if: github.event.issue.author_association == 'OWNER'"
run "$scripts/check-factory.sh"
expect_status 1
expect_output "  the job build: its \`if:\` names no account the event vouches for"

scenario "fails on such a job that never asks trusted.sh: a comment that names the script is not a step that runs it"
started_by 'on:' '  issues:' -- "$vouched" '    steps:' '      # factory/scripts/trusted.sh is asked by the script below.' '      - run: make'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "  the job build: no step runs factory/scripts/trusted.sh"
expect_no_output "names no account"

scenario "fails for each event anyone can raise, however on: lists it"
for event in issues issue_comment pull_request_review pull_request_review_comment pull_request_target; do
  started_by 'on:' '  push:' "  $event:" '    types: [created]' -- '    steps:' '      - run: make'
  run "$scripts/check-factory.sh"
  expect_status 1
  expect_output "  the job build: its \`if:\` names no account the event vouches for"
  expect_output "  the job build: no step runs factory/scripts/trusted.sh"
  started_by "on: $event" -- '    steps:' '      - run: make'
  run "$scripts/check-factory.sh"
  expect_status 1
  started_by "on: [push, $event]" -- '    steps:' '      - run: make'
  run "$scripts/check-factory.sh"
  expect_status 1
done

scenario "passes a job whose if: names an account the event vouches for, on one line or folded over several, and that asks trusted.sh"
for condition in "$vouched" "    if: github.event.review.user.login == github.repository_owner" \
    "    if: github.event.pull_request.user.login == 'claude[bot]'" "    if: github.event.issue.user.login == 'github-actions[bot]'" \
    "    if: github.event.pull_request.merged == true"; do
  started_by 'on:' '  issues:' '  pull_request_review:' '  pull_request_target:' -- "$condition" '    steps:' "$asks"
  run "$scripts/check-factory.sh"
  expect_status 0
  expect_output "factory scripts ok"
done
started_by 'on:' '  issues:' -- '    if: >-' "      github.event.label.name == 'ready' &&" \
  "      contains(fromJSON('[\"OWNER\"]'), github.event.issue.author_association)" '    steps:' "$asks"
run "$scripts/check-factory.sh"
expect_status 0

scenario "names only the job that lacks the condition, of two"
started_by 'on:' '  issue_comment:' -- "$vouched" '    steps:' "$asks" '  tell:' '    steps:' '      - run: gh issue comment'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "  the job tell: its \`if:\` names no account the event vouches for"
expect_output "  the job tell: no step runs factory/scripts/trusted.sh"
expect_no_output "the job build"

scenario "leaves alone a workflow none of the five events starts, though it names one elsewhere"
started_by 'on:' '  pull_request:' '    types: [opened]' '  workflow_dispatch:' '  schedule:' '    - cron: "17 6 * * 5"' \
  'permissions:' '  issues: write' -- '    permissions:' '      issues: write' '    steps:' '      - run: gh api repos/o/r/issues'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"
started_by 'on: [push, pull_request]' -- '    steps:' '      - run: make'
run "$scripts/check-factory.sh"
expect_status 0

scenario "fails on an ordered list numbered by hand in a file .gitattributes marks merge=list, naming the file and the line"
repo_with one.test.sh 'true'
printf 'factory/guide.md merge=list\n' > .gitattributes
printf '# Guide\n\n1. File a ticket.\n2. Add the label.\n' > factory/guide.md
git add .
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/guide.md: .gitattributes marks it \`merge=list\`, so each item of an ordered list is written \`1.\`"
expect_output "  4:2. Add the label."
expect_no_output "factory scripts ok"

scenario "passes a marked file whose every item is written 1., and a list numbered by hand in a file no mark names"
repo_with one.test.sh 'true'
printf 'factory/guide.md merge=list\n' > .gitattributes
printf '# Guide\n\n1. File a ticket.\n1. Add the label.\n' > factory/guide.md
printf '# Steps\n\n1. One.\n2. Two.\n' > factory/steps.md
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok: 1 checked"
