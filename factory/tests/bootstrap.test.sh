#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/bootstrap.sh: which steps a setup runs, and where it stops.
. "$(dirname "$0")/helpers.sh"

# setup: a copy of bootstrap.sh beside stand-ins for its steps. Each writes its name to $T/steps; the one named in $T/fails exits 1,
# the one named in $T/asks leaves a click to the owner, and deploy gives the closing summary production's address.
setup() {
  mkdir -p "$T/setup"
  cp "$root/.claude/skills/bootstrap/scripts/bootstrap.sh" "$root/.claude/skills/bootstrap/scripts/present.sh" "$T/setup/"
  : > "$T/steps"
  : > "$T/fails"
  : > "$T/asks"
  local step
  for step in preflight scaffold purpose github vercel database database-key sign-in preview-access board board-token workflow-app agent-token deploy; do
    cat > "$T/setup/$step.sh" <<EOF
#!/usr/bin/env bash
. "\$(dirname "\$0")/present.sh"
echo "$step" >> "\$T/steps"
if grep -qx "$step" "\$T/asks"; then mark needs-owner "$step: a click is left for you"; else mark done "$step ok"; fi
[ "$step" != deploy ] || [ -s "\$SETUP_NEEDS_OWNER" ] || echo https://shop.example > "\$SETUP_PRODUCTION"
! grep -qx "$step" "\$T/fails"
EOF
    chmod +x "$T/setup/$step.sh"
  done
}
# committed <path>...: this folder is a git repository whose one commit holds these files.
committed() {
  git init --quiet .
  local path
  for path in "$@"; do mkdir -p "$(dirname "$path")"; echo x > "$path"; done
  git add --all
  git commit --quiet -m "first commit"
}
ran() { grep -qx "$1" "$T/steps" || fail "expected the step $1 to run"; }
did_not_run() { ! grep -qx "$1" "$T/steps" || fail "expected the step $1 not to run"; }

scenario "runs the scaffold in a folder that is no git repository"
setup
run "$T/setup/bootstrap.sh" shop
expect_status 0
ran scaffold
ran deploy
expect_output "bootstrap complete: shop"

scenario "skips the scaffold where the first commit holds the app and the factory's scripts"
setup
committed apps/web/package.json factory/scripts/ship.sh
run "$T/setup/bootstrap.sh" shop
expect_status 0
did_not_run scaffold
ran purpose
expect_output "scaffold ok: shop has its first commit already"

scenario "runs the scaffold in a repository whose commit holds no scaffold, such as a clone with only a README"
setup
committed README.md
run "$T/setup/bootstrap.sh" shop
expect_status 0
ran scaffold

scenario "stops at the step that fails, says which, and runs none after it"
setup
echo vercel > "$T/fails"
run "$T/setup/bootstrap.sh" shop
expect_status 1
expect_output "Setup stopped at vercel."
ran github
did_not_run database

scenario "in a terminal, heads each step in bold with its number out of fourteen, and marks each end in its colour"
setup
echo vercel > "$T/fails"
echo purpose > "$T/asks"
run in_terminal "$T/setup/bootstrap.sh" shop
expect_status 1
expect_output $'\033[1m[1/14] preflight\033[0m'
expect_output $'\033[1m[5/14] vercel\033[0m'
expect_output $'\033[32m✓\033[0m preflight ok'
expect_output $'\033[33m!\033[0m purpose: a click is left for you'
expect_output $'\033[31m✗\033[0m Setup stopped at vercel.'

scenario "ends a run that left nothing to the owner by saying where production answers and what to do next"
setup
run "$T/setup/bootstrap.sh" shop
expect_status 0
expect_output "$(printf '\n\n[14/14] deploy\n')"
expect_output "✓ shop is live: https://shop.example runs the commit on main"
expect_output "File a ticket, then add the \`ready\` label to it"
expect_no_output "run the same command again"

scenario "ends a run by listing each step that left something to the owner, in one block"
setup
printf 'database\nboard\n' > "$T/asks"
run "$T/setup/bootstrap.sh" shop
expect_status 0
expect_output "$(printf 'run the same command again: it confirms each.\n  database: a click is left for you\n  board: a click is left for you\n')"
expect_no_output "bootstrap complete"
expect_no_output "is live"
[ -z "$(ls -A "$TMPDIR")" ] || fail "left behind in the temporary directory: $(ls -A "$TMPDIR")"

# words <text>: the text without escape codes and the box, its spaces and line ends as one space each.
words() { sed -E $'s/\033\\[[0-9;]*m//g' <<<"$1" | tr -d '\r' | sed 's/[┌─│└]//g' | tr -s ' \n' ' '; }

scenario "prints no escape code and no box, and the same words, into a pipe and with NO_COLOR set"
setup
echo board > "$T/asks"
run in_terminal "$T/setup/bootstrap.sh" shop
styled=$out
expect_output "┌──"
run "$T/setup/bootstrap.sh" shop
expect_no_output $'\033'
expect_no_output "┌"
expect_no_output "│"
[ "$(words "$out")" = "$(words "$styled")" ] || fail "expected the same words as in a terminal, which printed: $styled"
piped=$out
run in_terminal env NO_COLOR=1 "$T/setup/bootstrap.sh" shop
expect_no_output $'\033'
expect_no_output "┌"
[ "$(tr -d '\r' <<<"$out")" = "$piped" ] || fail "expected NO_COLOR to print what a pipe gets, which was: $piped"
