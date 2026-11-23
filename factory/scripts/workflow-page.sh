#!/usr/bin/env bash
# Prints the words that link a workflow's page on GitHub, where "Run workflow" starts it (decisions A691a).
# Usage: workflow-page.sh <workflow-file> [<input>=<value>]...
#        Prints one phrase to end a sentence with: the link, then each input to fill in. Needs GITHUB_REPOSITORY.
set -euo pipefail

workflow="${1:?Usage: workflow-page.sh <workflow-file> [<input>=<value>]...}"
shift
repo="${GITHUB_REPOSITORY:?workflow-page.sh needs GITHUB_REPOSITORY to link the page of $workflow}"
inputs=""
for input; do
  inputs+="${inputs:+ and} \`${input%%=*}\` set to \`${input#*=}\`"
done
printf 'the [`%s` workflow'"'"'s page](%s/%s/actions/workflows/%s), where "Run workflow" starts it%s\n' \
  "${workflow%.yml}" "${GITHUB_SERVER_URL:-https://github.com}" "$repo" "$workflow" "${inputs:+ with$inputs}"
