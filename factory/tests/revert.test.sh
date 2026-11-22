#!/usr/bin/env bash
# Tests for revert.sh: files the ticket that takes a shipped one back and starts its build, and reopens it once merged.
. "$(dirname "$0")/helpers.sh"

commit=abcdef0123456789abcdef0123456789abcdef01

# Pull request #7 closed ticket #12 and merged as $commit. The next ticket GitHub files is #30, kept in $T/ticket.json.
# $T/fail holds one line per gh call, by its first words, that should fail; $T/flaky one that fails once.
# $T/since.json holds the open tickets another run filed after this one looked for an earlier take-back.
shipped() {
  echo '{"__typename":"Issue","closedByPullRequestsReferences":{"nodes":[{"number":7,"merged":true,"mergedAt":"2026-11-16T09:00:00Z"}]}}' > "$T/what.json"
  echo "{\"state\":\"MERGED\",\"mergeCommit\":{\"oid\":\"$commit\"},\"mergedAt\":\"2026-11-16T09:00:00Z\",\"title\":\"feat: export forecast as CSV\"}" > "$T/view.json"
  printf 'Closes #12\n\nThe forecast exports as CSV.\n' > "$T/body"
  echo '[{"filename":"apps/web/page.txt"}]' > "$T/files.json"
  echo '[{"number":12,"title":"Export forecast as CSV","state":"closed","state_reason":"completed"}]' > "$T/issues.json"
  echo '{"title":"Take back pull request #7"}' > "$T/ticket.json"
  echo '[]' > "$T/since.json"
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
      "api repos/{owner}/{repo}/issues?state=open&sort=created&direction=desc&per_page=100")
        jq -c --slurpfile filed "$T/ticket.json" ". + [{number: 30, title: \$filed[0].title, user: {login: \"github-actions[bot]\"}}]" "$T/since.json" ;;
      "issue edit 30 --remove-label ready" | "issue close 30 --reason duplicate --comment "*) ;;
      "issue view 30 --json title,body,labels,createdAt") cat "$T/ticket.json" ;;
      "issue view 30 --json title "* | "issue view 30 --json body "*) json "$(cat "$T/ticket.json")" "$@" ;;
      "workflow run implement.yml -f issue=30" | "issue close 30 --reason not planned") ;;
      "issue reopen 12" | "issue edit 12 --add-label reverted --remove-label deployed" | "issue comment 12 "* | "pr comment 7 "*) ;;
      "issue edit 12 --remove-label revert" | "issue comment 7 "* | "issue edit 7 --remove-label revert") ;;
      "issue edit 12 --add-label reverted --add-label ready --remove-label deployed --remove-label needs-human --remove-label in-progress" | "workflow run implement.yml -f issue=12") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
}
start() { run env GH_TOKEN=workflow-token "$scripts/revert.sh" start "${1:-12}" "${2:-repo-owner}" repo-owner; }
# The owner merged #7 with GitHub's merge button, and main then failed: button-merge.sh runs this, in nobody's name.
button() { run env GH_TOKEN=workflow-token FAILED="${printed-FAILED factory/tests/ship.test.sh: expected exit 0}" "$scripts/revert.sh" button 7; }
merged() { run env GH_TOKEN=workflow-token "$scripts/revert.sh" shipped 30 31; }
filed() { jq -r "$1" "$T/ticket.json"; }
# expect_nothing_changed [labelled]: the labelled ticket, #12 unless given, is told why and loses the label; no ticket was
# filed, closed or reopened, and no build was started.
expect_nothing_changed() {
  expect_output "Nothing was changed."
  expect_calls 1 "gh issue comment ${1:-12} --body Not started: "
  expect_calls 1 "gh issue edit ${1:-12} --remove-label revert"
  expect_calls 2 "gh issue "
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
expect_call "gh issue edit 12 --remove-label revert"
expect_no_call "gh issue comment"

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

scenario "the label added by anyone but the owner changes nothing except a comment on the ticket that says so, and the label goes"
shipped
start 12 mallory
expect_status 1
expect_output "Not started: only the repo's owner, repo-owner, may take a ticket back, and mallory asked for it."
expect_nothing_changed
expect_call "gh issue comment 12 --body Not started: only the repo's owner, repo-owner, may take a ticket back, and mallory asked for it. Nothing was changed."
expect_calls 2 "gh "

scenario "refuses what is not a number"
shipped
start "12; rm -rf ."
expect_status 1
expect_output "is not the number of a ticket or a pull request. Nothing was changed."
expect_no_call "gh "

scenario "stops for a ticket no merged pull request closes"
shipped
echo '{"__typename":"Issue","closedByPullRequestsReferences":{"nodes":[{"number":9,"merged":false,"mergedAt":null}]}}' > "$T/what.json"
start 12
expect_status 1
expect_output "Not started: no merged pull request closes ticket #12, so it shipped nothing to take back."
expect_nothing_changed
expect_call "gh issue comment 12 --body Not started: no merged pull request closes ticket #12, so it shipped nothing to take back. Nothing was changed."

scenario "stops for a pull request that is not merged"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
echo '{"state":"OPEN","mergeCommit":null,"mergedAt":null,"title":"feat: export forecast as CSV"}' > "$T/view.json"
start 7
expect_status 1
expect_output "Not started: pull request #7 is not merged, so it shipped nothing to take back."
expect_nothing_changed 7

scenario "stops when a ticket that takes the pull request back is already open"
shipped
echo '[{"number":29,"title":"Take back pull request #7","state":"open","state_reason":null}]' > "$T/issues.json"
start 12
expect_status 1
expect_output "Not started: ticket #29 already takes back pull request #7."
expect_nothing_changed

scenario "another run filed the take-back at the same time: the later ticket is closed, no build of it is started, and the ticket is told"
shipped
echo '[{"number":29,"title":"Take back pull request #7","user":{"login":"github-actions[bot]"}}]' > "$T/since.json"
start 12
expect_status 1
expect_calls 1 "gh issue create"
expect_calls 1 "gh issue close 30 --reason duplicate"
expect_no_call "gh workflow run"
expect_calls 1 "gh issue comment 12 --body Not started: ticket #29 already takes back pull request #7, so ticket #30, filed at the same time, was closed."
expect_calls 1 "gh issue edit 12 --remove-label revert"

scenario "whether another run filed the take-back too cannot be read: it says so, and the build is started"
shipped
echo "api repos/{owner}/{repo}/issues?state=open&sort=created" > "$T/fail"
start 12
expect_status 0
expect_output "Whether another run filed the same ticket as #30 could not be read from GitHub, so #30 stays open."
expect_call "gh workflow run implement.yml -f issue=30"
expect_no_call "gh issue close"

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
expect_call "gh issue comment 12 --body Not started: the ticket that takes back pull request #7 could not be filed."
expect_call "gh issue edit 12 --remove-label revert"
expect_no_call "gh workflow run"
[ "$(grep -c "^gh issue create" "$T/calls")" = 1 ] || fail "expected the ticket to be filed once, never again"

scenario "starts no build when GitHub does not say which ticket it filed"
shipped
echo "Created." > "$T/url"
start 12
expect_status 1
expect_output "GitHub did not say which ticket it filed to take back pull request #7. Find it, take the \`ready\` label off it and add it again."
expect_call "gh issue comment 12 --body Not started: GitHub did not say which ticket it filed to take back pull request #7."
expect_call "gh issue edit 12 --remove-label revert"
expect_no_call "gh workflow run"

scenario "a build that cannot be started leaves no ticket behind, and is started once"
shipped
echo "workflow run" > "$T/fail"
start 12
expect_status 1
expect_call "gh issue close 30 --reason not planned"
expect_output "Not started: the build that takes back pull request #7 could not be started, and the ticket filed for it, #30, was closed. Nothing was changed."
expect_call "gh issue comment 12 --body Not started: the build that takes back pull request #7 could not be started"
expect_call "gh issue edit 12 --remove-label revert"
[ "$(grep -c "^gh workflow run" "$T/calls")" = 1 ] || fail "expected the build to be started once, never again"

scenario "a build that cannot be started, whose ticket cannot be closed, says how to start it"
shipped
printf 'workflow run\nissue close\n' > "$T/fail"
start 12
expect_status 1
expect_output "Not started: the build of ticket #30, which takes back pull request #7, could not be started. Take the \`ready\` label off it and add it again."
expect_no_output "Nothing was changed."
expect_call "gh issue comment 12 --body Not started: the build of ticket #30, which takes back pull request #7, could not be started."
expect_call "gh issue edit 12 --remove-label revert"

scenario "a refusal the ticket cannot be told still takes the label off, and says both"
shipped
echo "issue comment 12" > "$T/fail"
start 12 mallory
expect_status 1
expect_output "Not started: only the repo's owner"
expect_output "Ticket #12 could not be told so."
expect_call "gh issue edit 12 --remove-label revert"

scenario "a label that cannot be taken off fails the run, after the take-back started once"
shipped
echo "issue edit 12 --remove-label revert" > "$T/fail"
start 12
expect_status 1
expect_output "ticket #30 takes back pull request #7: its build was started"
expect_output "The \`revert\` label could not be taken off ticket #12."
expect_calls 1 "gh workflow run implement.yml -f issue=30"

scenario "tells the ticket and takes the label off again when either call fails once"
shipped
printf 'issue comment 12\nissue edit 12 --remove-label revert\n' > "$T/flaky"
start 12 mallory
expect_status 1
expect_calls 2 "gh issue comment 12 --body Not started: "
expect_calls 2 "gh issue edit 12 --remove-label revert"
expect_no_output "could not be"

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

scenario "takes back a merge with the button that broke main: no owner starts it, and the ticket says what failed"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
button
expect_status 0
expect_call "gh issue create --title Take back the button merge of pull request #7 --label chore --label ready --body ## Change"
expect_call "Take back pull request #7 (\`feat: export forecast as CSV\`), which shipped ticket #12: it was merged with GitHub's merge button, and \`main\` then failed, having passed before the merge. The test of \`main\` ended:

\`\`\`
FAILED factory/tests/ship.test.sh: expected exit 0
\`\`\`

Take it back whole. On your branch run \`git revert --no-edit $commit\`, and change nothing else."
expect_no_call "the owner asked for it"
expect_call "gh workflow run implement.yml -f issue=30"
expect_output "ticket #30 takes back pull request #7: its build was started, and Esme opens the pull request that reverts abcdef0"
expect_no_call "--remove-label revert"
run env GH_TOKEN=workflow-token "$scripts/check-ticket.sh" 30
expect_status 0

scenario "a test of main that printed nothing, or a fence, still leaves one fenced block in the ticket"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
printed="" button
expect_status 0
expect_call "
\`\`\`
It printed nothing.
\`\`\`"
printed='before
```
after' button
expect_status 0
expect_call "
\`\`\`
before
after
\`\`\`"

for title in "Take back the button merge of pull request #7" "Take back pull request #7"; do
  scenario "a merge with the button is taken back once: \"$title\" is already filed, so it says so and files nothing"
  shipped
  echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
  jq -n --arg title "$title" '[{number: 29, title: $title, state: "closed", state_reason: "completed"}]' > "$T/issues.json"
  button
  expect_status 0
  expect_output "ticket #29 already takes back pull request #7; no second one was filed"
  expect_no_call "gh issue create"
  expect_no_call "gh workflow run"
done

scenario "a merge with the button is taken back once when the owner's take-back is filed at the same time: the later is closed"
shipped
echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
echo '[{"number":29,"title":"Take back pull request #7","user":{"login":"github-actions[bot]"}}]' > "$T/since.json"
button
expect_status 0
expect_calls 1 "gh issue close 30 --reason duplicate"
expect_output "ticket #29 already takes back pull request #7; ticket #30, filed at the same time, was closed"
expect_no_call "gh workflow run"

scenario "the owner cannot start a second take-back of a merge the factory is taking back"
shipped
echo '[{"number":29,"title":"Take back the button merge of pull request #7","state":"open","state_reason":null}]' > "$T/issues.json"
start 12
expect_status 1
expect_output "Not started: ticket #29 already takes back pull request #7."
expect_nothing_changed

for read in "api graphql" "pr view 7 --json state" "pr view 7 --json body" "api --method GET repos/{owner}/{repo}/issues" "api repos/{owner}/{repo}/pulls/7/files" "issue create" "workflow run"; do
  scenario "a take-back of a merge with the button fails when GitHub does not answer: $read"
  shipped
  echo '{"__typename":"PullRequest","number":7}' > "$T/what.json"
  echo "$read" > "$T/fail"
  button
  expect_status 1
  expect_output "Not started: "
  expect_no_call "gh issue reopen"
  expect_no_call "gh issue comment"
  expect_no_call "--remove-label revert"
done

# Ticket #30 took back the merge with the button, and pull request #31, which reverts it, has merged.
taken_back() {
  shipped
  jq -n '{title: "Take back the button merge of pull request #7", body: "## Change\nTake back pull request #7. The test of `main` ended:\n\n```\nFAILED factory/tests/ship.test.sh: expected exit 0\n```\n\nTake it back whole.\n\n## Docs to update\nNone."}' > "$T/ticket.json"
}

scenario "once the take-back of a merge with the button has merged, the ticket is told what failed and is in progress again"
taken_back
merged
expect_status 0
expect_call "gh issue reopen 12"
expect_call "gh issue comment 12 --body Taken back: pull request #31 reverted pull request #7, and \`main\` no longer holds its change. Pull request #7 was merged with GitHub's merge button, and \`main\` then failed, having passed before the merge. This ticket is being built again: build it so that this passes, starting from the commits of pull request #7 (\`git fetch origin refs/pull/7/head\`). The test of \`main\` ended:

\`\`\`
FAILED factory/tests/ship.test.sh: expected exit 0
\`\`\`"
expect_call "gh issue edit 12 --add-label reverted --add-label ready --remove-label deployed --remove-label needs-human --remove-label in-progress"
[ "$(grep -c "^gh workflow run" "$T/calls")" = 1 ] || fail "expected the build to be started once"
expect_no_call "add \`ready\`"
expect_output "ticket #12 was reopened and its build started again: pull request #31 took back pull request #7"
[ "$(grep -n '^gh workflow run implement.yml' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue edit 12 --add-label reverted --add-label ready' "$T/calls" | cut -d: -f1)" ] \
  && [ "$(grep -n '^gh issue edit 12 --add-label reverted --add-label ready' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue comment 12 ' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the ticket to be told, then labelled ready, then built"

scenario "a take-back the owner started still waits for ready: no build is started"
shipped
merged
expect_status 0
expect_no_call "gh workflow run"
expect_no_call "--add-label ready"

scenario "a ticket that cannot be told what failed is still built again, and the script fails"
taken_back
echo "issue view 30 --json body" > "$T/fail"
merged
expect_status 1
expect_output "GitHub did not return what ticket #30 says failed on \`main\`, so ticket #12 is not told it."
expect_call "gh issue comment 12 --body Taken back: pull request #31 reverted pull request #7"
expect_call "gh workflow run implement.yml -f issue=12"

scenario "a ticket that cannot be labelled ready gets no build, which would be refused, and the script says how to start it"
taken_back
echo "issue edit 12" > "$T/fail"
merged
expect_status 1
expect_call "gh issue reopen 12"
expect_output "Ticket #12 could not be labelled \`reverted\` and \`ready\`, so its build was not started. Add \`ready\` to start it."
expect_no_call "gh workflow run"

scenario "a build that cannot be started again is asked for once, and the script says how to start it"
taken_back
echo "workflow run" > "$T/fail"
merged
expect_status 1
expect_output "The build of ticket #12 could not be started. Take the \`ready\` label off it and add it again."
[ "$(grep -c "^gh workflow run" "$T/calls")" = 1 ] || fail "expected the build to be asked for once, never again"

scenario "the take-back of a merge with the button that closed no ticket tells that pull request, and builds nothing"
taken_back
echo "A person's own pull request." > "$T/body"
merged
expect_status 0
expect_call "gh pr comment 7 --body Taken back: pull request #31 reverted pull request #7, and \`main\` no longer holds its change."
expect_no_call "gh workflow run"

scenario "says how it is used when given neither half"
shipped
run "$scripts/revert.sh" 12 repo-owner repo-owner
expect_status 1
expect_output "Usage: revert.sh start"
expect_no_call "gh "

# A change to the workflow must fail here: nothing runs revert.yml before it is installed.
scenario "revert.yml starts for the \`revert\` label and for no other label, and for no command"
workflow="$root/factory/workflows/revert.yml"
cd "$root"
run "$scripts/events.sh"
expect_status 0
expect_output "| \`revert.yml\` | issues (types: labeled) | The \`revert\` label on a shipped ticket takes it back: an engineer opens the pull request that reverts it. | no script or workflow |"
[ "$(grep -c '^    if: ' "$workflow")" = 1 ] && grep -A1 -xF '    if: >-' "$workflow" | grep -qxF "      github.event.label.name == 'revert' &&" \
  || fail "the job of revert.yml does not run for the \`revert\` label alone"
[ "$(grep -c '^  [a-z-]*:$' <<<"$(sed -n '/^jobs:/,$p' "$workflow")")" = 1 ] || fail "revert.yml has a second job, which the label does not guard"
grep -qxF '          NUMBER: ${{ github.event.issue.number }}' "$workflow" || fail "revert.yml does not take the number of the labelled ticket"
grep -qxF '          STARTED_BY: ${{ github.triggering_actor }}' "$workflow" || fail "revert.yml does not say who started the run"
grep -qxF '        run: factory/scripts/revert.sh start "$NUMBER" "$STARTED_BY" "$OWNER"' "$workflow" || fail "revert.yml does not run revert.sh start"

scenario "what the owner reads names the label, and no command that takes a ticket back"
! grep -rn 'gh workflow run revert' "$root/factory/README.md" "$root/factory/owner-guide.md" || fail "a document hands the owner a command to take a ticket back"
grep -qF 'add the `revert` label' "$root/factory/owner-guide.md" || fail "owner-guide.md does not name the \`revert\` label"
