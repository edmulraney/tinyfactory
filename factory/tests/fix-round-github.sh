#!/usr/bin/env bash
# GitHub as it stands around a pull request whose checks failed, shared by the tests of the fix-round scripts.
# Usage: . "$(dirname "$0")/fix-round-github.sh"
#        Sourced after helpers.sh.

head=5555555555555555555555555555555555555555

# Pull request #7 (closing #12) with `checks` (job 30) failed in ci run 900; a scenario changes the $T file it is about.
checks_failed() {
  head=5555555555555555555555555555555555555555
  echo '{"state":"OPEN","author":{"login":"app/claude"},"headRefName":"feat/12-export-forecast-csv","baseRefName":"main","labels":[]}' > "$T/pull"
  echo MERGEABLE > "$T/mergeable"
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  echo '[{"databaseId":900,"attempt":1}]' > "$T/runs"
  echo completed > "$T/status"
  echo false > "$T/draft"
  echo '{"jobs":[{"id":30,"name":"checks","conclusion":"failure"},{"id":31,"name":"e2e","conclusion":"success"}]}' > "$T/jobs"
  printf '2026-11-16T08:00:00.1000000Z ##[group]Run pnpm lint\n2026-11-16T08:00:01.0000000Z src/page.tsx: unused variable\n2026-11-16T08:00:02.0000000Z ##[error]Process completed with exit code 1.\n' > "$T/log-30"
  echo "the end-to-end log" > "$T/log-31"
  echo '[{"id":1,"user":{"login":"repo-owner"},"body":"Looks good."}]' > "$T/comments.json"
  echo '{"labels":[{"name":"factory"},{"name":"in-progress"}]}' > "$T/labels"
  echo '[]' > "$T/reviews.json"
  echo '[{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files.json"
  echo '[]' > "$T/review-comments.json"
  echo "$ci_yml" > "$T/ci-yml"
  : > "$T/fail"
  : > "$T/fail-once"
  export head
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    while IFS= read -r words; do
      case "$*" in "$words"*) [ "$(grep -cF -- "gh $words" "$T/calls")" -gt 1 ] || { echo "gh: failed once: $*" >&2; exit 1; } ;; esac
    done < "$T/fail-once"
    case "$*" in
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;;
      "pr view 7 --json state,author,headRefOid,headRefName,labels "* | "pr view 7 --json headRefOid,baseRefName,mergeable "*)
        # Each is set on its own, with no brace list (decisions H121).
        json "$(jq --arg head "$head" --arg m "$(head -n 1 "$T/mergeable")" ".headRefOid = \$head | .mergeable = \$m" "$T/pull")" "$@"
        case "$*" in *mergeable*)
          if [ "$(wc -l < "$T/mergeable")" -gt 1 ]; then tail -n +2 "$T/mergeable" > "$T/mergeable.rest"; mv "$T/mergeable.rest" "$T/mergeable"; fi ;;
        esac ;;
      "pr view 7 --json isDraft,labels "*) json "$(jq --argjson draft "$(cat "$T/draft")" ".isDraft = \$draft" "$T/pull")" "$@" ;;
      "pr view 7 --json headRefOid "*) json "{\"headRefOid\":\"$head\"}" "$@" ;;
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/7/reviews?per_page=100 --paginate --jq "*) json "$(cat "$T/reviews.json")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/7/reviews/"*" --jq "*)
        id=${2##*/}; json "$(jq --argjson id "$id" ".[] | select(.id == \$id)" "$T/reviews.json")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/7/comments?per_page=100 --paginate --jq "*) json "$(cat "$T/review-comments.json")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/7/files --paginate --jq "*) json "$(cat "$T/files.json")" "$@" ;;
      "pr edit 7 --remove-label needs-human" | "pr edit 7 --remove-label needs-human --remove-label waits-for-main" | "issue edit 12 --remove-label needs-human --add-label in-progress") echo "https://github.example/7" ;;
      "run list --workflow ci.yml --commit $head --limit 20 --json databaseId,conclusion "* | "run list --workflow ci.yml --commit $head --limit 20 --json attempt,conclusion "*) json "$(cat "$T/runs")" "$@" ;;
      "run list --workflow ci.yml --commit $head --limit 20 --json databaseId,status,conclusion "* | "run view 900 --json status "*)
        case "$1 $2" in
          "run list") json "$(jq --arg s "$(head -n 1 "$T/status")" "map(. + {status: \$s})" "$T/runs")" "$@" ;;
          *) json "{\"status\":\"$(head -n 1 "$T/status")\"}" "$@" ;;
        esac
        if [ "$(wc -l < "$T/status")" -gt 1 ]; then tail -n +2 "$T/status" > "$T/status.rest"; mv "$T/status.rest" "$T/status"; fi ;;
      "api repos/owner/myapp/actions/runs/900/jobs --paginate "* | "api repos/{owner}/{repo}/actions/runs/900/jobs --paginate "*) json "$(cat "$T/jobs")" "$@" ;;
      "run rerun --job "*) : ;;
      "api repos/owner/myapp/actions/jobs/"*"/logs" | "api repos/owner/myapp/actions/jobs/"*"/logs --allow-escape-sequences")
        id=${2#*/jobs/}; id=${id%/logs}
        if [ -f "$T/log-$id.later" ] && [ "$(grep -c "jobs/$id/logs" "$T/calls")" -ge 3 ]; then cat "$T/log-$id.later"
        elif [ -f "$T/log-$id" ] && [ $# -eq 2 ] && grep -q "$(printf "\\033")" "$T/log-$id"; then
          echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2; exit 1
        elif [ -f "$T/log-$id" ]; then cat "$T/log-$id"
        else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
      "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq "*) json "$(cat "$T/comments.json")" "$@" ;;
      "api repos/{owner}/{repo}/contents/.github/workflows/ci.yml --jq "*) json "{\"sha\":\"$(cat "$T/ci-yml")\"}" "$@" ;;
      "issue view 12 --json labels "*) json "$(cat "$T/labels")" "$@" ;;
      "issue edit 12 --add-label needs-human --remove-label in-progress") echo "https://github.example/12" ;;
      "pr comment 7 --body "* | "issue comment 7 --body "* | "pr edit 7 --add-label needs-human") echo "https://github.example/7#comment" ;;
      "workflow run "*) echo "created workflow_dispatch event" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  # Waiting for a log, or for GitHub to work out a conflict, takes no time here.
  stub sleep ':'
}
# Sentences check-inventory.sh prints when the workflows on main had not settled.
edited_directly=".github/workflows/ci.yml was edited directly. Undo that and change factory/workflows/ci.yml: the installer copies it in once that merges."
never_installed="This check read main again every 10 seconds for 120 seconds, in case an install was on its way, and they still differ."
# What it prints for a run that is an install behind in its own workflow (decisions W134b).
stale_run=".github/workflows/ci.yml is an install behind main, where it now matches its source. Nothing was edited, but this run uses the workflow from before the install. Merge main into the branch and push, which starts a run with the workflow main holds: git fetch origin main && git merge origin/main"
not_settled() {
  printf '2026-11-16T15:37:55.1000000Z ##[group]Run pnpm lint\n2026-11-16T15:37:58.0000000Z %s\n2026-11-16T15:37:59.0000000Z ##[error]Process completed with exit code 1.\n' "${1:-$edited_directly}" > "$T/log-30"
}
# What workflow-behind.sh and post-verdict.sh print for a review with no verdict in a run behind main (decisions A142c).
review_behind=".github/workflows/ci.yml on main has changed since this run began: this run uses the workflow from before the install. Merge main into the branch and push, which starts a run with the workflow main holds: git fetch origin main && git merge origin/main"
reviews_behind() {
  echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":33,"name":"review","conclusion":"failure"},{"id":34,"name":"verdicts","conclusion":"failure"}]}' > "$T/jobs"
  printf '2026-11-17T09:00:00.1000000Z adam: ended with no verdict that can be posted\n2026-11-17T09:00:01.0000000Z ##[error]Process completed with exit code 1.\n' > "$T/log-33"
  printf '2026-11-17T09:00:00.1000000Z adam: Adam (architecture and taste): not reviewed. %s\n2026-11-17T09:00:00.2000000Z ryan: Ryan (correctness): not reviewed. %s\n2026-11-17T09:00:01.0000000Z ##[error]Process completed with exit code 1.\n' "$review_behind" "$review_behind" > "$T/log-34"
}
# The id git gives the ci.yml main holds, which a fresh-run round's comment records (decisions A142b).
ci_yml=cccccccccccccccccccccccccccccccccccccccc
fresh_run_round() { echo "{\"id\":3,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:fresh-run-round ${1:-$ci_yml} -->The fix round for a fresh run\"}"; }
in_conflict() { echo CONFLICTING > "$T/mergeable"; }
# left_out <comment>: merge-queue.sh removed it from those that wait to merge, at its head, with that comment (decisions M455d).
left_out() {
  jq --arg body "<!-- factory:merge-queue removed $head -->$1" '. + [{id: 90, user: {login: "github-actions[bot]"}, body: $body}]' "$T/comments.json" > "$T/comments.new"
  mv "$T/comments.new" "$T/comments.json"
}
# Its engineer found that what failed lies outside it, and labelled it (decisions A368a).
waits_for_main() { jq '.labels = [{name: "needs-human"}, {name: "waits-for-main"}]' "$T/pull" > "$T/pull.new" && mv "$T/pull.new" "$T/pull"; }
nothing_failed() { echo '{"jobs":[{"id":30,"name":"checks","conclusion":"success"},{"id":31,"name":"e2e","conclusion":"success"}]}' > "$T/jobs"; }
# GitHub started no ci run for the head: it was pushed while it conflicted.
no_ci_run() { echo '[]' > "$T/runs"; }
# reviewed <id> <login> <state> [commit] [summary]: adds a review, of the head unless another commit is given.
reviewed() {
  jq --argjson id "$1" --arg login "$2" --arg state "$3" --arg commit "${4:-$head}" --arg body "${5:-}" \
    '. + [{id: $id, user: {login: $login}, state: $state, commit_id: $commit, body: $body}]' "$T/reviews.json" > "$T/reviews.new"
  mv "$T/reviews.new" "$T/reviews.json"
}
sent_back() {
  reviewed 40 someone-else CHANGES_REQUESTED "$head" "Not the owner's."
  reviewed 41 repo-owner CHANGES_REQUESTED "$head" "Not like this: keep the old column order."
  echo '[{"pull_request_review_id":41,"path":"src/export.ts","line":12,"original_line":12,"body":"Dates first, as before."},
         {"pull_request_review_id":40,"path":"src/other.ts","line":3,"original_line":3,"body":"A comment of another review."}]' > "$T/review-comments.json"
}
