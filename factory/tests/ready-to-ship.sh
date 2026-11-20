#!/usr/bin/env bash
# GitHub and production around a pull request that is ready to ship, for the ship, merge-gate and approve-merge tests.
# Usage: . ready-to-ship.sh   (after helpers.sh)
#        ready_to_ship                  pull request #7 closes #12, and its checks and reviews passed
#        ship [<pr>:<head>...]          ships a group the test passed whole: pull request #7 alone when none is named
#        found <result> <pr>:<head>...  what test-group.sh writes of pull requests it all found so, in $T/result.json;
#                                       each still waits to merge

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
  mkdir -p "$T/runs" "$T/artifacts" "$T/jobs" "$T/heads" "$T/pulls" "$T/trees"
  # What cut-rule-files.sh downloads: main holds one rule file, of three words, in its budget of 50.
  mkdir -p "$T/on-main/repo/factory"
  echo "50 TASTE.md" > "$T/on-main/repo/factory/rule-files.txt"
  echo "What good means." > "$T/on-main/repo/TASTE.md"
  echo "$main" > "$T/main"
  echo '[{"databaseId":900,"status":"completed","conclusion":"success"}]' > "$T/runs/$head"
  # What button-merge.sh reads: the commit of main the checks of the run passed with (decisions M19).
  echo "{\"artifacts\":[{\"name\":\"playwright-$head\"},{\"name\":\"tested-with-main-$main\"}]}" > "$T/artifacts/900"
  echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":32,"name":"merge","conclusion":"success"}]}' > "$T/jobs/900"
  echo '[]' > "$T/open.json"
  : > "$T/flaky"
  echo MERGED > "$T/state"
  echo '[]' > "$T/statuses.json"
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
      # Who merged it: $T/merged-by holds the login, a person unless a scenario names the token of the workflows.
      "pr view 7 --json state,mergedBy"*) echo "{\"state\":\"$(cat "$T/state")\",\"mergedBy\":{\"login\":\"$(cat "$T/merged-by" 2>/dev/null || echo repo-owner)\"},\"mergeCommit\":{\"oid\":\"$merged\"}}" ;;
      "pr view 7 --json state,author,mergedBy,comments") jq --arg state "$(cat "$T/state")" --arg author "$(cat "$T/author" 2>/dev/null || echo app/claude)" --arg by "$(cat "$T/merged-by" 2>/dev/null || echo repo-owner)" ". + {state: \$state, author: {login: \$author}, mergedBy: {login: \$by}}" "$T/comments" ;;
      # What revert.sh reads and files to take #7 back: $T/tickets.json holds the tickets filed since the merge, and the next is #30.
      "api graphql -F owner={owner} -F name={repo} -F number=7 "*) json "{\"data\":{\"repository\":{\"issueOrPullRequest\":{\"__typename\":\"PullRequest\",\"number\":7}}}}" "$@" ;;
      "pr view 7 --json state,mergeCommit,mergedAt,title") echo "{\"state\":\"$(cat "$T/state")\",\"mergeCommit\":{\"oid\":\"$merged\"},\"mergedAt\":\"2026-11-16T09:00:00Z\",\"title\":\"feat: export forecast as CSV\"}" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f since=2026-11-16T09:00:00Z "*) json "$(cat "$T/tickets.json" 2>/dev/null || echo "[]")" "$@" ;;
      "issue create --title "*) echo "https://github.com/owner/myapp/issues/30" ;;
      "api repos/{owner}/{repo}/tarball/main") tar -cz -C "$T/on-main" repo ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 "*) json "[]" "$@" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f labels=factory -f since="*) json "[]" "$@" ;;
      "pr view 7 --json headRefOid,mergeCommit") echo "{\"headRefOid\":\"$head\",\"mergeCommit\":{\"oid\":\"$merged\"}}" ;;
      "api repos/{owner}/{repo}/commits/$merged "*) json "{\"parents\":[{\"sha\":\"$(cat "$T/main")\"}]}" "$@" ;;
      # What the merge gate reads of a ticket that takes back pull request #5: $T/ticket-author holds who filed #12, a person
      # unless a scenario names the token of the workflows, and $T/taken.json who merged #5 and as which commit.
      "issue view 12 --json title,author") echo "{\"title\":\"$(cat "$T/title" 2>/dev/null || echo "Export forecast as CSV")\",\"author\":{\"login\":\"$(cat "$T/ticket-author" 2>/dev/null || echo repo-owner)\"}}" ;;
      "pr view 5 --json mergedBy,mergeCommit") cat "$T/taken.json" ;;
      "pr view 7 --json mergeCommit "*) json "{\"mergeCommit\":{\"oid\":\"$merged\"}}" "$@" ;;
      # Another pull request of a group: $T/pulls/<n> holds its ticket, and its merge commit is its number forty times.
      "pr view "[89]" --json body "*) json "{\"body\":\"Closes #$(cat "$T/pulls/$3")\"}" "$@" ;;
      "pr view "[89]" --json mergeCommit "*) json "{\"mergeCommit\":{\"oid\":\"$(printf "$3%.0s" $(seq 40))\"}}" "$@" ;;
      "pr view "[89]" --json author "*) json "{\"author\":{\"login\":\"$(cat "$T/author-$3" 2>/dev/null || echo app/claude)\"}}" "$@" ;;
      "pr view "[89]" --json state "*) json "{\"state\":\"MERGED\"}" "$@" ;;
      "pr view "[89]" --json number,"*) echo "gh: no such pull request in the record" >&2; exit 1 ;;
      "issue view 1"[34]" --json title "*) json "{\"title\":\"Another ticket\"}" "$@" ;;
      "api repos/owner/myapp/pulls/"[89]"/files "* | "api repos/{owner}/{repo}/pulls/"[89]"/files "*) n=${2#*/pulls/}; json "$(cat "$T/files-${n%/files}.json" 2>/dev/null || cat "$T/files.json")" "$@" ;;
      "pr merge "[89]" "*) if [ -f "$T/merge" ]; then . "$T/merge"; fi ;;
      "issue edit 1"[34]" "* | "issue close 1"[34] | "issue comment 1"[34]" "*) ;;
      # The git tree of a commit, for the comparison with what was tested: $T/trees/<commit> when a scenario wrote one.
      "api repos/{owner}/{repo}/commits/"*" --jq .commit.tree.sha") json "{\"commit\":{\"tree\":{\"sha\":\"$(cat "$T/trees/${2##*/}" 2>/dev/null || echo "no tree was given for ${2##*/}")\"}}}" "$@" ;;
      "pr view 7 --json comments "*) json "$(cat "$T/comments")" "$@" ;;
      "pr view 7 --json author "*) json "{\"author\":{\"login\":\"$(cat "$T/author" 2>/dev/null || echo app/claude)\"}}" "$@" ;;
      "pr view 7 --json baseRefName "*) json "{\"baseRefName\":\"main\"}" "$@" ;;
      "pr view 7 --json state,headRefOid,reviews") cat "$T/view.json" ;;
      "pr view 7 --json reviews,comments") jq -s ".[0] + .[1]" "$T/view.json" "$T/comments" ;;
      "pr view 7 --json number,"*) json "{\"number\":7,\"title\":\"feat: export forecast as CSV\",\"headRefName\":\"feat/12-export-forecast-csv\",\"state\":\"MERGED\",\"mergedAt\":\"2026-11-16T09:00:00Z\",\"labels\":[],\"comments\":[]}" "$@" ;;
      "run list --workflow ci.yml --branch "*) json "[]" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs -f branch=feat/12-export-forecast-csv "*) json "{\"workflow_runs\":[{\"id\":900}]}" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/runs/900/jobs -f filter=all "*)
        json "{\"jobs\":[{\"run_id\":900,\"conclusion\":\"success\",\"started_at\":\"2026-11-16T08:40:00Z\",\"completed_at\":\"2026-11-16T08:43:30Z\",\"runner_id\":1000000001}]}" "$@" ;;
      "api repos/{owner}/{repo}/issues/12/events?per_page=100 "*) json "[{\"event\":\"labeled\",\"label\":{\"name\":\"ready\"},\"created_at\":\"2026-11-16T08:30:00Z\"}]" "$@" ;;
      "api repos/{owner}/{repo}/issues/7/events?per_page=100 "*) json "[]" "$@" ;;
      # What start-waiting.sh reads: $T/ready.json holds the tickets that wait with ready, and nothing else is in flight.
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100 "*) json "$(cat "$T/ready.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "[]" "$@" ;;
      # GitHub still lists as open the ticket this merge closed.
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 "*) json "[{\"number\":12}]" "$@" ;;
      # What start-retests.sh reads of a pull request its owner may have sent back: $T/reviews-<n> holds its reviews.
      "api repos/{owner}/{repo}/pulls/"*"/reviews?per_page=100 "*) n=${2#*/pulls/}; json "$(cat "$T/reviews-${n%/reviews*}" 2>/dev/null || echo "[]")" "$@" ;;
      # The open pull requests as start-retests.sh lists them, which are those labelled waits-for-main unless a scenario adds one.
      # What merge-queue.sh reads: $T/queue.json holds the pull requests that still wait to merge, each added at its head.
      "pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews "*) json "$(cat "$T/queue.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*"factory:merge-queue"*)
        n=${2#*/issues/}; n=${n%/comments*}
        records=$(jq --argjson n "$n" "[.[] | select(.number == \$n) | {id: 1, user: {login: \"github-actions[bot]\"}, body: (\"<!-- factory:merge-queue added \" + .headRefOid + \" -->It waits.\")}]" "$T/queue.json" 2>/dev/null || echo "[]")
        json "$records" "$@" ;;
      "pr list --state open --limit 100 --json number,author,labels,isDraft "*) json "$(cat "$T/marked.json" 2>/dev/null || echo "[]")" "$@" ;;
      "pr list --state open --limit 100 "*) echo "[]" ;;
      "api repos/{owner}/{repo}/issues/"*"/events?per_page=100 "*) json "[{\"id\":1,\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}}]" "$@" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f since=2026-11-16T08:30:00Z "*) json "$(cat "$T/issues.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api repos/{owner}/{repo}/git/"*) sessions_on_github "$@" ;;
      "issue comment 12 "*) ;;
      "issue view 12 --json title "*) json "{\"title\":\"$(cat "$T/title" 2>/dev/null || echo "Export forecast as CSV")\"}" "$@" ;;
      "pr view 5 --json body "*) json "{\"body\":\"Closes #3\"}" "$@" ;;
      "issue reopen 3" | "issue edit 3 --add-label reverted "* | "issue comment 3 "*) ;;
      "issue view 12 --json body "*) json "$(jq -Rs "{body: .}" "$T/ticket-body" 2>/dev/null || echo "{\"body\":\"\"}")" "$@" ;;
      "pr view 7 --json state "*) json "{\"state\":\"$(cat "$T/state")\"}" "$@" ;;
      "issue view 12 --json labels "*) json "{\"labels\":$(cat "$T/labels.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "api repos/{owner}/{repo}/commits?sha=main&per_page=30 "*) json "$(cat "$T/log.json")" "$@" ;;
      # Vercel skipped the commit $T/skipped-commit names, as $T/skipped-statuses.json says.
      "api repos/{owner}/{repo}/commits/"*"/statuses "*)
        commit=${2%/statuses}
        if [ "${commit##*/}" = "$(cat "$T/skipped-commit" 2>/dev/null)" ]; then json "$(cat "$T/skipped-statuses.json")" "$@"; else json "$(cat "$T/statuses.json")" "$@"; fi ;;
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
      # What rerun-refused.sh reads: $T/latest-runs.json holds the latest runs, newest first, $T/first-jobs/<run>
      # the jobs of the first attempt of a run and $T/annotations/<job> what GitHub said of a job.
      "api --method GET repos/{owner}/{repo}/actions/runs -f created=>="*) json "{\"workflow_runs\":$(cat "$T/latest-runs.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "api repos/{owner}/{repo}/actions/runs/"*"/attempts/1/jobs?per_page=100 "*) n=${2#*/runs/}; json "{\"jobs\":$(cat "$T/first-jobs/${n%/attempts*}")}" "$@" ;;
      "api repos/{owner}/{repo}/check-runs/"*"/annotations?per_page=100 "*) n=${2#*/check-runs/}; json "$(jq -Rs "[{message: .}]" "$T/annotations/${n%/annotations*}")" "$@" ;;
      "run rerun "*" --failed") ;;
      "pr list --state merged --label proof "*) json "$(cat "$T/waiting.json" 2>/dev/null || echo "[]")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/"*"/runs "*) json "{\"workflow_runs\":$(cat "$T/first-runs.json" 2>/dev/null || echo "[]")}" "$@" ;;
      "repo view "*) json "{\"nameWithOwner\":\"owner/myapp\"}" "$@" ;;
      "api repos/owner/myapp/pulls/7/files "* | "api repos/{owner}/{repo}/pulls/7/files "*) json "$(cat "$T/files.json")" "$@" ;;
      "pr merge 7 "*) if [ -f "$T/merge" ]; then . "$T/merge"; fi ;;
      "pr edit "* | "issue edit 12 "* | "issue close 12" | "pr comment "* | "workflow run "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub curl 'cat "$T/health" 2>/dev/null || { echo "curl: (7) could not connect" >&2; exit 7; }'
# The clock jumps 400 seconds at each read and sleep takes no time, so a ten-minute wait that fails ends at once.
  stub sleep ':'
  stub date 'now=$(cat "$T/clock" 2>/dev/null || echo 1000); echo $((now + 400)) > "$T/clock"; echo "$now"'
}
# found <result> <pr>:<head>...
found() {
  local result="$1"
  shift
  jq -n --arg main "$main" --arg result "$result" \
    '{main: $main, tree: "", pulls: [$ARGS.positional[] | split(":") | {number: (.[0] | tonumber), head: .[1], result: $result}]}' \
    --args "$@" > "$T/result.json"
  jq '[.pulls[] | {number, headRefOid: .head, isDraft: false, reviews: []}]' "$T/result.json" > "$T/queue.json"
}
# no_longer_waits <number>: its owner sent it back, or it was pushed to, after the group was begun.
no_longer_waits() { jq --argjson n "$1" 'map(select(.number != $n))' "$T/queue.json" > "$T/queue.new" && mv "$T/queue.new" "$T/queue.json"; }
ship() {
  [ $# -gt 0 ] || set -- "7:$head"
  found passed "$@"
  run "$scripts/ship.sh" "$T/result.json" "$@"
}
# also_ships <number> <ticket>: another pull request of the group, which closes that ticket; sets $head_<number>.
also_ships() {
  echo "$2" > "$T/pulls/$1"
  printf -v "head_$1" '%s' "$(printf "${1}a%.0s" $(seq 20))"
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
# The record of measures as GitHub holds it, or nothing.
recorded() { git --git-dir="$T/github/owner/myapp.git" show sessions:measures.jsonl 2>/dev/null; }
# also_open <number> <who opened it> <mergeable>: its ci run is <number>00.
also_open() {
  local sha
  sha=$(printf "$1%.0s" $(seq 40)); sha=${sha:0:40}
  echo "$sha" > "$T/heads/$1"
  echo "[{\"databaseId\":${1}00,\"status\":\"completed\"}]" > "$T/runs/$sha"
  echo "{\"jobs\":[{\"id\":${1}0,\"name\":\"checks\"}]}" > "$T/jobs/${1}00"
  jq --argjson n "$1" --arg login "$2" --arg m "$3" --arg sha "$sha" '. + [{number: $n, mergeable: $m, author: {login: $login}, headRefOid: $sha}]' "$T/open.json" > "$T/open.new"
  mv "$T/open.new" "$T/open.json"
}
