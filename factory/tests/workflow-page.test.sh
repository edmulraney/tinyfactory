#!/usr/bin/env bash
# Tests for workflow-page.sh: the words that link a workflow's page, where a person starts it (decisions A691a).
. "$(dirname "$0")/helpers.sh"

scenario "links the workflow's page in this repository, and says what starts it there"
run env GITHUB_REPOSITORY=owner/myapp GITHUB_SERVER_URL=https://github.example "$scripts/workflow-page.sh" resume.yml
expect_status 0
[ "$out" = 'the [`resume` workflow'"'"'s page](https://github.example/owner/myapp/actions/workflows/resume.yml), where "Run workflow" starts it' ] \
  || fail "expected exactly the link and what starts the workflow there"

scenario "names each input to fill in, with its value, and holds no command"
run env -u GITHUB_SERVER_URL GITHUB_REPOSITORY=owner/myapp "$scripts/workflow-page.sh" install-workflows.yml pr=8 then="9 10"
expect_status 0
expect_output '(https://github.com/owner/myapp/actions/workflows/install-workflows.yml), where "Run workflow" starts it with `pr` set to `8` and `then` set to `9 10`'
expect_no_output "gh workflow run"

scenario "stops, and prints no link, when nothing names the repository"
run env -u GITHUB_REPOSITORY "$scripts/workflow-page.sh" fix.yml pr=7
expect_failure
expect_output "workflow-page.sh needs GITHUB_REPOSITORY to link the page of fix.yml"
expect_no_output "actions/workflows"
