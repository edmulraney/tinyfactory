#!/usr/bin/env bash
# Runs every setup step in order, in the current directory. `npx tinyfactory <name>` makes the folder and runs this.
# Usage: bootstrap.sh [name]   (name defaults to the directory name)
#        Safe to re-run: each step leaves alone what an earlier run finished, so the same command carries on.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
name="${1:-$(basename "$PWD")}"

for step in preflight scaffold purpose github vercel database database-key sign-in preview-access board board-token workflow-app agent-token; do
  printf '\n== %s ==\n' "$step"
  # The scaffold ends by proving the project, which takes minutes. A project whose first commit
  # holds the app and the factory's scripts was scaffolded and proven by the run that made the
  # commit. A commit that holds neither, such as a clone with only a README, is no scaffold.
  if [ "$step" = scaffold ] && [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ] \
    && git cat-file -e HEAD:apps/web/package.json 2>/dev/null && git cat-file -e HEAD:factory/scripts 2>/dev/null; then
    echo "scaffold ok: $name has its first commit already"
    continue
  fi
  if ! "$here/$step.sh" "$name"; then
    printf '\nSetup stopped at %s. Fix what it reports, then run the same command again: it carries on from here.\n' "$step" >&2
    exit 1
  fi
done
printf '\nbootstrap complete: %s\n' "$name"
