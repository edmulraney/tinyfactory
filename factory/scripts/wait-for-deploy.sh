#!/usr/bin/env bash
# Waits until a deployment reports that it is running a given commit, by polling its health endpoint.
# Usage: wait-for-deploy.sh <base-url> <commit-sha> [<later-commit-sha>...]
#        A later commit holds the given one, so production running it counts as live too (decisions M597).
#        Exits 0 when the commit is live, 2 when its deployment was skipped, 1 after 10 minutes.
#        GH_TOKEN (statuses: read) is optional: without it a skipped deployment is waited for in full.
set -uo pipefail

url="${1%/}/api/health"; expected="$2"; shift 2; deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  actual=$(curl -fsS --max-time 10 "$url" 2>/dev/null | jq -r '.commit // empty' 2>/dev/null || true)
  if [ -n "$actual" ] && [[ " $expected $* " == *" $actual "* ]]; then
    echo "live: $url reports $actual"
    exit 0
  fi
  # Production never reports a commit Vercel skipped (decisions M33). A failed read is no answer: the wait goes on.
  skipped=$(gh api "repos/{owner}/{repo}/commits/$expected/statuses" --jq '
    [.[] | select(.context | startswith("Vercel"))] | group_by(.context) | map(.[0].description // "")
    | select(length > 0 and all(test("^skipped"; "i"))) | .[0]' 2>/dev/null || true)
  if [ -n "$skipped" ]; then
    echo "skipped: Vercel did not deploy $expected (\"$skipped\"), so $url will not report it"
    exit 2
  fi
  sleep 10
done
echo "timed out: $url reports '${actual:-nothing}', expected $expected" >&2
exit 1
