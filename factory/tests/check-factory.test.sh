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

# reviewers <adam's Bash entries> <ryan's>: a ci.yml whose checks job runs a script, and whose reviewers hold these tools.
reviewers() {
  repo_with one.test.sh 'true'
  mkdir -p factory/workflows
  printf '%s\n' '# Runs the checks.' 'jobs:' '  checks:' '          claude_args: |' '            --allowedTools "Read,Bash(factory/scripts/events.sh:*),Bash"' \
    '  adam:' '          claude_args: |' "            --allowedTools \"Read,Grep,$1\"" \
    '  ryan:' '          claude_args: |' '            --max-turns 40' "            --allowedTools \"Read,$2\"" > factory/workflows/ci.yml
  git add .
}

scenario "passes reviewers whose tools run only gh and git, whatever another job's tools run"
reviewers 'Bash(gh pr view:*),Bash(git diff:*)' 'Bash(gh issue view:*),Bash(git log:*)'
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"

scenario "fails on a reviewer's tool that runs a script from the repo, naming the line, the job and the entry"
reviewers 'Bash(gh pr view:*),Bash(factory/scripts/events.sh:*)' 'Bash(git log:*)'
run "$scripts/check-factory.sh"
expect_status 1
expect_output "factory/workflows/ci.yml: a reviewer's job checks out the pull request with a token that writes, so it runs no script from the repo (H293d)"
expect_output "  line 8, in the job adam: Bash(factory/scripts/events.sh:*)"
expect_no_output "Bash(gh pr view:*)"
expect_no_output "in the job checks"
expect_no_output "factory scripts ok"

scenario "fails on the second reviewer's too, on Bash with no command and on a command that only starts like git"
reviewers 'Bash(git diff:*)' 'Bash(gh pr diff:*),Bash,Bash(gitleaks:*),Bash(bash factory/scripts/events.sh)'
run "$scripts/check-factory.sh"
expect_status 1
# The newline ends the line: without it, the gitleaks line below would meet this too.
expect_output $'  line 12, in the job ryan: Bash\n'
expect_output "  line 12, in the job ryan: Bash(gitleaks:*)"
expect_output "  line 12, in the job ryan: Bash(bash factory/scripts/events.sh)"
expect_no_output "in the job adam"

scenario "leaves another workflow's tools alone: only ci.yml's reviewers check out a pull request to judge it"
reviewers 'Bash(git diff:*)' 'Bash(git log:*)'
printf '%s\n' '# Builds a ticket.' 'jobs:' '  adam:' '            --allowedTools "Bash(pnpm:*)"' > factory/workflows/implement.yml
git add .
run "$scripts/check-factory.sh"
expect_status 0
expect_output "factory scripts ok"
