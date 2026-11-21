#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/bootstrap.sh: which steps a setup runs, and where it stops.
. "$(dirname "$0")/helpers.sh"

# setup: a copy of bootstrap.sh beside stand-ins for its steps. Each writes its name to $T/steps; the one named in $T/fails exits 1.
setup() {
  mkdir -p "$T/setup"
  cp "$root/.claude/skills/bootstrap/scripts/bootstrap.sh" "$T/setup/bootstrap.sh"
  : > "$T/steps"
  : > "$T/fails"
  local step
  for step in preflight scaffold purpose github vercel database database-key sign-in preview-access board board-token workflow-app agent-token; do
    printf '#!/usr/bin/env bash\necho "%s" >> "$T/steps"\n! grep -qx "%s" "$T/fails"\n' "$step" "$step" > "$T/setup/$step.sh"
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
ran agent-token
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
