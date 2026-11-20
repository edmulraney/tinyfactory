#!/usr/bin/env bash
# Says whether what failed on a pull request is only that its ci run uses a ci.yml main no longer holds.
# Usage: needs-fresh-run.sh <pr-number> <failures-file>   (the file collect-failures.sh wrote)
#        Needs GH_TOKEN (contents and pull-requests: read).
#        Prints `true <id>`, the id being the one git gives main's installed ci.yml, or `false`.
#        A read GitHub does not answer stops it with a message and exit 1.
set -euo pipefail

usage="Usage: needs-fresh-run.sh <pr-number> <failures-file>"
pr="${1:?$usage}"; failures="${2:?$usage}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

[ -f "$failures" ] || die "There is no file $failures, so what failed on pull request #$pr is not known."

# In check-inventory.sh's sentence and workflow-behind.sh's (decisions W134b, A142c); needs-fresh-run.test.sh checks.
behind="this run uses the workflow from before the install"

# One heading per failed job or conflict: each must be such a job whose log holds the sentence, or an engineer has work.
only=$(awk -v sentence="$behind" '
  /^===== / {
    if (open && !found) other = 1
    # A failed `review` job says nothing of its own: `verdicts` runs after it and says why (decisions A427f).
    open = ($0 != "===== failed job: review =====")
    if (open) {
      jobs++; found = 0
      if ($0 != "===== failed job: checks =====" && $0 != "===== failed job: verdicts =====") other = 1
    }
    next
  }
  open && index($0, sentence) { found = 1 }
  END { if (open && !found) other = 1; if (jobs > 0 && !other) print "yes"; else print "no" }' "$failures")
if [ "$only" != yes ]; then
  echo false
  exit 0
fi

# Each answer is read on a line of its own, so a failed read stops the script (decisions H7).
workflow=$(gh api "repos/{owner}/{repo}/contents/.github/workflows/ci.yml" --jq .sha) \
  || die "Could not read the ci.yml main holds from GitHub, so whether pull request #$pr has had its fresh run for it is not known."
[[ "$workflow" =~ ^[0-9a-f]{40,64}$ ]] \
  || die "GitHub gave no id for the ci.yml main holds, so whether pull request #$pr has had its fresh run for it is not known."
before=$("$script_dir/fix-rounds.sh" "$pr" fresh-run "$workflow") \
  || die "The fix rounds for a fresh run of pull request #$pr could not be counted, so whether it has had one for the ci.yml main holds is not known."
# Once per ci.yml on main: a push gives a run with main's file, so a second failure is no install (decisions A142b).
if [ "$before" -eq 0 ]; then echo "true $workflow"; else echo false; fi
