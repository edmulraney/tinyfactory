#!/usr/bin/env bash
# Runs every setup step in order, in the current directory. `npx tinyfactory <name>` makes the folder and runs this.
# Usage: bootstrap.sh [name]   (name defaults to the directory name)
#        Safe to re-run: each step leaves alone what an earlier run finished, so the same command carries on.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
name="${1:-$(basename "$PWD")}"
. "$here/present.sh"

# Each step writes here what it left for the owner (decisions S421c).
SETUP_NEEDS_OWNER=$(mktemp)
# The deploy step writes here the address production answers at, for the closing summary.
SETUP_PRODUCTION=$(mktemp)
export SETUP_NEEDS_OWNER SETUP_PRODUCTION
trap 'rm -f "$SETUP_NEEDS_OWNER" "$SETUP_PRODUCTION"' EXIT

steps=(preflight scaffold purpose github vercel database database-key sign-in preview-access board board-token workflow-app agent-token deploy)
number=0
for step in "${steps[@]}"; do
  number=$((number + 1))
  heading "[$number/${#steps[@]}] $step"
  # The scaffold ends by proving the project, which takes minutes. A project whose first commit
  # holds the app and the factory's scripts was scaffolded and proven by the run that made the
  # commit. A commit that holds neither, such as a clone with only a README, is no scaffold.
  if [ "$step" = scaffold ] && [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ] \
    && git cat-file -e HEAD:apps/web/package.json 2>/dev/null && git cat-file -e HEAD:factory/scripts 2>/dev/null; then
    mark done "scaffold ok: $name has its first commit already"
    continue
  fi
  if ! "$here/$step.sh" "$name"; then
    mark failed "Setup stopped at $step. Fix what it reports, then run the same command again: it carries on from here." >&2
    exit 1
  fi
done

heading "What to do next"
[ ! -s "$SETUP_PRODUCTION" ] || mark done "$name is live: $(cat "$SETUP_PRODUCTION") runs the commit on main"
if [ -s "$SETUP_NEEDS_OWNER" ]; then
  { echo "Do what these steps ask above, then run the same command again: it confirms each."; cat "$SETUP_NEEDS_OWNER"; } | owner_block
else
  mark done "bootstrap complete: $name"
  echo "File a ticket, then add the \`ready\` label to it, which starts its build: factory/owner-guide.md says how."
fi
