#!/usr/bin/env bash
# Says which checks a change can affect, as `app=` and `factory=` lines, each `true` or `false`, alone on stdout.
# Usage: checks-needed.sh <commit-of-main>   (in a checkout that holds that commit and the change merged with it)
set -euo pipefail

main="${1:?Usage: checks-needed.sh <commit-of-main>}"
# The root's three package files are what every check is run with, so they count as both (decisions H268b).
both='package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$'
# What the app is built from, as needs-e2e.sh has it (decisions M75a, M165a), and the shared actions its checks are set up by (H268b).
app="^(apps/|packages/|\.github/actions/|$both)"
factory="^(factory/|\.claude/|\.github/|$both)"

emit() { echo "$3" >&2; echo "app=$1"; echo "factory=$2"; exit 0; }

# A read that fails runs every check, and the exit is still 0 (decisions H268c).
# No renames, so a moved file is listed under both its names: one moved out of the app changes the app too.
# Paths as they are: git would put one with a letter outside ASCII in quotes, and it would match neither list.
files=$(git -c core.quotePath=false diff --name-only --no-renames "$main" HEAD) \
  || emit true true "Could not read the files changed since $main from git, so every check runs."

needs_app=false
needs_factory=false
if changed=$(grep -E -m 1 "$app" <<<"$files"); then
  needs_app=true
  message="It changes what the app is built from ($changed), so typecheck, the app's tests and its build run."
else
  message="It changes nothing the app is built from, so typecheck, the app's tests and its build are skipped."
fi
if changed=$(grep -E -m 1 "$factory" <<<"$files"); then
  needs_factory=true
  message+=" It changes the factory ($changed), so the factory's tests run."
else
  message+=" It changes nothing of the factory's, so the factory's tests are skipped."
fi
emit "$needs_app" "$needs_factory" "$message"
