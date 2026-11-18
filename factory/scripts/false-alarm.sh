#!/usr/bin/env bash
# Says whether what failed on a pull request is only `checks`, because the workflows on main had not settled.
# Usage: false-alarm.sh <pr-number> <failures-file>   (the file collect-failures.sh wrote)
#        Needs GH_TOKEN (actions and pull-requests: read).
#        Prints `true` or `false`. A read GitHub does not answer stops it with a message and exit 1.
set -euo pipefail

pr="${1:?Usage: false-alarm.sh <pr-number> <failures-file>}"; failures="${2:?Usage: false-alarm.sh <pr-number> <failures-file>}"

die() { echo "$1" >&2; exit 1; }

[ -f "$failures" ] || die "There is no file $failures, so what failed on pull request #$pr is not known."

# As check-inventory.sh prints them (false-alarm.test.sh checks it); its third is for an engineer (decisions W134b).
edited="was edited directly. Undo that and change"
never_installed="in case an install was on its way, and they still differ."

# Each failed job and a conflict has one heading in the file.
if [ "$(grep -c '^===== ' "$failures" || true)" != 1 ] \
  || ! grep -qxF '===== failed job: checks =====' "$failures" \
  || ! grep -qF -e "$edited" -e "$never_installed" "$failures"; then
  echo false
  exit 0
fi

# Each answer is read on a line of its own, so a failed read stops the script (decisions H7).
head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid) \
  || die "Could not read pull request #$pr from GitHub, so whether its checks have been run again is not known."
attempt=$("$(dirname "$0")/ci-run.sh" "$head" attempt) \
  || die "Could not list the ci runs for ${head:0:7}, the head of pull request #$pr, so whether its checks have been run again is not known."
# Only the first attempt: a second failure with the same sentence is no gap of a few seconds (decisions A134a, A134b).
if [ "$attempt" = 1 ]; then echo true; else echo false; fi
