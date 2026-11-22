#!/usr/bin/env bash
# Says whether a pull request's end-to-end tests need to run, and why, as two lines on stdout.
# Usage: needs-e2e.sh <pr-number>   (needs GH_TOKEN and GITHUB_REPOSITORY)
#        Prints `run=true` or `run=false`, then `reason=<one sentence>`, and the sentence on stderr too.
set -euo pipefail

pr="${1:?Usage: needs-e2e.sh <pr-number>}"
# What the app is built from; nothing is built from the workspace's other packages (decisions M75a, M165a).
app='^(apps/|packages/|package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$)'
# GitHub lists at most this many of a pull request's files, so a list this long may be cut short.
max_files=3000

# The comment in ci.yml about skipped tests carries the reason (decisions M608).
emit() { echo "$2" >&2; echo "run=$1"; echo "reason=$2"; exit 0; }

# The folder is looked for beside the script, so the caller's folder changes nothing (decisions M501).
[ -d "$(dirname "$0")/../../apps" ] \
  || emit false "This repository holds no apps folder, so it has no end-to-end tests to run for pull request #$pr."

# A read that fails runs the tests, and the exit is still 0 (decisions M75b).
# A renamed file is listed under both its names: one moved out of the app changes the app too.
files=$(gh api "repos/${GITHUB_REPOSITORY:-}/pulls/$pr/files" --paginate \
  --jq '.[] | .filename, (.previous_filename // empty)') \
  || emit true "Could not read the files pull request #$pr changes from GitHub, so its end-to-end tests run."

if [ "$(grep -c . <<<"$files" || true)" -ge "$max_files" ]; then
  emit true "Pull request #$pr changes $max_files files or more, and GitHub lists no more than that, so its end-to-end tests run."
fi
if changed=$(grep -E -m 1 "$app" <<<"$files"); then
  emit true "Pull request #$pr changes app code ($changed), so its end-to-end tests run."
fi
emit false "Pull request #$pr changes no app code, so the app in its preview is the app on main."
