#!/usr/bin/env bash
# Tests for factory/scripts/merge-gate.sh: ship a passed pull request, or hold one only the owner may decide.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

gate() { run env GH_TOKEN=workflow-token PRODUCTION_URL=https://myapp.example/ "$scripts/merge-gate.sh" 7 "$head" repo-owner; }
unreviewed() { jq '.reviews = []' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"; }

scenario "ships a pull request that touches no protected path, with nobody's approval"
ready_to_ship
unreviewed
gate
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_call "gh issue edit 12 --add-label deployed"

# A pull request whose patch changes one line of each path given.
change() {
  : > "$T/diff"; : > "$T/patch"
  local path
  for path in "$@"; do
    echo "$path" >> "$T/diff"
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-%s\n+%s\n' "$path" "$path" "$path" "$path" "${old:-one}" "${new:-two}" >> "$T/patch"
  done
}
# A factory ticket's pull request: #12 is labelled so.
factory_change() {
  echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
  change "$@"
}
# The installer GitHub runs is the one main holds, or is not.
installer() {
  mkdir -p factory/workflows .github/workflows
  echo "name: install-workflows" > factory/workflows/install-workflows.yml
  echo "name: install-workflows$1" > .github/workflows/install-workflows.yml
}
expect_held_as_owners() {
  expect_status 0
  expect_no_call "gh pr merge"
  expect_call "gh pr comment 7 --body Both reviews passed, but this pull request changes what only the repo owner may decide:

\`\`\`
$1
\`\`\`

Approve it to ship it: it merges as soon as the repo owner approves."
  expect_call "gh pr edit 7 --add-label needs-human"
  expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
}

scenario "ships a factory ticket's change to the factory's files alone that both reviews passed, with nobody's approval"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh .claude/skills/implement/SKILL.md .github/PULL_REQUEST_TEMPLATE.md
gate
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_no_call "gh pr comment 7 --body Both reviews passed"
expect_no_call "--add-label needs-human"

scenario "holds a product ticket's change to the theme for the owner, though Esme may make it"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx apps/web/src/app/globals.css
gate
expect_held_as_owners "the product's bar: apps/web/src/app/globals.css"
expect_no_call "gh issue view 12 --json labels"

scenario "a pull request held for the owner is no longer being built: a ticket that waits with ready is started"
ready_to_ship
unreviewed
change apps/web/src/app/globals.css
echo '[{"number":20}]' > "$T/ready.json"
gate
expect_status 0
expect_call "gh workflow run implement.yml -f issue=20"
[ "$(grep -n '^gh workflow run implement.yml' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue edit 12 --remove-label in-progress' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the held pull request and its ticket were labelled"

scenario "says so and fails when the ticket that waits cannot be started, with the pull request still held"
ready_to_ship
unreviewed
change apps/web/src/app/globals.css
echo '[{"number":20}]' > "$T/ready.json"
echo "workflow run implement.yml" > "$T/fail"
gate
expect_status 1
expect_call "gh pr edit 7 --add-label needs-human"
expect_output "Pull request #7 waits for the owner, and the tickets that wait with ready were not all started"

scenario "holds a factory ticket's change to the theme for the owner"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh apps/web/src/app/globals.css
gate
expect_held_as_owners "the product's bar: apps/web/src/app/globals.css"

scenario "holds a change to the rest of the product's bar and to CLAUDE.md, on a product ticket and on a factory ticket"
ready_to_ship
unreviewed
bar="the product's bar: TASTE.md
the product's bar: DESIGN.md
the product's bar: apps/web/eslint.config.mjs
the product's bar: apps/web/e2e/test.ts
the agents' instructions: CLAUDE.md"
change TASTE.md DESIGN.md apps/web/eslint.config.mjs apps/web/e2e/test.ts CLAUDE.md
gate
expect_held_as_owners "$bar"
: > "$T/calls"
factory_change TASTE.md DESIGN.md apps/web/eslint.config.mjs apps/web/e2e/test.ts CLAUDE.md
gate
expect_held_as_owners "$bar"

scenario "ships a change to the product's bar the owner has approved at this commit"
ready_to_ship
change apps/web/src/app/globals.css
gate
expect_status 0
expect_calls 1 "gh pr merge 7"

scenario "holds a product ticket's change whose diff the rule cannot read, and shows why"
ready_to_ship
unreviewed
printf '@@ -1 +1 @@\n-one\n+two\n' > "$T/patch"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "owner-decides.sh: line 1 of the diff opens a hunk of no file"

scenario "does not ship, and says why, when a product ticket's diff cannot be read from GitHub"
ready_to_ship
unreviewed
rm "$T/patch"
gate
expect_failure
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return this pull request's diff, so whether it changes what only the owner may decide is not known."

scenario "ships a factory ticket's change to a workflow, when the installer that runs is the one main holds"
ready_to_ship
unreviewed
old='        run: factory/scripts/say.sh' new='        run: factory/scripts/say.sh "$PR"' factory_change factory/workflows/ci.yml
installer ""
gate
expect_status 0
expect_calls 1 "gh pr merge 7"

scenario "holds a workflow change while the installer that runs is an older one, which would refuse it once merged"
ready_to_ship
unreviewed
old='        run: factory/scripts/say.sh' new='        run: factory/scripts/say.sh "$PR"' factory_change factory/workflows/ci.yml factory/scripts/ship.sh
installer " as it was"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Both reviews passed, but this pull request changes a workflow while the installer that runs is not yet the one \`main\` holds, and that one may refuse a change nobody approved:

\`\`\`
factory/workflows/ci.yml
\`\`\`"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "holds a workflow change when no installer is installed at all"
ready_to_ship
unreviewed
factory_change factory/workflows/ci.yml
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "while the installer that runs is not yet the one"

scenario "holds a factory ticket's change to spend or limits for the owner, and shows the line"
ready_to_ship
unreviewed
old="    timeout-minutes: 20" new="    timeout-minutes: 360" factory_change factory/workflows/ci.yml
installer ""
gate
expect_held_as_owners "spend or limits: factory/workflows/ci.yml: timeout-minutes: 20
spend or limits: factory/workflows/ci.yml: timeout-minutes: 360"

scenario "holds a factory ticket's change to secrets or permissions for the owner"
ready_to_ship
unreviewed
old="      contents: read" new="      contents: write" factory_change factory/workflows/ci.yml
installer ""
gate
expect_held_as_owners "secrets or permissions: factory/workflows/ci.yml: contents: read
secrets or permissions: factory/workflows/ci.yml: contents: write"

scenario "holds a factory ticket's change to the scripts that decide the hold, among files that would merge"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh factory/scripts/owner-decides.sh factory/README.md
gate
expect_held_as_owners "this rule: factory/scripts/owner-decides.sh"

scenario "ships a held change the owner has approved at this commit"
ready_to_ship
factory_change factory/scripts/merge-gate.sh
gate
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_no_call "gh pr diff 7
"

scenario "holds a factory ticket's change whose diff the rule cannot read, and shows why"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh
printf '@@ -1 +1 @@\n-one\n+two\n' > "$T/patch"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "owner-decides.sh: line 1 of the diff opens a hunk of no file"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when a factory ticket's diff cannot be read from GitHub"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh
rm "$T/patch"
gate
expect_failure
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return this pull request's diff, so whether it changes what only the owner may decide is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when the ticket's labels cannot be read: that is not a factory ticket, nor a product one"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh
echo "issue view 12 --json labels" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return the labels of ticket #12, so whether it is a \`factory\` ticket, which may change the factory's files, is not known."

scenario "holds a product ticket's pull request that touches the factory's files for the owner, and says which files"
ready_to_ship
unreviewed
printf 'apps/web/src/app/page.tsx\nfactory/scripts/ship.sh\nCLAUDE.md\n' > "$T/diff"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_call "factory/scripts/ship.sh"
expect_call "Approve it to ship it: it merges as soon as the repo owner approves."
expect_no_call "apps/web/src/app/page.tsx"
expect_no_call "CLAUDE.md"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"

scenario "puts both reviewers' assumptions at the top of the comment that tells the owner, in the order each gave them"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"GitHub accepts `queue: max` on a job.","if_wrong":"Every merge stops."}]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"The action takes `client-id`.","if_wrong":"No token is made."},{"assumes":"Neon answers 200 for a deleted branch.","if_wrong":"The step fails."},{"assumes":"A branch name has no space.","if_wrong":"A build is skipped."}]}'
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body **Before you approve, what the reviewers could not check:**

- **Adam (architecture and taste):** Assumes: GitHub accepts \`queue: max\` on a job.
  If wrong: Every merge stops.
- **Ryan (correctness):** Assumes: The action takes \`client-id\`.
  If wrong: No token is made.
- **Ryan (correctness):** Assumes: Neon answers 200 for a deleted branch.
  If wrong: The step fails.
- **Ryan (correctness):** Assumes: A branch name has no space.
  If wrong: A build is skipped.

Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"

scenario "says nothing about assumptions when both reviewers' lists are empty"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[]}'
gate
expect_status 0
expect_call "gh pr comment 7 --body Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_no_call "could not check"

scenario "says nothing about assumptions after reviews from before there was a list"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
echo '{"comments":[{"body":"**Adam (architecture and taste): PASS**\n\nFits."},{"body":"**Ryan (correctness): PASS**\n\nCorrect."}]}' > "$T/comments"
gate
expect_status 0
expect_call "gh pr comment 7 --body Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_no_call "could not check"

scenario "shows only each reviewer's latest list: an assumption settled in a fix round is gone"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Ryan (correctness)" '{"findings":[{"file":"a.sh","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}],"assumptions":[{"assumes":"An old claim.","if_wrong":"Something."}]}'
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"Vercel skips a docs-only build.","if_wrong":"The gate waits ten minutes."}]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[]}'
gate
expect_status 0
expect_call "- **Adam (architecture and taste):** Assumes: Vercel skips a docs-only build."
expect_no_call "An old claim."
expect_no_call "**Ryan (correctness):**"

scenario "a pass carried forward is a reviewer's latest verdict, and its list is shown like any other"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[]}'
jq '.comments += [{body: "**Ryan (correctness): PASS**\n\nCarried forward from the review of abc1234: every commit since is a merge of `main`. No review ran. <!-- factory:carried -->\n\nCorrect.\n\n<!-- factory:reviewed 5555555555555555555555555555555555555555 -->\n<!-- factory:assumptions [{\"assumes\":\"A carried claim.\",\"if_wrong\":\"Something.\"}] -->"}]' "$T/comments" > "$T/comments.new"; mv "$T/comments.new" "$T/comments"
gate
expect_status 0
expect_call "- **Ryan (correctness):** Assumes: A carried claim."

scenario "a verdict posted before the install, with unverified claims in three parts, is still read: the claim and what goes wrong, in order"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Adam (architecture and taste)" '{"findings":[],"assumptions":[{"assumes":"Vercel skips a docs-only build.","if_wrong":"The gate waits ten minutes."}]}'
jq '.comments += [{body: "**Ryan (correctness): PASS**\n\n**Not verified**\n\n1. An old claim.\n   Not confirmed: No page.\n   If it is false: Something.\n\n<!-- factory:reviewed 5555555555555555555555555555555555555555 -->\n<!-- factory:unverified [{\"claim\":\"An old claim.\",\"why\":\"No page.\",\"risk\":\"Something.\"},{\"claim\":\"A second.\",\"why\":\"Not run.\",\"risk\":\"Something else.\"},{\"claim\":\"A third.\",\"why\":\"x\",\"risk\":\"y\"},{\"claim\":\"A fourth.\",\"why\":\"x\",\"risk\":\"z\"}] -->"}]' "$T/comments" > "$T/comments.new"; mv "$T/comments.new" "$T/comments"
gate
expect_status 0
expect_call "gh pr comment 7 --body **Before you approve, what the reviewers could not check:**

- **Adam (architecture and taste):** Assumes: Vercel skips a docs-only build.
  If wrong: The gate waits ten minutes.
- **Ryan (correctness):** Assumes: An old claim.
  If wrong: Something.
- **Ryan (correctness):** Assumes: A second.
  If wrong: Something else.
- **Ryan (correctness):** Assumes: A third.
  If wrong: y
- **Ryan (correctness):** Assumes: A fourth.
  If wrong: z

Both reviews passed"
expect_no_call "No page."

scenario "a comment that only quotes a hidden list adds nothing to the owner's comment, and a verdict that quotes one adds only its own assumption"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"It reads this line:\n<!-- factory:assumptions [{\"assumes\":\"Quoted.\",\"if_wrong\":\"y\"}] -->","if_wrong":"Nothing."}]}'
jq '.comments += [{body: "I looked at it.\n<!-- factory:assumptions [{\"assumes\":\"Not a verdict.\",\"if_wrong\":\"y\"}] -->"}]' "$T/comments" > "$T/comments.new"; mv "$T/comments.new" "$T/comments"
gate
expect_status 0
expect_call "- **Ryan (correctness):** Assumes: It reads this line:"
expect_no_call "- **Ryan (correctness):** Assumes: Quoted."
expect_no_call "Not a verdict."

scenario "does not tell the owner all is verified when a verdict's list cannot be read: it says so instead"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
echo '{"comments":[{"body":"**Ryan (correctness): PASS**\n\nCorrect.\n\n<!-- factory:assumptions [{\"claim\": -->"}]}' > "$T/comments"
gate
expect_failure
expect_no_call "gh pr merge"
expect_no_call "Both reviews passed"
expect_call "gh pr comment 7 --body Not merged: The reviewers' assumptions could not be read from their verdicts"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "holds a protected pull request that closes no ticket, and labels no ticket"
ready_to_ship
unreviewed
echo "A person's own pull request." > "$T/body"
echo factory/decisions.md > "$T/diff"
gate
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"

scenario "ships a protected pull request the owner has already approved at this commit"
ready_to_ship
echo factory/decisions.md > "$T/diff"
gate
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_no_call "Both reviews passed"

scenario "holds a protected pull request the owner approved at an older commit"
ready_to_ship
jq --arg old "$older" '.reviews[0].commit.oid = $old' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
echo factory/decisions.md > "$T/diff"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "gh pr edit 7 --add-label needs-human"

# The owner's reviews of #7, oldest first: <state> [commit] for each, of its head unless said.
owner_said() {
  local reviews="[]" state commit
  while [ $# -gt 0 ]; do
    state=$1; commit=$head; shift
    if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then commit=$1; shift; fi
    reviews=$(jq -c --arg s "$state" --arg c "$commit" '. + [{author: {login: "repo-owner"}, state: $s, commit: {oid: $c}}]' <<<"$reviews")
  done
  jq --argjson r "$reviews" '.reviews = $r' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
}
expect_held_for_owner() {
  expect_status 0
  expect_no_call "gh pr merge"
  expect_call "gh pr comment 7 --body Both reviews passed, but the repo owner asked for changes to this pull request, so only they can say it is now right. Approve it to ship it, or submit a \"Request changes\" review to send it back again."
  expect_no_call "Both reviews passed, but this pull request"
  expect_call "gh pr edit 7 --add-label needs-human"
  expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
}

scenario "holds a pull request the owner sent back, though it touches no protected path, and flags its ticket"
ready_to_ship
owner_said CHANGES_REQUESTED "$older"
gate
expect_held_for_owner

scenario "holds a factory ticket's change the owner sent back, though nothing in it is theirs alone to decide"
ready_to_ship
factory_change factory/scripts/ship.sh
owner_said CHANGES_REQUESTED "$older"
gate
expect_held_for_owner

scenario "holds one the owner sent back at this commit, and one they commented on afterwards"
ready_to_ship
owner_said CHANGES_REQUESTED COMMENTED
gate
expect_held_for_owner

scenario "holds one the owner approved and then sent back"
ready_to_ship
owner_said APPROVED CHANGES_REQUESTED
gate
expect_held_for_owner

scenario "ships one whose request the owner took back with an approval, though of an older commit"
ready_to_ship
owner_said CHANGES_REQUESTED "$older" APPROVED "$older"
gate
expect_status 0
expect_calls 1 "gh pr merge 7"

scenario "ships one the owner sent back once the owner approves this commit"
ready_to_ship
owner_said CHANGES_REQUESTED "$older" APPROVED
gate
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_no_call "Both reviews passed"

scenario "ships one whose \"Request changes\" review the owner dismissed"
ready_to_ship
owner_said DISMISSED "$older"
gate
expect_status 0
expect_calls 1 "gh pr merge 7"

scenario "ships one that only another reviewer sent back"
ready_to_ship
jq '.reviews = [{author: {login: "someone-else"}, state: "CHANGES_REQUESTED", commit: {oid: .headRefOid}}]' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
gate
expect_status 0
expect_calls 1 "gh pr merge 7"

scenario "says the protected files, not the owner's request, when a pull request the owner sent back touches them"
ready_to_ship
owner_said CHANGES_REQUESTED "$older"
echo factory/decisions.md > "$T/diff"
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "only a \`factory\` ticket may change"
expect_calls 1 "gh pr comment 7"

scenario "does not ship, and says why, when the reviews cannot be read: that is not a pull request the owner left alone"
ready_to_ship
echo "pr view 7 --json reviews" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return this pull request's reviews, so whether the owner approved it or sent it back is not known."

scenario "fails when the owner could not be told that a pull request they sent back waits for them"
ready_to_ship
owner_said CHANGES_REQUESTED "$older"
echo "issue edit 12" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"

scenario "ships when listing the files fails twice and then answers"
ready_to_ship
echo "2 pr diff 7" > "$T/flaky"
gate
expect_status 0
expect_calls 3 "gh pr diff 7"
expect_calls 1 "gh pr merge 7"

scenario "does not ship, and says why, when the files cannot be listed: that is not a pull request with no protected path"
ready_to_ship
unreviewed
echo "pr diff 7" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not list the files this pull request changes, so whether it needs a person is not known. Approving this pull request again retries it."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship a protected pull request, and says why, when its reviews cannot be read"
ready_to_ship
echo factory/decisions.md > "$T/diff"
echo "pr view 7 --json reviews" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub did not return this pull request's reviews"

scenario "fails when the owner could not be told that a protected pull request waits for them"
ready_to_ship
unreviewed
echo factory/decisions.md > "$T/diff"
echo "pr comment 7" > "$T/fail"
gate
expect_failure
expect_no_call "gh pr merge"

scenario "passes on what ship.sh says when it does not merge"
ready_to_ship
echo "pr merge 7" > "$T/fail"
gate
expect_failure
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Not merged: GitHub failed or refused the merge three times"
