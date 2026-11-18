#!/usr/bin/env bash
# Tests for flag-ticket.sh: the ticket a pull request closes is flagged for a person; gh is the one stand-in.
. "$(dirname "$0")/helpers.sh"

# Pull request #7 closes #12; $T/fail holds one line per gh call, by its first words, that should fail.
github() {
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "issue edit 12 --add-label needs-human --remove-label in-progress") echo "https://github.example/12" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
flag() { run env GH_TOKEN=workflow-token "$scripts/flag-ticket.sh" 7; }

scenario "flags the ticket the pull request closes, which is no longer in progress"
github
flag
expect_status 0
expect_call "gh issue edit 12 --add-label needs-human --remove-label in-progress"

scenario "a pull request that closes no ticket has none to flag"
github
echo "A change with no ticket." > "$T/body"
flag
expect_status 0
expect_no_call "gh issue edit"

scenario "stops with a message when the pull request cannot be read: that is not 'closes no ticket'"
github
echo "pr view 7" > "$T/fail"
flag
expect_status 1
expect_output "The ticket pull request #7 closes could not be read, so it was not flagged for a person."
expect_no_call "gh issue edit"

scenario "stops with a message when the ticket cannot be flagged"
github
echo "issue edit 12" > "$T/fail"
flag
expect_status 1
expect_output "Could not add needs-human to issue #12, which pull request #7 closes."

scenario "leaves nothing behind"
github
flag
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
