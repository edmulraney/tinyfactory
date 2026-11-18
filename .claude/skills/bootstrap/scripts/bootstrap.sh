#!/usr/bin/env bash
# Runs the whole bootstrap in order, in the current directory. This is what `npx factory <name>`
# will wrap. Each step is safe to re-run, so after fixing a failure just run this again.
# It opens the purpose interview (what are we building, and its mission), then needs only browser
# approvals: the Neon sign-in, the board token, the workflow app, the Claude token, and two settings no API
# exposes (Vercel's preview retention and the board's automations).
# Usage: bootstrap.sh [name]   (name defaults to the directory name)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
name="${1:-$(basename "$PWD")}"

for step in preflight scaffold purpose github vercel database database-key sign-in preview-access board board-token workflow-app agent-token; do
  printf '\n== %s ==\n' "$step"
  "$here/$step.sh" "$name"
done
printf '\nbootstrap complete: %s\n' "$name"
