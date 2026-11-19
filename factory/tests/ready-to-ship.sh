#!/usr/bin/env bash
# GitHub and production around a pull request that is ready to ship, for the ship, merge-gate and approve-merge tests.
# Usage: . ready-to-ship.sh   (after helpers.sh)
. "$(dirname "${BASH_SOURCE[0]}")/overtaking.sh"

head=5555555555555555555555555555555555555555
merged=abcdef0123456789abcdef0123456789abcdef01
main=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
older=0000000000000000000000000000000000000001

# Pull request #7 closes #12, in a repo that holds an app; each scenario changes the one $T file it is about, which the gh stand-in below reads.
ready_to_ship() {
  mkdir -p apps
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  echo '[{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files.json"
  echo '{"comments":[{"body":"Looks good."}]}' > "$T/comments"
  echo '[{"id":1,"user":{"login":"repo-owner"},"body":"Looks good."}]' > "$T/rounds"
  echo "{\"commit\":\"$merged\"}" > "$T/health"
  : > "$T/fail"
  mkdir -p "$T/runs" "$T/artifacts" "$T/jobs" "$T/heads"
  echo "$main" > "$T/main"
  echo '[{"databaseId":900,"status":"completed","conclusion":"success"}]' > "$T/runs/$head"
  echo "{\"artifacts\":[{\"name\":\"playwright-$head\"},{\"name\":\"tested-with-main-$main\"}]}" > "$T/artifacts/900"
  echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":31,"name":"fits-main","conclusion":"skipped"},{"id":32,"name":"merge","conclusion":"success"}]}' > "$T/jobs/900"
  echo '[]' > "$T/open.json"
  : > "$T/flaky"
  echo MERGED > "$T/state"
  echo '[]' > "$T/statuses.json"
  echo apps/web/src/app/page.tsx > "$T/diff"
  printf 'diff --git a/apps/web/src/app/page.tsx b/apps/web/src/app/page.tsx\n--- a/apps/web/src/app/page.tsx\n+++ b/apps/web/src/app/page.tsx\n@@ -1 +1 @@\n-one\n+two\n' > "$T/patch"
  # What ticket-cost.sh reads: one reviewer's session, and ticket #12 made `ready` 30 minutes before the merge.
  mkdir -p "$T/sessions/pr-7"
  echo '[{"type":"system","subtype":"init","model":"claude-fable-5-2"},{"type":"result","total_cost_usd":1.5,"num_turns":9}]' > "$T/sessions/pr-7/20261116T080000Z-adam-run900.json"
  echo "{\"state\":\"OPEN\",\"headRefOid\":\"$head\",\"reviews\":[{\"author\":{\"login\":\"repo-owner\"},\"state\":\"APPROVED\",\"commit\":{\"oid\":\"$head\"}}]}" > "$T/view.json"
  # Neither is #7's squash commit: one only mentions it below its title, one reverts it.
  jq -n '[{sha: "1111111111111111111111111111111111111111", commit: {message: "feat: something else (#17)\n\nFollows (#7)"}},
          {sha: "2222222222222222222222222222222222222222", commit: {message: "Revert \"feat: export forecast as CSV (#7)\""}}]' > "$T/log.json"
  # What measures.sh pushes to: git sends the address of owner/myapp on GitHub to this repository, which has no branch yet.
  git init --quiet --bare --initial-branch main "$T/github/owner/myapp.git"
  printf '[url "file://%s/github/"]\n  insteadOf = https://x-access-token:workflow-token@github.com/\n' "$T" > "$T/gitconfig"
  export GIT_CONFIG_GLOBAL="$T/gitconfig"
  export merged head
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    while read -r times words; do
      case "$*" in "$words"*)
        if [ "$(grep -cxF -- "gh $*" "$T/calls")" -le "$times" ]; then echo "gh: HTTP 502: Bad Gateway: $*" >&2; exit 1; fi ;;
      esac
    done < "$T/flaky"
    case "$*" in
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "pr view 7 --json mergeCommit "*) json "{\"mergeCommit\":{\"oid\":\"$merged\"}}" "$@" ;;
      "pr view 7 --json comments "*) json "$(cat "$T/comments")" "$@" ;;
      "pr view 7 --json author "*) json "{\"author\":{\"login\":\"$(cat "$T/author" 2>/dev/null || echo app/claude)\"}}" "$@" ;;
      "pr view 7 --json baseRefName "*) json "{\"baseRefName\":\"main\"}" "$@" ;;
      "pr view 7 --json state,headRefOid,reviews") cat "$T/view.json" ;;
      "pr view 7 --json reviews,comments") jq -s ".[0] + .[1]" "$T/view.json" "$T/comments" ;;
      "pr view 7 --json number,"*) json "{\"number\":7,\"title\":\"feat: export forecast as CSV\",\"headRefName\":\"feat/12-export-forecast-csv\",\"state\":\"MERGED\",\"mergedAt\":\"2026-11-16T09:00:00Z\",\"labels\":[],\"comments\":[]}" "$@" ;;
      "run list --workflow ci.yml --branch "*) json "[]" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs -f branch=feat/12-export-forecast-csv "*) json "{\"workflow_runs\":[{\"id\":900}]}" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs/900/jobs -f filter=all "*)
        json "{\"jobs\":[{\"run_id\":900,\"conclusion\":\"success\",\"started_at\":\"2026-11-16T08:40:00Z\",\"completed_at\":\"2026-11-16T08:43:30Z\"}]}" "$@" ;;
      "api repos/{owner}/{repo}/issues/12/events?per_page=100 "*) json "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-16T08:30:00Z\"}]" "$@" ;;
      "api repos/{owner}/{repo}/issues/7/events?per_page=100 "*) json "[]" "$@" ;;
      # What start-waiting.sh reads: $T/ready.json holds the tickets that wait with ready, and nothing else is in flight.
      "api repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100 "*) json "$(cat "$T/ready.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "[]" "$@" ;;
      # GitHub still lists as open the ticket this merge closed.
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 "*) json "[{\"number\":12}]" "$@" ;;
      # The pull requests labelled waits-for-main, as start-retests.sh lists them; nothing else is in flight.
      "pr list --state open --limit 100 --json number,author,labels,isDraft "*) json "$(cat "$T/marked.json" 2>/dev/null || echo "[]")" "$@" ;;
      "pr list --state open --limit 100 "*) echo "[]" ;;
      "api repos/{owner}/{repo}/issues/"*"/events?per_page=100 "*) json "[{\"id\":1,\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}}]" "$@" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f since=2026-11-16T08:30:00Z "*) json "$(cat "$T/issues.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/git/"*) sessions_on_github "$@" ;;
      "issue comment 12 "*) ;;
      "issue view 12 --json title "*) json "{\"title\":\"$(cat "$T/title" 2>/dev/null || echo "Export forecast as CSV")\"}" "$@" ;;
      "pr view 5 --json body "*) json "{\"body\":\"Closes #3\"}" "$@" ;;
      "issue reopen 3" | "issue edit 3 --add-label reverted --remove-label deployed" | "issue comment 3 "*) ;;
      "pr view 7 --json state "*) json "{\"state\":\"$(cat "$T/state")\"}" "$@" ;;
      "pr diff 7 --name-only") cat "$T/diff" ;;
      "pr diff 7") cat "$T/patch" ;;
      "issue view 12 --json labels "*) json "{\"labels\":$(cat "$T/labels.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "api repos/{owner}/{repo}/commits?sha=main&per_page=30 "*) json "$(cat "$T/log.json")" "$@" ;;
      "api repos/{owner}/{repo}/commits/"*"/statuses "*) json "$(cat "$T/statuses.json")" "$@" ;;
      "pr view 7 --json headRefOid "*) json "{\"headRefOid\":\"$head\"}" "$@" ;;
      "api repos/{owner}/{repo}/issues/7/comments?per_page=100 "*) json "$(cat "$T/rounds")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 "*) n=${2#*/issues/}; json "$(cat "$T/rounds-${n%/comments*}" 2>/dev/null || echo "[]")" "$@" ;;
      "pr view "*" --json headRefOid "*) json "{\"headRefOid\":\"$(cat "$T/heads/$3")\"}" "$@" ;;
      "pr view "*" --json isDraft,labels "*) json "{\"isDraft\":$(grep -qx "$3" "$T/drafts" 2>/dev/null && echo true || echo false),\"labels\":$(jq -c --argjson n "$3" "[.[] | select(.number == \$n) | .labels[]]" "$T/marked.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "api repos/{owner}/{repo}/commits/main "*) json "{\"sha\":\"$(cat "$T/main")\"}" "$@" ;;
      "run list --workflow ci.yml --commit "*) json "$(cat "$T/runs/$6" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/"*"/artifacts "*) n=${2#*/runs/}; json "$(cat "$T/artifacts/${n%/artifacts}")" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/"*"/jobs "*) n=${2#*/runs/}; json "$(cat "$T/jobs/${n%/jobs}")" "$@" ;;
      "pr list --state open --base main "*)
        # GitHub works out `mergeable` after a merge: $T/unknown holds how many answers come first
        # in which it does not know yet.
        remaining=$(cat "$T/unknown" 2>/dev/null || echo 0)
        if [ "$remaining" -gt 0 ]; then
          echo $((remaining - 1)) > "$T/unknown"
          json "$(jq "map(.mergeable = \"UNKNOWN\")" "$T/open.json")" "$@"
        else
          json "$(cat "$T/open.json")" "$@"
        fi ;;
      "run rerun --job "*) ;;
      "pr list --state merged --label proof "*) json "$(cat "$T/waiting.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/"*"/runs "*) json "{\"workflow_runs\":$(cat "$T/first-runs.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "repo view "*) json "{\"nameWithOwner\":\"owner/myapp\"}" "$@" ;;
      "api repos/owner/myapp/pulls/7/files "* | "api repos/{owner}/{repo}/pulls/7/files "*) json "$(cat "$T/files.json")" "$@" ;;
      "api repos/{owner}/{repo}/compare/"* | "api --method GET repos/{owner}/{repo}/contents/factory/workflows "* | "api --method GET repos/{owner}/{repo}/commits "*) git_as_github "$@" ;;
      "pr merge 7 "*) if [ -f "$T/merge" ]; then . "$T/merge"; fi ;;
      "pr edit "* | "issue edit 12 "* | "issue close 12" | "pr comment "* | "workflow run "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub curl 'cat "$T/health" 2>/dev/null || { echo "curl: (7) could not connect" >&2; exit 7; }'
# The clock jumps 400 seconds at each read and sleep takes no time, so a ten-minute wait that fails ends at once.
  stub sleep ':'
  stub date 'now=$(cat "$T/clock" 2>/dev/null || echo 1000); echo $((now + 400)) > "$T/clock"; echo "$now"'
}
tested_with_an_older_main() {
  echo "{\"artifacts\":[{\"name\":\"tested-with-main-$older\"}]}" > "$T/artifacts/900"
}
# A merge call that "failed" can leave this on main: a scenario writes $put_on_main into $T/merge for that.
# shellcheck disable=SC2016
put_on_main='jq --arg sha "$merged" "[{sha: \$sha, commit: {message: \"feat: export forecast as CSV (#7)\n\nThe forecast exports as CSV.\"}}] + ." "$T/log.json" > "$T/log.new" && mv "$T/log.new" "$T/log.json"'
on_main() { eval "$put_on_main"; }
# verdict <reviewer> <review JSON>: the real post-verdict.sh writes it, so a change there fails its readers' tests.
verdict() {
  OUTPUT="$2" RUNNER_TEMP="$T/tmp" "$scripts/post-verdict.sh" "$1" 7 > /dev/null || true
  jq --rawfile body "$T/tmp/verdict.md" '.comments += [{body: $body}]' "$T/comments" > "$T/comments.new"
  mv "$T/comments.new" "$T/comments"
  rm "$T/tmp/verdict.md"
  : > "$T/calls"
}
# shellcheck disable=SC2034
round='{"id":2,"user":{"login":"github-actions[bot]"},"body":"<!-- factory:fix-round -->Fix round 1 of 3"}'
# How many times something was called, by the first words of the call.
# The record of measures as GitHub holds it, or nothing.
recorded() { git --git-dir="$T/github/owner/myapp.git" show sessions:measures.jsonl 2>/dev/null; }
calls() { grep -cF -- "$1" "$T/calls" || true; }
expect_calls() {
  [ "$(calls "$2")" = "$1" ] || fail "expected $1 of the call, got $(calls "$2"): $2"
}
# also_open <number> <who opened it> <mergeable>: its ci run is <number>00, whose fits-main is job <number>1.
also_open() {
  local sha
  sha=$(printf "$1%.0s" $(seq 40)); sha=${sha:0:40}
  echo "$sha" > "$T/heads/$1"
  echo "[{\"databaseId\":${1}00,\"status\":\"completed\"}]" > "$T/runs/$sha"
  echo "{\"jobs\":[{\"id\":${1}0,\"name\":\"checks\"},{\"id\":${1}1,\"name\":\"fits-main\"}]}" > "$T/jobs/${1}00"
  jq --argjson n "$1" --arg login "$2" --arg m "$3" --arg sha "$sha" '. + [{number: $n, mergeable: $m, author: {login: $login}, headRefOid: $sha}]' "$T/open.json" > "$T/open.new"
  mv "$T/open.new" "$T/open.json"
}
