#!/usr/bin/env bash
# Tests for start-retests.sh: after a merge, each pull request labelled `waits-for-main` gets its fix round.
. "$(dirname "$0")/helpers.sh"

# $T/pulls holds the open pull requests; $T/fail lists the gh calls, by their first words, that fail.
github() {
  : > "$T/fail"; echo '[]' > "$T/pulls"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state open --limit 100 --json number,author,labels,isDraft "*) json "$(cat "$T/pulls")" "$@" ;;
      "workflow run fix.yml -f pr="*) echo "created workflow_dispatch event" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# open <number> <who opened it> <draft> [label]...
open() {
  local number="$1" login="$2" draft="$3"; shift 3
  jq --argjson n "$number" --arg login "$login" --argjson draft "$draft" \
    '. + [{number: $n, author: {login: $login}, isDraft: $draft, labels: ($ARGS.positional | map({name: .}))}]' "$T/pulls" --args "$@" > "$T/pulls.new"
  mv "$T/pulls.new" "$T/pulls"
}
retest() { run env GH_TOKEN=workflow-token "$scripts/start-retests.sh"; }

scenario "starts the fix round of a pull request labelled waits-for-main, and touches none without the label"
github
open 7 app/claude false needs-human waits-for-main
open 8 app/claude false needs-human
open 9 app/claude false
retest
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_output "started the fix round that tests pull request #7 with main again"
[ "$(grep -c '^gh workflow run' "$T/calls")" = 1 ] || fail "expected one workflow to be started"
[ "$(grep -c . "$T/calls")" = 2 ] || fail "expected GitHub to be asked for the list, and one round, and nothing else"

scenario "starts one for each labelled pull request"
github
open 7 app/claude false waits-for-main
open 11 app/claude false waits-for-main needs-human
retest
expect_status 0
expect_call "gh workflow run fix.yml -f pr=7"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "starts nothing, and says so, when no pull request carries the label"
github
open 8 app/claude false needs-human
retest
expect_status 0
expect_no_call "gh workflow run"
expect_output "no pull request is labelled waits-for-main: none is tested again"

scenario "leaves a labelled draft, which its engineer is still building, and a labelled pull request a person opened"
github
open 7 app/claude true waits-for-main
open 8 repo-owner false waits-for-main
retest
expect_status 0
expect_no_call "gh workflow run"

scenario "stops with a message when the pull requests cannot be read: that is not 'none is labelled'"
github
open 7 app/claude false waits-for-main
echo "pr list" > "$T/fail"
retest
expect_status 1
expect_no_call "gh workflow run"
expect_output "The open pull requests could not be read from GitHub, so none labelled waits-for-main is tested again after this merge."
expect_no_output "no pull request is labelled"

scenario "a round that could not be started does not stop the next, and the script fails naming it"
github
open 7 app/claude false waits-for-main
open 11 app/claude false waits-for-main
echo "workflow run fix.yml -f pr=7" > "$T/fail"
retest
expect_status 1
expect_call "gh workflow run fix.yml -f pr=11"
expect_output "started the fix round that tests pull request #11 with main again"
expect_output "could not be started: #7. Each keeps waits-for-main, and the next merge starts it."
