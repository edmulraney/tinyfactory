#!/usr/bin/env bash
# Tests for revert.sh: files the ticket that takes a shipped one back and starts its build, and reopens it once merged.
. "$(dirname "$0")/helpers.sh"

commit=abcdef0123456789abcdef0123456789abcdef01

# Pull request #7 closed ticket #12 and merged as $commit. The next ticket GitHub files is #30, kept in $T/ticket.json.
# $T/fail holds one line per gh call, by its first words, that should fail; $T/flaky one that fails once.
shipped() {
  echo '{"__typename":"Issue","closedByPullRequestsReferences":{"nodes":[{"number":7,"merged":true,"mergedAt":"2026-11-16T09:00:00Z"}]}}' > "$T/what.json"
  echo "{\"state\":\"MERGED\",\"mergeCommit\":{\"oid\":\"$commit\"},\"mergedAt\":\"2026-11-16T09:00:00Z\",\"title\":\"feat: export forecast as CSV\"}" > "$T/view.json"
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  echo '[{"filename":"apps/web/page.txt"}]' > "$T/files.json"
  echo '[{"number":12,"title":"Export forecast as CSV","state":"closed","state_reason":"completed"}]' > "$T/issues.json"
  echo '{"title":"Take back pull request #7"}' > "$T/ticket.json"
  : > "$T/fail"
  : > "$T/flaky"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    while IFS= read -r words; do
      case "$*" in "$words"*)
        if [ "$(grep -cF -- "gh $words" "$T/calls")" -le 1 ]; then echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi ;;
      esac
    done < "$T/flaky"
    case "$*" in
      "api graphql -F owner={owner} -F name={repo} -F number="*) json "{\"data\":{\"repository\":{\"issueOrPullRequest\":$(cat "$T/what.json")}}}" "$@" ;;
      "pr view 7 --json state,mergeCommit,mergedAt,title") cat "$T/view.json" ;;
      "pr view 7 --json body "*) json "$(jq -Rs "{body: .}" "$T/body")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/issues -f state=all -f since=2026-11-16T09:00:00Z -f per_page=100 --paginate "*) json "$(cat "$T/issues.json")" "$@" ;;
      "api repos/{owner}/{repo}/pulls/7/files --paginate "*) json "$(cat "$T/files.json")" "$@" ;;
      "issue create --title "*)
        jq -n --arg title "$4" --arg label "$6" --arg ready "$8" --arg body "${10}" "{title: \$title, body: \$body, labels: [{name: \$label}, {name: \$ready}], createdAt: \"2026-11-18T09:00:00Z\"}" > "$T/ticket.json"
        cat "$T/url" 2>/dev/null || echo "https://github.com/owner/myapp/issues/30" ;;
      "issue view 30 --json title,body,labels,createdAt") cat "$T/ticket.json" ;;
      "issue view 30 --json title "*) json "$(cat "$T/ticket.json")" "$@" ;;
      "workflow run implement.yml -f issue=30" | "issue close 30 --reason not planned") ;;
      "issue reopen 12" | "issue edit 12 --add-label reverted --remove-label deployed" | "issue comment 12 "* | "pr comment 7 "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
}
start() { run env GH_TOKEN=workflow-token "$scripts/revert.sh" start "${1:-12}" "${2:-repo-owner}" repo-owner; }
merged() { run env GH_TOKEN=workflow-token "$scripts/revert.sh" shipped 30 31; }
filed() { jq -r "$1" "$T/ticket.json"; }
# Nothing changed: no ticket was filed, closed or touched, and no build was started.
expect_nothing_changed() {
  expect_output "Nothing was changed."
  expect_no_call "gh issue "
  expect_no_call "gh workflow run"
}

scenario "takes a ticket back: files a chore that reverts its commit, and starts the build of that ticket"
shipped
start 12
expect_status 0
expect_call "gh issue create --title Take back pull request #7 --label chore --label ready --body ## Change"
expect_call "Take back pull request #7 (\`feat: export forecast as CSV\`), which shipped ticket #12: the owner asked for it."
expect_call "run \`git revert --no-edit $commit\`, and change nothing else."
expect_call "resolve the conflict so that what later pull requests shipped stays and only what #7 shipped goes."
expect_call "## Docs to update"
expect_call "gh workflow run implement.yml -f issue=30"
expect_output "ticket #30 takes back pull request #7: its build was started, and Esme opens the pull request that reverts abcdef0"
expect_no_call "gh issue close"
expect_no_call "gh issue reopen"

scenario "the ticket it files passes the check every build begins with"
shipped
start 12
run env GH_TOKEN=workflow-token "$scripts/check-ticket.sh" 30
expect_status 0

scenario "a pull request that changed a path only a person may merge is a factory ticket, which Fred builds"
shipped
echo '[{"filename":"README.md"},{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
start 12
expect_status 0
expect_call "gh issue create --title Take back pull request #7 --label factory --label ready --body ## Change"
expect_call "## How we will know it works"
expect_output "and Fred opens the pull request"
run env GH_TOKEN=workflow-token "$scripts/check-ticket.sh" 30
expect_status 0

scenario "a file moved out of a protected path makes it a factory ticket too"
shipped
echo '[{"filename":"docs/ci.yml","previous_filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
start 12
expect_status 0
expect_call "--label factory"

scenario "a pull request that changed a workflow is taken back like any other"
shipped
echo '[{"filename":"factory/workflows/ci.yml"},{"filename":".claude/skills/bootstrap/scripts/labels.sh"}]' > "$T/files.json"
start 12
expect_status 0
expect_call "gh workflow run implement.yml -f issue=30"

scenario "takes a ticket back by its pull request's number"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
start "#7"
expect_status 0
expect_call "-F number=7 "
expect_call "gh issue create --title Take back pull request #7 "

scenario "takes back the newest merged pull request of a ticket shipped twice, never one that did not merge"
shipped
echo '{"__typename":"Issue","closedByPullRequestsReferences":{"nodes":[
  {"number":9,"merged":false,"mergedAt":null},
  {"number":7,"merged":true,"mergedAt":"2026-11-16T09:00:00Z"},
  {"number":5,"merged":true,"mergedAt":"2026-11-15T09:00:00Z"}]}}' > "$T/what.json"
start 12
expect_status 0
expect_call "gh pr view 7 --json state"
expect_no_call "gh pr view 5"
expect_no_call "gh pr view 9"

scenario "a pull request that closes no ticket is taken back, and its ticket names none"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
echo "A person's own pull request." > "$T/body"
start 7
expect_status 0
expect_call "Take back pull request #7 (\`feat: export forecast as CSV\`): the owner asked for it."
expect_no_call "which shipped ticket"

scenario "refuses a run the owner did not start, before asking GitHub anything"
shipped
start 12 "github-actions[bot]"
expect_status 1
expect_output "Not started: only the repo's owner, repo-owner, may take a ticket back, and github-actions[bot] started this run."
expect_nothing_changed
expect_no_call "gh "

scenario "refuses what is not a number"
shipped
start "12; rm -rf ."
expect_status 1
expect_output "is not the number of a ticket or a pull request"
expect_nothing_changed
expect_no_call "gh "

scenario "stops for a ticket no merged pull request closes"
shipped
echo '{"__typename":"Issue","closedByPullRequestsReferences":{"nodes":[{"number":9,"merged":false,"mergedAt":null}]}}' > "$T/what.json"
start 12
expect_status 1
expect_output "Not started: no merged pull request closes ticket #12, so it shipped nothing to take back."
expect_nothing_changed

scenario "stops for a pull request that is not merged"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
echo '{"state":"OPEN","mergeCommit":null,"mergedAt":null,"title":"feat: export forecast as CSV"}' > "$T/view.json"
start 7
expect_status 1
expect_output "Not started: pull request #7 is not merged, so it shipped nothing to take back."
expect_nothing_changed

scenario "stops when a ticket that takes the pull request back is already open"
shipped
echo '[{"number":29,"title":"Take back pull request #7","state":"open","state_reason":null}]' > "$T/issues.json"
start 12
expect_status 1
expect_output "Not started: ticket #29 already takes back pull request #7."
expect_nothing_changed

scenario "stops when the pull request was already taken back"
shipped
echo '[{"number":29,"title":"Take back pull request #7","state":"closed","state_reason":"completed"}]' > "$T/issues.json"
start 12
expect_status 1
expect_output "Not started: ticket #29 already takes back pull request #7."
expect_nothing_changed

scenario "an earlier ticket closed as not planned, another pull request's, or a pull request of that title, holds nothing back"
shipped
echo '[{"number":27,"title":"Take back pull request #7","state":"closed","state_reason":"not_planned"},
  {"number":28,"title":"Take back pull request #70","state":"open","state_reason":null},
  {"number":29,"title":"Take back pull request #7","state":"open","pull_request":{"url":"x"}}]' > "$T/issues.json"
start 12
expect_status 0
expect_call "gh workflow run implement.yml -f issue=30"

for read in "api graphql" "pr view 7 --json state" "pr view 7 --json body" "api --method GET repos/{owner}/{repo}/issues" "api repos/{owner}/{repo}/pulls/7/files"; do
  scenario "stops, changing nothing, when GitHub does not answer: $read"
  shipped
  echo "$read" > "$T/fail"
  start 12
  expect_status 1
  expect_output "Not started: GitHub did not"
  expect_nothing_changed
done

scenario "asks GitHub again when a read fails once"
shipped
printf 'api graphql\npr view 7 --json state\npr view 7 --json body\napi --method GET repos/{owner}/{repo}/issues\napi repos/{owner}/{repo}/pulls/7/files\n' > "$T/flaky"
start 12
expect_status 0
expect_call "gh workflow run implement.yml -f issue=30"

scenario "stops when the ticket cannot be filed, and starts no build"
shipped
echo "issue create" > "$T/fail"
start 12
expect_status 1
expect_output "Not started: the ticket that takes back pull request #7 could not be filed. Nothing was changed."
expect_no_call "gh workflow run"
[ "$(grep -c "^gh issue create" "$T/calls")" = 1 ] || fail "expected the ticket to be filed once, never again"

scenario "starts no build when GitHub does not say which ticket it filed"
shipped
echo "Created." > "$T/url"
start 12
expect_status 1
expect_output "GitHub did not say which ticket it filed to take back pull request #7. Find it, take the \`ready\` label off it and add it again."
expect_no_call "gh workflow run"

scenario "a build that cannot be started leaves no ticket behind, and is started once"
shipped
echo "workflow run" > "$T/fail"
start 12
expect_status 1
expect_call "gh issue close 30 --reason not planned"
expect_output "Not started: the build that takes back pull request #7 could not be started, and the ticket filed for it, #30, was closed. Nothing was changed."
[ "$(grep -c "^gh workflow run" "$T/calls")" = 1 ] || fail "expected the build to be started once, never again"

scenario "a build that cannot be started, whose ticket cannot be closed, says how to start it"
shipped
printf 'workflow run\nissue close\n' > "$T/fail"
start 12
expect_status 1
expect_output "Not started: the build of ticket #30, which takes back pull request #7, could not be started. Take the \`ready\` label off it and add it again."
expect_no_output "Nothing was changed."

scenario "once the revert has merged, the ticket taken back is reopened, labelled and told"
shipped
merged
expect_status 0
expect_call "gh issue reopen 12"
expect_call "gh issue edit 12 --add-label reverted --remove-label deployed"
expect_call "gh issue comment 12 --body Taken back: pull request #31 reverted pull request #7, and \`main\` no longer holds its change. To build this ticket again, add \`ready\`."
expect_output "ticket #12 was reopened as reverted: pull request #31 took back pull request #7"

scenario "a merged ticket that takes nothing back reopens nothing"
shipped
echo '{"title":"Export forecast as CSV"}' > "$T/ticket.json"
merged
expect_status 0
[ -z "$out" ] || fail "expected nothing said"
[ "$(grep -c . "$T/calls")" = 1 ] || fail "expected the one read of the ticket's title"

scenario "a title that only begins or ends like a revert's takes nothing back"
shipped
for title in "Take back pull request #7 and #8" "Never take back pull request #7" "Take back pull request #"; do
  jq -n --arg title "$title" '{title: $title}' > "$T/ticket.json"
  merged
  expect_status 0
done
expect_no_call "gh issue reopen"
expect_no_call "gh pr view"

scenario "a merged revert of a pull request that closed no ticket tells that pull request"
shipped
echo "A person's own pull request." > "$T/body"
merged
expect_status 0
expect_call "gh pr comment 7 --body Taken back: pull request #31 reverted pull request #7, and \`main\` no longer holds its change."
expect_no_call "gh issue reopen"
expect_no_call "gh issue edit"

for read in "issue view 30" "pr view 7 --json body"; do
  scenario "fails, reopening nothing, when GitHub does not answer after the merge: $read"
  shipped
  echo "$read" > "$T/fail"
  merged
  expect_status 1
  expect_output "GitHub did not return"
  expect_no_call "gh issue reopen"
done

scenario "after the merge, each call is asked again when it fails once"
shipped
printf 'issue view 30\npr view 7 --json body\nissue reopen 12\nissue edit 12\nissue comment 12\n' > "$T/flaky"
merged
expect_status 0
expect_call "gh issue comment 12 --body Taken back:"

scenario "a ticket that cannot be reopened is still labelled and told, and the script fails"
shipped
echo "issue reopen 12" > "$T/fail"
merged
expect_status 1
expect_output "Ticket #12 could not be reopened."
expect_call "gh issue edit 12 --add-label reverted --remove-label deployed"
expect_call "gh issue comment 12 "

scenario "a ticket that cannot be labelled is still reopened and told, and the script fails"
shipped
echo "issue edit 12" > "$T/fail"
merged
expect_status 1
expect_call "gh issue reopen 12"
expect_output "Ticket #12 could not be labelled \`reverted\` in place of \`deployed\`."
expect_call "gh issue comment 12 "

scenario "fails when the ticket cannot be told, already reopened and labelled"
shipped
echo "issue comment 12" > "$T/fail"
merged
expect_status 1
expect_call "gh issue reopen 12"
expect_output "Ticket #12 could not be told that pull request #31 took it back."

scenario "fails when a pull request that closed no ticket cannot be told"
shipped
echo "A person's own pull request." > "$T/body"
echo "pr comment 7" > "$T/fail"
merged
expect_status 1
expect_output "Pull request #7 could not be told that pull request #31 took it back."

scenario "says how it is used when given neither half"
shipped
run "$scripts/revert.sh" 12 repo-owner repo-owner
expect_status 1
expect_output "Usage: revert.sh start"
expect_no_call "gh "
