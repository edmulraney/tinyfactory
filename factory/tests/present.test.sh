#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/present.sh: a step's heading, its marks and the block for the owner.
. "$(dirname "$0")/helpers.sh"

# shown.sh <bash>: runs the bash after sourcing present.sh, as a setup script would.
shown="$_base/shown.sh"
printf '#!/usr/bin/env bash\n. "%s"\neval "$1"\n' "$root/.claude/skills/bootstrap/scripts/present.sh" > "$shown"
chmod +x "$shown"
block='printf "%s\n" "Approve the token in the browser." "https://github.com/login/device" "ABCD-1234" | owner_block'

scenario "prints a heading in bold in a terminal, with space above"
run in_terminal "$shown" 'echo before; heading "[9/13] board"'
expect_status 0
expect_output $'before\r\n\r\n\033[1m[9/13] board\033[0m'

scenario "marks a step that ended well in green, one that needs the owner in yellow and one that failed in red"
run in_terminal "$shown" 'mark done "board ok"; mark needs-owner "a click is left"; mark failed "board stopped"'
expect_status 0
expect_output $'\033[32m✓\033[0m board ok'
expect_output $'\033[33m!\033[0m a click is left'
expect_output $'\033[31m✗\033[0m board stopped'

scenario "boxes what the owner must do in a terminal: the action first, then the link and the code on lines of their own"
run in_terminal "$shown" "$block"
expect_status 0
expect_output $'┌──'
expect_output $'│\033[0m \033[1mApprove the token in the browser.\033[0m\r\n'
expect_output $'│\033[0m https://github.com/login/device\r\n'
expect_output $'│\033[0m ABCD-1234\r\n'
expect_output $'└──'

scenario "prints the same words with no escape code and no box into a pipe"
run "$shown" "heading '[9/13] board'; mark done 'board ok'; mark needs-owner 'a click is left'; mark failed 'board stopped'; $block"
expect_status 0
[ "$out" = $'\n[9/13] board\n✓ board ok\n! a click is left\n✗ board stopped\n\n  Approve the token in the browser.\n  https://github.com/login/device\n  ABCD-1234' ] \
  || fail "expected the plain heading, marks and block"

scenario "prints no escape code and no box in a terminal where NO_COLOR is set"
run in_terminal env NO_COLOR=1 "$shown" "heading '[9/13] board'; mark failed 'board stopped'; $block"
expect_status 0
expect_no_output $'\033'
expect_no_output "┌"
expect_output $'[9/13] board\r\n✗ board stopped\r\n\r\n  Approve the token in the browser.\r\n  https://github.com/login/device\r\n'

scenario "styles a block made inside a command substitution as the terminal the script writes to"
run in_terminal "$shown" 'made=$(echo Approve | owner_block); echo "$made"'
expect_status 0
expect_output "┌──"

scenario "records what a step left for the owner where bootstrap.sh asked for it, and nothing else"
run env SETUP_NEEDS_OWNER="$T/needs-owner" "$shown" "mark done 'board ok'; mark needs-owner 'a click is left'; mark failed 'board stopped'"
expect_status 0
[ "$(cat "$T/needs-owner")" = "a click is left" ] || fail "expected only the step that needs the owner, got: $(cat "$T/needs-owner")"
