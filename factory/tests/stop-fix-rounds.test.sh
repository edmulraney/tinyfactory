#!/usr/bin/env bash
# Tests for stop-fix-rounds.sh: a pull request out of rounds and its ticket are flagged, told why, and a retro starts.
. "$(dirname "$0")/helpers.sh"

# $T/fail holds one line per gh call, by its first words, that should fail.
github() {
  : > "$T/fail"
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr edit 7 --add-label needs-human" | "pr comment 7 --body "*) echo "https://github.example/7" ;;
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "issue edit 12 --add-label needs-human --remove-label in-progress") echo "https://github.example/12" ;;
      "workflow run retro.yml -f pr=7") echo "created workflow_dispatch event" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
stop_rounds() { run env GH_TOKEN=workflow-token "$scripts/stop-fix-rounds.sh" 7; }

scenario "flags the pull request and its ticket, which is no longer in progress, tells it why and starts a retro"
github
stop_rounds
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"
expect_call "gh pr comment 7 --body Three fix rounds have not got this pull request to green. Stopping here; it needs a human."
expect_call "gh workflow run retro.yml -f pr=7"
[ "$(wc -l < "$T/calls")" -eq 5 ] || fail "expected those calls, the read of the description, and no other"

scenario "flags no ticket for a pull request that closes none"
github
echo "A person's own pull request." > "$T/body"
stop_rounds
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"
expect_call "gh workflow run retro.yml -f pr=7"

while IFS='|' read -r words message; do
  scenario "stops with a message when this fails: gh $words"
  github
  echo "$words" > "$T/fail"
  stop_rounds
  expect_status 1
  expect_output "$message"
done <<'CALLS'
pr edit 7|Pull request #7 has used its three fix rounds, and needs-human could not be added to it.
pr view 7 --json body|Pull request #7 has used its three fix rounds, and the ticket it closes could not be flagged.
issue edit 12|Pull request #7 has used its three fix rounds, and the ticket it closes could not be flagged.
pr comment 7|Pull request #7 has used its three fix rounds, and could not be told so.
workflow run retro.yml|Pull request #7 has used its three fix rounds and was told so, but the retro could not be started.
CALLS

scenario "leaves nothing behind"
github
stop_rounds
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
