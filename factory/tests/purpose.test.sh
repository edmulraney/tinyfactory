#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/purpose.sh: the interview ends by itself once PURPOSE.md is written.
. "$(dirname "$0")/helpers.sh"

purpose="$root/.claude/skills/bootstrap/scripts/purpose.sh"

# A stand-in for Claude Code: it writes PURPOSE.md when $T/writes exists, runs the Stop hook from --settings as Claude
# Code does when an answer ends, and then records that the session stayed open, as one does until the owner leaves it.
claude_session() {
  stub claude "$(cat <<'STUB'
[ "$1" = --settings ] || exit 2
[ ! -e "$T/writes" ] || echo "# Purpose" > PURPOSE.md
CLAUDE_PROJECT_DIR=$PWD sh -c "$(jq -r '.hooks.Stop[0].hooks[0].command' <<<"$2")" </dev/null
echo "session still open" >> "$T/calls"
STUB
)"
}

scenario "ends the session once the answer that wrote PURPOSE.md is given, and setup carries on"
claude_session
touch "$T/writes"
run in_terminal "$purpose" demo
expect_status 0
expect_call "claude --settings"
expect_no_call "session still open"
expect_output "purpose ok: wrote PURPOSE.md"
expect_no_output "/exit"
expect_no_call "/exit"

scenario "leaves the session open after an answer while PURPOSE.md does not exist, and setup carries on once the owner leaves"
claude_session
run in_terminal "$purpose" demo
expect_status 0
expect_call "session still open"
expect_output "purpose not written yet; setup continues."

scenario "carries on with setup when Claude Code fails to start"
stub claude 'echo "claude: not logged in" >&2; exit 1'
run in_terminal "$purpose" demo
expect_status 0
expect_output "purpose not written yet; setup continues."
