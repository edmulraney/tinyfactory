#!/usr/bin/env bash
# Tests for factory/scripts/merge-gate.sh: ship a passed pull request, or hold one only the owner may decide.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

# Pull request #7 in git: the directory a scenario runs in is the gate's checkout of main, and GitHub keeps the pull
# request's last commit. main_holds and pull_request_holds each commit what the directory holds then.
main_holds() {
  rm -rf .git
  git init --quiet --initial-branch main .
  git remote add origin "$T/github/owner/myapp.git"
  git add -A && git commit --quiet --allow-empty -m "chore: begin"
}
pull_request_holds() {
  git checkout --quiet --detach
  git add -A && git commit --quiet --allow-empty -m "the change"
  pushed
}
# GitHub holds the commit that is checked out as the pull request's last, and the checkout is back on main.
pushed() {
  local was="$head"
  head=$(git rev-parse HEAD)
  git push --quiet --force origin HEAD:refs/pull/7/head
  git checkout --quiet main
  # The checkout holds main alone, as a runner's does, until the gate fetches.
  git reflog expire --expire=now --all && git prune --expire=now
  # GitHub's answers name that commit.
  [ "$was" = "$head" ] && return
  sed -i.bak "s/$was/$head/g" "$T/view.json" && rm "$T/view.json.bak"
  mv "$T/runs/$was" "$T/runs/$head"
}
# A pull request that changes one line of each path given.
change() {
  local path
  for path in "$@"; do mkdir -p "$(dirname "$path")"; echo "${old:-one}" > "$path"; done
  main_holds
  for path in "$@"; do echo "${new:-two}" > "$path"; done
  pull_request_holds
}
# watch_git [<times> <the first words of a call>]: git as it is, each call recorded, and that call failing its first <times> times.
git=$(command -v git)
watch_git() {
  echo "${1:-0} ${2:-no call}" > "$T/git-fails"
  stub git '
    read -r times words < "$T/git-fails"
    case "$*" in "$words"*)
      if [ "$(grep -cxF -- "git $*" "$T/calls")" -le "$times" ]; then echo "git: failed: $*" >&2; exit 1; fi ;;
    esac
    exec '"$git"' "$@"'
}
gate() {
  # A scenario that does not say what the pull request changes is about one line of the app.
  [ -d .git ] || change apps/web/src/app/page.tsx
  run env GH_TOKEN=workflow-token "$scripts/merge-gate.sh" 7 "$head" repo-owner
}
unreviewed() { jq '.reviews = []' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"; }

scenario "adds to those that wait to merge a pull request that touches no protected path, with nobody's approval"
ready_to_ship
unreviewed
gate
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->This pull request waits to merge at ${head:0:7}."
expect_call "gh workflow run merge-group.yml"

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
  expect_no_call "gh workflow run merge-group.yml"
  expect_first_line "gh pr comment 7 --body" "Approve this pull request: it merges as soon as the repo owner approves."
  expect_call "Both reviews passed, but this pull request changes what only the repo owner may decide:

\`\`\`
$1
\`\`\`"
  expect_call "gh pr edit 7 --add-label needs-human"
  expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"
}

scenario "adds to those that wait to merge a factory ticket's change to the factory's files alone that both reviews passed, with nobody's approval"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh .claude/skills/implement/SKILL.md .github/PULL_REQUEST_TEMPLATE.md
gate
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->This pull request waits to merge at ${head:0:7}."
expect_no_call "Both reviews passed"
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
# In the order git lists the files.
bar="the agents' instructions: CLAUDE.md
the product's bar: DESIGN.md
the product's bar: TASTE.md
the product's bar: apps/web/e2e/test.ts
the product's bar: apps/web/eslint.config.mjs"
change TASTE.md DESIGN.md apps/web/eslint.config.mjs apps/web/e2e/test.ts CLAUDE.md
gate
expect_held_as_owners "$bar"
: > "$T/calls"
factory_change TASTE.md DESIGN.md apps/web/eslint.config.mjs apps/web/e2e/test.ts CLAUDE.md
gate
expect_held_as_owners "$bar"

scenario "adds to those that wait to merge a change to the product's bar the owner has approved at this commit"
ready_to_ship
change apps/web/src/app/globals.css
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "holds a product ticket's change whose diff the rule cannot read, and shows why"
ready_to_ship
unreviewed
change "docs/café.md"
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "owner-decides.sh: line 1 of the diff names a path git had to quote"

scenario "does not ship, and says why, when git cannot read a product ticket's diff"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx
watch_git 99 "diff $(git rev-parse main)"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: Git could not read this pull request's diff, so whether it changes what only the owner may decide is not known."

# The owner merged pull request #5 with GitHub's merge button, which raised a workflow's time limit, and main then failed.
# A workflow filed ticket #12 to take it back, and pull request #7 puts the limit back (decisions M439f).
# taken_back [<who merged #5>]: $after_merge changes main after that merge, and $take_back is what #7 does instead.
taken_back() {
  ready_to_ship
  unreviewed
  echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
  echo "Take back the button merge of pull request #5" > "$T/title"
  echo app/github-actions > "$T/ticket-author"
  mkdir -p factory/workflows
  echo "    timeout-minutes: 20" > factory/workflows/ci.yml
  main_holds
  echo "    timeout-minutes: 360" > factory/workflows/ci.yml
  git add -A && git commit --quiet -m "feat: wait longer (#5)"
  jq -n --arg commit "$(git rev-parse HEAD)" --arg by "${1:-repo-owner}" '{mergedBy: {login: $by}, mergeCommit: {oid: $commit}}' > "$T/taken.json"
  [ -z "${after_merge:-}" ] || { eval "$after_merge"; git add -A && git commit --quiet -m "feat: something later (#6)"; }
  eval "${take_back:-echo '    timeout-minutes: 20' > factory/workflows/ci.yml}"
  pull_request_holds
  installer ""
}
expect_held_for_the_owner() {
  expect_status 0
  expect_no_call "gh pr merge"
  expect_call "Both reviews passed, but this pull request changes what only the repo owner may decide:"
  expect_call "spend or limits: factory/workflows/ci.yml: timeout-minutes: 20"
  expect_call "gh pr edit 7 --add-label needs-human"
}

scenario "a take-back of a merge the owner made with the button waits to merge with no approval"
taken_back
gate
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->"
expect_calls 1 "gh workflow run merge-group.yml"
expect_no_call "Both reviews passed"
expect_no_call "--add-label needs-human"

scenario "the same change waits for the owner when its ticket takes nothing back"
taken_back
echo "Wait less for the checks" > "$T/title"
gate
expect_held_for_the_owner

scenario "it waits for the owner when the owner started the take-back: only the factory's own merges unapproved"
taken_back
echo "Take back pull request #5" > "$T/title"
gate
expect_held_for_the_owner

scenario "it waits for the owner when no workflow filed the ticket: an engineer cannot file its own way past the owner"
taken_back
echo app/claude > "$T/ticket-author"
gate
expect_held_for_the_owner

for by in app/github-actions someone-else; do
  scenario "it waits for the owner when $by merged the pull request it takes back, not the owner with the button"
  taken_back "$by"
  gate
  expect_held_for_the_owner
done

scenario "it waits for the owner when it changes a file the merge did not"
take_back="echo '    timeout-minutes: 20' > factory/workflows/ci.yml; echo '    timeout-minutes: 20' > factory/workflows/fix.yml" taken_back
gate
expect_held_for_the_owner

scenario "it waits for the owner when it leaves a file other than as main held it before the merge"
take_back="echo '    timeout-minutes: 30' > factory/workflows/ci.yml" taken_back
gate
expect_status 0
expect_no_call "gh pr merge"
expect_call "spend or limits: factory/workflows/ci.yml: timeout-minutes: 30"

scenario "it waits for the owner when it leaves part of the merge on main"
taken_back
git checkout --quiet --detach "$(jq -r .mergeCommit.oid "$T/taken.json")"
echo "    timeout-minutes: 360" > factory/workflows/fix.yml
git add -A && git commit --quiet --amend -m "feat: wait longer (#5)"
git branch --quiet --force main && git checkout --quiet main
jq --arg commit "$(git rev-parse HEAD)" '.mergeCommit.oid = $commit' "$T/taken.json" > "$T/taken.new" && mv "$T/taken.new" "$T/taken.json"
echo "    timeout-minutes: 20" > factory/workflows/ci.yml
pull_request_holds
installer ""
gate
expect_held_for_the_owner

scenario "it waits for the owner when a later merge changed the file, which going back would undo too"
after_merge="echo '    timeout-minutes: 90' > factory/workflows/ci.yml" taken_back
gate
expect_held_for_the_owner

scenario "it waits for the owner when main does not hold the commit GitHub names for the merge"
taken_back
jq '.mergeCommit.oid = "1234567812345678123456781234567812345678"' "$T/taken.json" > "$T/taken.new" && mv "$T/taken.new" "$T/taken.json"
gate
expect_held_for_the_owner

for words in "issue view 12 --json title,author" "pr view 5 --json mergedBy,mergeCommit"; do
  scenario "a take-back does not ship, and says why, when GitHub does not answer: $words"
  taken_back
  echo "$words" > "$T/fail"
  gate
  expect_failure
  expect_no_call "gh pr merge"
  expect_call "so whether this pull request takes back a merge made with the merge button is not known."
done

scenario "a pull request that changes nothing of the owner's is not asked what it takes back"
ready_to_ship
unreviewed
gate
expect_status 0
expect_no_call "gh issue view 12 --json title,author"

# GitHub refuses the whole diff of a very large pull request: the gate asks it for none (decisions M373).
lockfile() { seq "$1" "$(($1 + 30000))" > pnpm-lock.yaml; }

scenario "decides a pull request too large for GitHub's diff from git: a workflow's changed line is held, and shown"
ready_to_ship
unreviewed
echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
mkdir -p factory/workflows
echo "    timeout-minutes: 20" > factory/workflows/ci.yml
lockfile 1
main_holds
echo "    timeout-minutes: 360" > factory/workflows/ci.yml
lockfile 40000
pull_request_holds
installer ""
gate
expect_held_as_owners "spend or limits: factory/workflows/ci.yml: timeout-minutes: 20
spend or limits: factory/workflows/ci.yml: timeout-minutes: 360"
expect_no_call "gh pr diff"

scenario "adds to those that wait to merge a pull request too large for GitHub's diff, when its workflow's changed line is nothing the owner decides"
ready_to_ship
unreviewed
echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
mkdir -p factory/workflows
echo '        run: factory/scripts/say.sh' > factory/workflows/ci.yml
lockfile 1
main_holds
echo '        run: factory/scripts/say.sh "$PR"' > factory/workflows/ci.yml
lockfile 40000
pull_request_holds
installer ""
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"
expect_no_call "gh pr diff"

scenario "judges the pull request's own change, not what main gained since the branch left it"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx
echo three > TASTE.md
git add -A && git commit --quiet -m "docs: raise the bar"
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "judges the pull request's own change from a checkout of main's last commit alone, as an older ci.yml makes"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx
echo three > TASTE.md
git add -A && git commit --quiet -m "docs: raise the bar"
git push --quiet origin main
git rev-parse HEAD > .git/shallow
git reflog expire --expire=now --all && git prune --expire=now
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "adds to those that wait to merge a factory ticket's change to a workflow, when the installer that runs is the one main holds"
ready_to_ship
unreviewed
old='        run: factory/scripts/say.sh' new='        run: factory/scripts/say.sh "$PR"' factory_change factory/workflows/ci.yml
installer ""
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "holds a workflow change while the installer that runs is an older one, which would refuse it once merged"
ready_to_ship
unreviewed
old='        run: factory/scripts/say.sh' new='        run: factory/scripts/say.sh "$PR"' factory_change factory/workflows/ci.yml factory/scripts/ship.sh
installer " as it was"
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "Both reviews passed, but this pull request changes a workflow while the installer that runs is not yet the one \`main\` holds, and that one may refuse a change nobody approved:

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
expect_no_call "gh workflow run merge-group.yml"
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

scenario "adds to those that wait to merge a held change the owner has approved at this commit"
ready_to_ship
factory_change factory/scripts/merge-gate.sh
watch_git
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"
expect_no_call "git diff $(git rev-parse main)"

scenario "holds a factory ticket's change whose diff the rule cannot read, and shows why"
ready_to_ship
unreviewed
factory_change "factory/café.md"
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "owner-decides.sh: line 1 of the diff names a path git had to quote"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when git cannot read a factory ticket's diff"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh
watch_git 99 "diff $(git rev-parse main)"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: Git could not read this pull request's diff, so whether it changes what only the owner may decide is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when the ticket's labels cannot be read: that is not a factory ticket, nor a product one"
ready_to_ship
unreviewed
factory_change factory/scripts/ship.sh
echo "issue view 12 --json labels" > "$T/fail"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: GitHub did not return the labels of ticket #12, so whether it is a \`factory\` ticket, which may change the factory's files, is not known."

scenario "holds a product ticket's pull request that touches the factory's files for the owner, and says which files"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx factory/scripts/ship.sh CLAUDE.md
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_call "factory/scripts/ship.sh"
expect_first_line "gh pr comment 7 --body" "Approve this pull request: it merges as soon as the repo owner approves."
expect_no_call "apps/web/src/app/page.tsx"
expect_no_call "CLAUDE.md"
expect_call "gh pr edit 7 --add-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --add-label needs-human"

scenario "puts both reviewers' assumptions at the top of the comment that tells the owner, in the order each gave them"
ready_to_ship
unreviewed
change factory/decisions.md
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"GitHub accepts `queue: max` on a job.","if_wrong":"Every merge stops."}]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"The action takes `client-id`.","if_wrong":"No token is made."},{"assumes":"Neon answers 200 for a deleted branch.","if_wrong":"The step fails."},{"assumes":"A branch name has no space.","if_wrong":"A build is skipped."}]}'
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "gh pr comment 7 --body Approve this pull request: it merges as soon as the repo owner approves.

**Before you approve, what the reviewers could not check:**

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
change factory/decisions.md
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[]}'
gate
expect_status 0
expect_call "Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_no_call "could not check"

scenario "says nothing about assumptions after reviews from before there was a list"
ready_to_ship
unreviewed
change factory/decisions.md
comment "**Adam (architecture and taste): PASS**"$'\n\n'"Fits."
comment "**Ryan (correctness): PASS**"$'\n\n'"Correct."
gate
expect_status 0
expect_call "Both reviews passed, but this pull request changes files only a \`factory\` ticket may change, and it closes none:"
expect_no_call "could not check"

scenario "shows only each reviewer's latest list: an assumption settled in a fix round is gone"
ready_to_ship
unreviewed
change factory/decisions.md
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
change factory/decisions.md
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[]}'
body=$(jq -rn '"**Ryan (correctness): PASS**\n\nCarried forward from the review of abc1234: every commit since is a merge of `main`. No review ran. <!-- factory:carried -->\n\nCorrect.\n\n<!-- factory:reviewed 5555555555555555555555555555555555555555 -->\n<!-- factory:assumptions [{\"assumes\":\"A carried claim.\",\"if_wrong\":\"Something.\"}] -->"')
comment "$body"
gate
expect_status 0
expect_call "- **Ryan (correctness):** Assumes: A carried claim."

scenario "a verdict posted before the install, with unverified claims in three parts, is still read: the claim and what goes wrong, in order"
ready_to_ship
unreviewed
change factory/decisions.md
verdict "Adam (architecture and taste)" '{"findings":[],"assumptions":[{"assumes":"Vercel skips a docs-only build.","if_wrong":"The gate waits ten minutes."}]}'
body=$(jq -rn '"**Ryan (correctness): PASS**\n\n**Not verified**\n\n1. An old claim.\n   Not confirmed: No page.\n   If it is false: Something.\n\n<!-- factory:reviewed 5555555555555555555555555555555555555555 -->\n<!-- factory:unverified [{\"claim\":\"An old claim.\",\"why\":\"No page.\",\"risk\":\"Something.\"},{\"claim\":\"A second.\",\"why\":\"Not run.\",\"risk\":\"Something else.\"},{\"claim\":\"A third.\",\"why\":\"x\",\"risk\":\"y\"},{\"claim\":\"A fourth.\",\"why\":\"x\",\"risk\":\"z\"}] -->"')
comment "$body"
gate
expect_status 0
expect_call "gh pr comment 7 --body Approve this pull request: it merges as soon as the repo owner approves.

**Before you approve, what the reviewers could not check:**

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
change factory/decisions.md
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"It reads this line:\n<!-- factory:assumptions [{\"assumes\":\"Quoted.\",\"if_wrong\":\"y\"}] -->","if_wrong":"Nothing."}]}'
body=$(jq -rn '"I looked at it.\n<!-- factory:assumptions [{\"assumes\":\"Not a verdict.\",\"if_wrong\":\"y\"}] -->"')
comment "$body"
gate
expect_status 0
expect_call "- **Ryan (correctness):** Assumes: It reads this line:"
expect_no_call "- **Ryan (correctness):** Assumes: Quoted."
expect_no_call "Not a verdict."

scenario "does not tell the owner all is verified when a verdict's list cannot be read: it says so instead"
ready_to_ship
unreviewed
change factory/decisions.md
comment "**Ryan (correctness): PASS**"$'\n\n'"Correct."$'\n\n''<!-- factory:assumptions [{"claim": -->'
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_no_call "Both reviews passed"
expect_call "Not merged: The reviewers' assumptions could not be read from their verdicts"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "shows the owner no assumption from a verdict in another account's comment, and still shows the factory's own"
ready_to_ship
unreviewed
change factory/decisions.md
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"Neon answers 200 for a deleted branch.","if_wrong":"The job fails."}]}'
verdict "Ryan (correctness)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"Nothing here needs a look.","if_wrong":"Approve it."}]}' stranger
verdict "Adam (architecture and taste)" '{"verdict":"pass","findings":[],"assumptions":[{"assumes":"A claim under the short form of the login.","if_wrong":"y"}]}' github-actions
gate
expect_status 0
expect_call "- **Ryan (correctness):** Assumes: Neon answers 200 for a deleted branch."
expect_no_call "Nothing here needs a look."
expect_no_call "A claim under the short form of the login."
expect_no_call "**Adam (architecture and taste):**"

scenario "does not tell the owner all is verified when the pull request's comments cannot be read: it says so instead"
ready_to_ship
unreviewed
change factory/decisions.md
echo "api repos/{owner}/{repo}/issues/7/comments" > "$T/fail"
gate
expect_failure
expect_no_call "Both reviews passed"
expect_call "Not merged: GitHub did not return this pull request's comments, so the reviewers' assumptions cannot be shown to the owner"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "holds a protected pull request that closes no ticket, and labels no ticket"
ready_to_ship
unreviewed
echo "A person's own pull request." > "$T/body"
change factory/decisions.md
gate
expect_status 0
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "gh issue edit"

scenario "adds to those that wait to merge a protected pull request the owner has already approved at this commit"
ready_to_ship
change factory/decisions.md
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"
expect_no_call "Both reviews passed"

scenario "holds a protected pull request the owner approved at an older commit"
ready_to_ship
jq --arg old "$older" '.reviews[0].commit.oid = $old' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
change factory/decisions.md
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
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
  expect_no_call "gh workflow run merge-group.yml"
  expect_first_line "gh pr comment 7 --body" "Approve this pull request, or submit a \"Request changes\" review: an approval merges it, and a review sends it back to its engineer."
  expect_call "Both reviews passed, but the repo owner asked for changes to this pull request, so only they can say it is now right."
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

scenario "adds to those that wait to merge one whose request the owner took back with an approval, though of an older commit"
ready_to_ship
owner_said CHANGES_REQUESTED "$older" APPROVED "$older"
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "adds to those that wait to merge one the owner sent back once the owner approves this commit"
ready_to_ship
owner_said CHANGES_REQUESTED "$older" APPROVED
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"
expect_no_call "Both reviews passed"

scenario "adds to those that wait to merge one whose \"Request changes\" review the owner dismissed"
ready_to_ship
owner_said DISMISSED "$older"
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "adds to those that wait to merge one that only another reviewer sent back"
ready_to_ship
jq '.reviews = [{author: {login: "someone-else"}, state: "CHANGES_REQUESTED", commit: {oid: .headRefOid}}]' "$T/view.json" > "$T/view.new"; mv "$T/view.new" "$T/view.json"
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "says the protected files, not the owner's request, when a pull request the owner sent back touches them"
ready_to_ship
owner_said CHANGES_REQUESTED "$older"
change factory/decisions.md
gate
expect_status 0
expect_no_call "gh workflow run merge-group.yml"
expect_call "only a \`factory\` ticket may change"
expect_calls 1 "gh pr comment 7"

# The owner approved the pull request's last commit, which changes what only they decide; what follows adds a commit.
approved_change() {
  ready_to_ship
  old="${old:-one}" new="${new:-two}" factory_change "${1:-factory/scripts/merge-gate.sh}"
  approved=$head
}
on_the_pull_request() { git fetch --quiet origin refs/pull/7/head && git checkout --quiet --detach FETCH_HEAD; }
# merges_main [<what main gains> [<what the merge commit holds besides>]]: the pull request's next commit merges main.
merges_main() {
  eval "${1:-echo moved > moved.txt}"
  git add -A && git commit --quiet -m "docs: main moves"
  on_the_pull_request
  git merge --quiet --no-ff --no-commit main >/dev/null 2>&1 || true
  [ -z "${2:-}" ] || eval "$2"
  git add -A && git commit --quiet -m "Merge main"
  [ "$(git rev-list --parents -n 1 HEAD | wc -w)" -eq 3 ] || fail "the scenario did not make a merge commit"
  pushed
  owner_said APPROVED "$approved"
}
expect_asked_again() {
  case "$1" in *": "*) expect_held_as_owners "$1" ;; *) expect_held_as_owners "this rule: $1" ;; esac
  expect_call "The owner approved an older commit, \`${approved:0:7}\`, and that approval does not count for \`${head:0:7}\`: $2.

Both reviews passed"
}
expect_waits_to_merge() {
  expect_status 0
  expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->"
  expect_no_call "--add-label needs-human"
}
# What a fix round pushes: the commit that is checked out, with the owner's approval still of the older one.
fix_round_pushed() {
  git add -A && git commit --quiet --allow-empty -m "fix: what the reviewers found"
  pushed
  owner_said APPROVED "$approved"
}

scenario "a change the owner approved waits to merge, with no new approval, when the only commit since merges main"
approved_change
merges_main
gate
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->"
expect_no_call "--add-label needs-human"

scenario "it waits to merge after a second merge of main too, and when main changed the approved file far from the change"
ready_to_ship
echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
mkdir -p factory/scripts && seq 1 20 > factory/scripts/merge-gate.sh
main_holds
sed -i.bak 's/^10$/ten/' factory/scripts/merge-gate.sh && rm factory/scripts/merge-gate.sh.bak
pull_request_holds
approved=$head
merges_main '{ echo heading; echo; cat factory/scripts/merge-gate.sh; } > gate.new && mv gate.new factory/scripts/merge-gate.sh'
merges_main 'echo again > moved.txt'
gate
expect_status 0
expect_call "gh pr comment 7 --body <!-- factory:merge-queue added $head -->"

scenario "an approval stands through a conflict fix round: a merge of main settled by hand in another file, then a commit that changes another"
approved_change
merges_main 'echo theirs > factory/scripts/ship.sh' 'echo both > factory/scripts/ship.sh'
on_the_pull_request
echo three > apps.txt
fix_round_pushed
gate
expect_waits_to_merge
expect_no_call "Both reviews passed"

scenario "it stands for the product's bar too, when main changed the approved file far from the change"
ready_to_ship
mkdir -p apps/web && seq 1 20 > apps/web/eslint.config.mjs
main_holds
sed -i.bak 's/^10$/ten/' apps/web/eslint.config.mjs && rm apps/web/eslint.config.mjs.bak
pull_request_holds
approved=$head
merges_main '{ echo heading; echo; cat apps/web/eslint.config.mjs; } > lint.new && mv lint.new apps/web/eslint.config.mjs; echo theirs > ARCHITECTURE.md' 'echo both > ARCHITECTURE.md'
gate
expect_waits_to_merge

scenario "asks again, and says the approval was of an older commit, when a commit since changes something else the owner decides"
approved_change
on_the_pull_request
echo stricter > TASTE.md
fix_round_pushed
gate
expect_asked_again "the product's bar: TASTE.md
this rule: factory/scripts/merge-gate.sh" "what only the owner decides does not read the same at ${head:0:7} as at ${approved:0:7}"

scenario "asks again when a commit since changes the approved file once more, though the rule prints the same lines for both commits"
approved_change
on_the_pull_request
echo three > factory/scripts/merge-gate.sh
fix_round_pushed
gate
expect_asked_again factory/scripts/merge-gate.sh "what only the owner decides does not read the same at ${head:0:7} as at ${approved:0:7}"

scenario "asks again when a commit since moves the approved change within its file, to a place with the same lines around it"
ready_to_ship
mkdir -p apps/web && printf '%s\n' a b c one a b c one a b c > apps/web/eslint.config.mjs
main_holds
printf '%s\n' a b c two a b c one a b c > apps/web/eslint.config.mjs
pull_request_holds
approved=$head
on_the_pull_request
printf '%s\n' a b c one a b c two a b c > apps/web/eslint.config.mjs
fix_round_pushed
gate
expect_asked_again "the product's bar: apps/web/eslint.config.mjs" "what only the owner decides does not read the same at ${head:0:7} as at ${approved:0:7}"

scenario "asks again when the merge of main resolved a conflict in a file that only the owner decides"
approved_change
merges_main 'echo three > factory/scripts/merge-gate.sh' 'echo two > factory/scripts/merge-gate.sh'
gate
expect_asked_again factory/scripts/merge-gate.sh "what only the owner decides does not read the same at ${head:0:7} as at ${approved:0:7}"

scenario "asks again when the approval followed the owner's \"Request changes\": it was of the whole change, which a commit since changed"
approved_change
on_the_pull_request
echo three > apps.txt
fix_round_pushed
owner_said CHANGES_REQUESTED "$approved" APPROVED "$approved"
gate
expect_asked_again factory/scripts/merge-gate.sh "${head:0:7}, pushed since ${approved:0:7}, is not a merge of main"

scenario "an approval after a \"Request changes\" review the owner dismissed stands like any other"
approved_change
on_the_pull_request
echo three > apps.txt
fix_round_pushed
owner_said DISMISSED "$approved" APPROVED "$approved"
gate
expect_waits_to_merge

scenario "asks again when the approved commit is no longer in the pull request"
approved_change
on_the_pull_request
git commit --quiet --amend -m "the change, written again"
pushed
owner_said APPROVED "$approved"
gate
expect_asked_again factory/scripts/merge-gate.sh "the earlier commit, ${approved:0:7}, is no longer in the repo"

scenario "asks again for a workflow change after a commit that changes another file: the installer would not know the approval"
old="    timeout-minutes: 20" new="    timeout-minutes: 360" approved_change factory/workflows/ci.yml
installer ""
git add -A && git commit --quiet -m "ci: the installer"
on_the_pull_request
echo three > apps.txt
fix_round_pushed
gate
expect_asked_again "spend or limits: factory/workflows/ci.yml: timeout-minutes: 20
spend or limits: factory/workflows/ci.yml: timeout-minutes: 360" "${head:0:7}, pushed since ${approved:0:7}, is not a merge of main"

scenario "asks again for a workflow moved out of factory/workflows/ after a commit that changes another file: the installer would not know the approval"
ready_to_ship
echo '[{"name":"factory"},{"name":"in-progress"}]' > "$T/labels.json"
installer ""
echo "    timeout-minutes: 20" > factory/workflows/ci.yml
main_holds
mkdir -p factory/retired && mv factory/workflows/ci.yml factory/retired/ci.yml
pull_request_holds
approved=$head
on_the_pull_request
echo three > apps.txt
fix_round_pushed
gate
expect_asked_again "secrets or permissions: factory/workflows/ci.yml" "${head:0:7}, pushed since ${approved:0:7}, is not a merge of main"

scenario "does not ship, and says why, when git cannot read what the owner decides at the approved commit"
approved_change
on_the_pull_request
echo three > apps.txt
fix_round_pushed
watch_git 99 "--literal-pathspecs diff"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: Git could not read what only the owner decides at ${approved:0:7} and at ${head:0:7}, so whether the approval of ${approved:0:7} still stands is not known."

scenario "asks again when the owner sent it back after approving, though the only commit since merges main"
approved_change
merges_main
owner_said APPROVED "$approved" CHANGES_REQUESTED "$approved"
gate
expect_held_as_owners "this rule: factory/scripts/merge-gate.sh"

scenario "asks again for a workflow change that only merged main, while the installer that runs is an older one"
old="    timeout-minutes: 20" new="    timeout-minutes: 360" approved_change factory/workflows/ci.yml
installer " as it was"
git add -A && git commit --quiet -m "ci: a newer installer"
merges_main
gate
expect_held_as_owners "spend or limits: factory/workflows/ci.yml: timeout-minutes: 20
spend or limits: factory/workflows/ci.yml: timeout-minutes: 360"

scenario "a workflow change the owner approved before a merge of main waits to merge, when the installer that runs is the one main holds"
old="    timeout-minutes: 20" new="    timeout-minutes: 360" approved_change factory/workflows/ci.yml
installer ""
git add -A && git commit --quiet -m "ci: the installer"
merges_main
gate
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml"

scenario "does not ship, and says why, when git cannot compare the change with the one the owner approved"
approved_change
merges_main
watch_git 99 "rev-list --parents"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: Git could not compare this pull request's change with the one the owner approved at ${approved:0:7}, so whether that approval still stands is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when the reviews cannot be read: that is not a pull request the owner left alone"
ready_to_ship
echo "pr view 7 --json reviews" > "$T/fail"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_calls 1 "gh pr comment 7"
expect_call "Not merged: GitHub did not return this pull request's reviews, so whether the owner approved it or sent it back is not known."

scenario "fails when the owner could not be told that a pull request they sent back waits for them"
ready_to_ship
owner_said CHANGES_REQUESTED "$older"
echo "issue edit 12" > "$T/fail"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"

scenario "adds to those that wait to merge when fetching the pull request's commits fails twice and then answers"
ready_to_ship
change apps/web/src/app/page.tsx
watch_git 2 "fetch"
gate
expect_status 0
expect_calls 3 "git fetch --quiet origin refs/pull/7/head"
expect_calls 1 "gh workflow run merge-group.yml"

scenario "does not ship, and says why, when the pull request's commits cannot be fetched: that is not a pull request with no protected path"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx
watch_git 99 "fetch"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_calls 1 "gh pr comment 7"
expect_call "Not merged: GitHub did not return this pull request's commits, so what it changes is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship, and says why, when the commit to judge is not one the pull request holds"
ready_to_ship
unreviewed
change apps/web/src/app/page.tsx
head=$older
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_call "Not merged: Git could not list the files this pull request changes, so whether it needs a person is not known."
expect_call "gh pr edit 7 --add-label needs-human"

scenario "does not ship a protected pull request, and says why, when its reviews cannot be read"
ready_to_ship
change factory/decisions.md
echo "pr view 7 --json reviews" > "$T/fail"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_calls 1 "gh pr comment 7"
expect_call "Not merged: GitHub did not return this pull request's reviews"

scenario "fails when the owner could not be told that a protected pull request waits for them"
ready_to_ship
unreviewed
change factory/decisions.md
echo "pr comment 7" > "$T/fail"
gate
expect_failure
expect_no_call "gh workflow run merge-group.yml"

scenario "asks six times, then fails and asks a person to start the workflow, when merge-group.yml cannot be started: the pull request keeps its place"
ready_to_ship
echo "workflow run merge-group.yml" > "$T/fail"
gate
expect_failure
expect_first_line "gh pr comment 7 --body Start the \`merge-group\` workflow from the Actions tab: this pull request waits to merge, and that run tests and merges" "it."
expect_calls 6 "gh workflow run merge-group.yml"
expect_no_call "Approve this pull request again"
expect_call "gh pr edit 7 --add-label needs-human"
