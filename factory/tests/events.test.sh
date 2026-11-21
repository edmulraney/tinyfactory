#!/usr/bin/env bash
# Tests for factory/scripts/events.sh, on stand-in workflows and the scripts that start them (decisions H293a).
. "$(dirname "$0")/helpers.sh"

workflow() {
  mkdir -p factory/workflows factory/scripts
  local name="$1"
  shift
  printf '%s\n' "$@" > "factory/workflows/$name.yml"
}
row() { grep -F "| \`$1.yml\` |" <<<"$out" || true; }
expect_row() {
  [ "$(row "$1")" = "| \`$1.yml\` | $2 | $3 | $4 |" ] || fail "expected the row: | \`$1.yml\` | $2 | $3 | $4 |"
}

scenario "lists every workflow, one row each under the column names, in the order of their names"
workflow ship '# Ships a pull request.' 'name: ship' 'on: push'
workflow build '# Builds a ticket.' 'name: build' 'on: workflow_dispatch'
run "$scripts/events.sh"
expect_status 0
[ "$out" = "| Workflow | Starts on | What it does | Started by |
|---|---|---|---|
| \`build.yml\` | workflow_dispatch | Builds a ticket. | no script or workflow |
| \`ship.yml\` | push | Ships a pull request. | no script or workflow |" ] || fail "expected the two rows under the column names, and nothing else"

scenario "the trigger: each event under on, with its types, branches, paths, schedule and inputs, and no comment"
workflow ci '# Checks.' 'name: ci' '' 'on:' '  # Why this event.' '  pull_request:' '    types: [opened, synchronize]' \
  "    paths: ['factory/workflows/**']" '  push:' '    branches:' '      - main' '      - next' '  workflow_dispatch:' '    inputs:' \
  '      pr:' '        description: Pull request number' '        required: true' '      run:' '        required: false' \
  '' 'concurrency:' '  group: ci' 'jobs:' '  checks:' '    runs-on: ubuntu-latest'
workflow nightly '# Looks.' 'on:' '  schedule:' '    # Off the hour.' '    - cron: "43 */6 * * *"' 'jobs:' '  look:' '    steps: []'
workflow retro '# Learns.' 'on:' '  workflow_run:' '    workflows: [build, fix]' '    types: [completed]' '  workflow_dispatch:' 'jobs: {}'
workflow both '# Both.' 'on: [push, pull_request]' 'jobs: {}'
workflow quoted '# Quoted.' '"on":' '  push:' 'jobs: {}'
run "$scripts/events.sh"
expect_status 0
expect_row ci "pull_request (types: opened synchronize, paths: factory/workflows/**); push (branches: main next); workflow_dispatch (inputs: pr run)" "Checks." "no script or workflow"
expect_row nightly "schedule (cron: 43 */6 * * *)" "Looks." "no script or workflow"
expect_row retro "workflow_run (workflows: build fix, types: completed); workflow_dispatch" "Learns." "no script or workflow"
expect_row both "push pull_request" "Both." "no script or workflow"
expect_row quoted "push" "Quoted." "no script or workflow"
expect_no_output "ubuntu"
expect_no_output "group"

scenario "the comment: the workflow's first line, and no comment further down"
workflow ci '# Checks every pull request, and merges `one`.' 'name: ci' '# Why push.' 'on: push'
run "$scripts/events.sh"
expect_row ci "push" "Checks every pull request, and merges \`one\`." "no script or workflow"
expect_no_output "Why push"

scenario "what starts it: each script, bootstrap script and other workflow that holds its gh workflow run"
workflow fix '# Fixes.' 'on: workflow_dispatch' 'jobs:' '  again:' '    steps:' '      - run: gh workflow run fix.yml -f pr=7'
workflow fix-all '# Fixes all.' 'on: workflow_dispatch'
workflow ci '# Checks.' 'on: push' 'jobs:' '  start:' '    steps:' '      - run: if gh workflow run fix.yml -f pr="$PR"; then exit 0; fi'
workflow check '# Proves.' 'on: workflow_dispatch'
mkdir -p .claude/skills/bootstrap/scripts
echo 'gh workflow run fix.yml -f pr="$pr" >/dev/null' > factory/scripts/start-fix.sh
echo 'gh workflow run fix-all.yml' > factory/scripts/start-all.sh
echo 'echo "To start one: `gh workflow run fix.yml -f pr=$pr`."' > factory/scripts/tell.sh
echo 'gh workflow run check -R "$repo"' > .claude/skills/bootstrap/scripts/token.sh
echo 'gh workflow run fix.yml' > factory/scripts/notes.md
run "$scripts/events.sh"
expect_status 0
expect_row fix "workflow_dispatch" "Fixes." "\`start-fix.sh\`, \`ci.yml\`"
expect_row fix-all "workflow_dispatch" "Fixes all." "\`start-all.sh\`"
expect_row check "workflow_dispatch" "Proves." "\`token.sh\`"
expect_row ci "push" "Checks." "no script or workflow"

scenario "stops with a message on a workflow with no opening comment, and prints no table"
workflow build '# Builds.' 'on: push'
workflow ship 'name: ship' '# Ships.' 'on: push'
run "$scripts/events.sh"
expect_status 1
expect_output "factory/workflows/ship.yml has no opening comment"
expect_no_output "| Workflow |"

scenario "stops with a message on a workflow with no trigger, and prints no table"
workflow build '# Builds.' 'name: build' 'jobs: {}'
run "$scripts/events.sh"
expect_status 1
expect_output "factory/workflows/build.yml has no \`on:\`"
expect_no_output "| Workflow |"

scenario "stops with a message where there is no workflow: that is not a factory with no event"
run "$scripts/events.sh"
expect_status 1
expect_output "factory/workflows/ holds no workflow"
expect_no_output "| Workflow |"

scenario "prints a row for every workflow this repo holds"
cd "$root" || exit 1
run "$scripts/events.sh"
expect_status 0
for file in factory/workflows/*.yml; do
  [ -n "$(row "$(basename "$file" .yml)")" ] || fail "expected a row for $file"
done
