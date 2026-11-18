#!/usr/bin/env bash
# Watches the factory for whoever drives it through a backlog, and exits when what it prints changes.
# Usage: watch.sh [seconds between looks, 60 if not given]
#        Needs GH_TOKEN and GH_REPO, or a checkout gh can read.
set -euo pipefail

die() { echo "$1" >&2; exit 1; }

interval="${1:-60}"
case "$interval" in
  "" | *[!0-9]*) die "Usage: watch.sh [seconds between looks]. \"$interval\" is not a number of seconds." ;;
esac

# look: sets $state, what it prints; $events, the lines whose change is an event; and $later (decisions H7, H120c).
look() {
  local waiting main flagged proposals proofs ended runs old failed="" slid=""
  waiting=$(gh pr list --state open --label needs-human --limit 100 --json number,title \
    --jq '.[] | "waiting for the owner: pull request #\(.number) \(.title)"') \
    || die "The pull requests waiting for the owner could not be read from GitHub, so the watch stopped. Run it again."
  # The commit main is at shows a merge and the install after it (decisions H120b).
  main=$(gh api "repos/{owner}/{repo}/commits/main" \
    --jq '"last merge: \(.sha[0:7]) \(.commit.message | split("\n")[0])"') \
    || die "The commit main is at could not be read from GitHub, so the watch stopped. Run it again."
  flagged=$(gh issue list --state open --label needs-human --limit 100 --json number,title \
    --jq '.[] | "flagged for a person: #\(.number) \(.title)"') \
    || die "The issues flagged for a person could not be read from GitHub, so the watch stopped. Run it again."
  proposals=$(gh issue list --state open --label proposal --limit 100 --json number,title \
    --jq '.[] | "to read when convenient: proposal #\(.number) \(.title)"') \
    || die "The proposals could not be read from GitHub, so the watch stopped. Run it again."
  proofs=$(gh issue list --state open --label proof --limit 100 --json number,title \
    --jq '.[] | "to read when convenient: proof ticket #\(.number) \(.title)"') \
    || die "The proof tickets could not be read from GitHub, so the watch stopped. Run it again."
  later=$(printf '%s\n%s\n' "$proposals" "$proofs" | grep -v '^$' || true)
  # Asked for one ending at a time, so that each keeps its own 20 newest (decisions H166).
  for ended in failure timed_out startup_failure; do
    runs=$(gh run list --status "$ended" --limit "$window" --json databaseId,workflowName,headBranch,displayTitle \
      --jq '.[] | "failed run: \(.databaseId) \(.workflowName) on \(.headBranch): \(.displayTitle)"') \
      || die "The runs that ended $ended could not be read from GitHub, so the watch stopped. Run it again."
    old="oldest_$ended"
    if [ -n "$first" ] && [ "$(grep -c . <<<"$runs" || true)" -ge "$window" ]; then
      printf -v "$old" '%s' "$(sed -n 's/^failed run: \([0-9]*\) .*/\1/p' <<<"$runs" | sort -n | head -n 1)"
    fi
    # An older run only slid in when one of the 20 left the list (decisions H120e).
    slid+=$(awk -v oldest="${!old:-}" 'oldest != "" && $3 + 0 < oldest + 0' <<<"$runs")$'\n'
    failed+="$runs"$'\n'
  done
  first=""
  # Sorted, so that the same things in another order are not a change; a run two endings list is one line.
  state=$(printf '%s\n%s\n%s\n%s\n' "$waiting" "$main" "$flagged" "$failed" | grep -v '^$' | sort -u)
  events=$(only "$state" "$slid")
}

# only <these lines> <those lines>: the lines of the first that the second does not hold.
only() { grep -vxF -e "$2" <<<"$1" || true; }

window=20
first=yes
state=""
events=""
later=""
look
before="$events"
printf '%s\n' "$state"
[ -z "$later" ] || printf '%s\n' "$later"
echo "watching: looking again every $interval seconds, until a line changes that is not one to read when convenient"

while [ "$events" = "$before" ]; do
  sleep "$interval"
  look
done

echo
echo "changed:"
new=$(only "$events" "$before")
gone=$(only "$before" "$state")
[ -z "$new" ] || sed 's/^/  new: /' <<<"$new"
[ -z "$gone" ] || sed 's/^/  gone: /' <<<"$gone"
echo
echo "now:"
printf '%s\n' "$state"
[ -z "$later" ] || printf '%s\n' "$later"
