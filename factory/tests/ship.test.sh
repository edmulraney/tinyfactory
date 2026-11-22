#!/usr/bin/env bash
# Tests for ship.sh: merges a group that was tested with main as it is, never twice, and never fails in silence.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/ready-to-ship.sh"

export GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/

scenario "ships: merges, tidies the labels, confirms the deploy and marks the ticket deployed"
ready_to_ship
ship
expect_status 0
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit $head"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_call "gh issue close 12"
expect_call "curl -fsS --max-time 10 https://myapp.example/api/health"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "gh workflow run"
expect_no_call "gh run rerun"

scenario "the place the merge freed goes to a ticket that waits with ready"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
ship
expect_status 0
expect_calls 1 "gh workflow run"
expect_call "gh workflow run implement.yml -f issue=20"
expect_output "started the build of issue #20, which waited with ready"
[ "$(grep -n '^gh workflow run implement.yml' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue edit 12 --remove-label in-progress' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the waiting ticket to be started after the merged one gave up its place"

scenario "the merged ticket is closed and loses in-progress before the queue is read"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
ship
expect_status 0
read_at=$(grep -n -m 1 -F 'issues?state=open&labels=ready' "$T/calls" | cut -d: -f1)
[ "$(grep -n '^gh issue close 12' "$T/calls" | cut -d: -f1)" -lt "$read_at" ] || fail "expected ticket #12 to be closed before the queue was read"
[ "$(grep -n '^gh issue edit 12 --remove-label in-progress' "$T/calls" | cut -d: -f1)" -lt "$read_at" ] || fail "expected in-progress to come off ticket #12 before the queue was read"

scenario "a ticket that could not be closed is named on the pull request, and the waiting ticket is still started"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
echo "issue close 12" > "$T/fail"
ship
expect_status 1
expect_call "gh workflow run implement.yml -f issue=20"
expect_call "- ticket #12 could not be closed"

scenario "the idea whose last open slice the merged ticket was is closed"
ready_to_ship
echo 5 > "$T/parent-12"
echo '{"number":5,"state":"open","labels":[{"name":"idea"}]}' > "$T/idea.json"
echo '[{"number":11,"state":"closed"},{"number":12,"state":"open"}]' > "$T/slices.json"
ship
expect_status 0
expect_call "gh issue close 5"

scenario "the idea of the merged ticket stays open while another slice of it is open"
ready_to_ship
echo 5 > "$T/parent-12"
echo '{"number":5,"state":"open","labels":[{"name":"idea"}]}' > "$T/idea.json"
echo '[{"number":11,"state":"open"},{"number":12,"state":"closed"}]' > "$T/slices.json"
ship
expect_status 0
expect_no_call "gh issue close 5"

scenario "an idea that could not be closed is named on the pull request, and the waiting ticket is still started"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
echo 5 > "$T/parent-12"
echo "api repos/{owner}/{repo}/issues/5 " > "$T/fail"
ship
expect_status 1
expect_call "gh workflow run implement.yml -f issue=20"
expect_call "- whether ticket #12 was the last open slice of an idea is not known, so no idea was closed"

scenario "a waiting ticket that comes after the merged ticket is started, though GitHub still lists that ticket as open"
ready_to_ship
echo '[{"number":20,"body":"After #12\n"}]' > "$T/ready.json"
ship
expect_status 0
expect_call "gh workflow run implement.yml -f issue=20"
expect_no_call "gh issue comment 20"

scenario "a waiting ticket that cannot be started is said on the pull request, and the merge stands"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
echo "workflow run implement.yml" > "$T/fail"
ship
expect_status 1
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "the tickets that wait with \`ready\` were not all started"

scenario "a merge that leaves a rule file over its word budget files the ticket that cuts it, and its build starts"
ready_to_ship
echo "2 TASTE.md" > "$T/on-main/repo/factory/rule-files.txt"
# GitHub lists the ticket filed, #30, among those labelled ready.
echo '[{"number":30}]' > "$T/ready.json"
ship
expect_status 0
expect_calls 1 "gh issue create"
expect_call 'gh issue create --title Cut `TASTE.md` to budget --label factory --label ready '
expect_call "gh workflow run implement.yml -f issue=30"
[ "$(grep -n -m 1 '^gh issue create --title Cut' "$T/calls" | cut -d: -f1)" -lt "$(grep -n -m 1 -F 'issues?state=open&labels=ready' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the ticket to be filed before the queue was read"

scenario "a merge that leaves every rule file in its word budget files no ticket"
ready_to_ship
ship
expect_status 0
expect_call "gh api repos/{owner}/{repo}/tarball/main"
expect_no_call "gh issue create"

scenario "still ships, and passes, when the rule files on main cannot be read: the log says so, and when the ticket is filed"
ready_to_ship
echo "2 TASTE.md" > "$T/on-main/repo/factory/rule-files.txt"
echo '[{"number":20}]' > "$T/ready.json"
echo "api repos/{owner}/{repo}/tarball/main" > "$T/fail"
ship
expect_status 0
expect_output "Not every rule file over its word budget got its ticket (\`cut-rule-files.sh\` failed); the next merge files it."
expect_no_call "gh issue create"
expect_call "gh workflow run implement.yml -f issue=20"
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "but not everything that follows a merge finished"

# never_started <run> <workflow> <what GitHub said of its one job, which reached no step>: one run older than those there.
never_started() {
  mkdir -p "$T/first-jobs" "$T/annotations"
  [ -e "$T/latest-runs.json" ] || echo '[]' > "$T/latest-runs.json"
  jq -c --argjson id "$1" --arg name "$2" '. + [{id: $id, name: $name, display_title: "the title of \($id)", run_attempt: 1, conclusion: "failure"}]' \
    "$T/latest-runs.json" > "$T/latest-runs.new"
  mv "$T/latest-runs.new" "$T/latest-runs.json"
  echo "[{\"id\":${1}1,\"conclusion\":\"failure\",\"steps\":[]}]" > "$T/first-jobs/$1"
  printf '%s' "$3" > "$T/annotations/${1}1"
}
billing="The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"

scenario "a merge runs again a run refused for billing, before it starts a waiting ticket, and no run that never started for another reason"
ready_to_ship
echo '[{"number":20}]' > "$T/ready.json"
never_started 505 implement "$billing"
never_started 504 retro "The job was not acquired by a runner."
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_calls 1 "gh run rerun"
expect_call "gh run rerun 505 --failed"
expect_output "running again: 505 implement: the title of 505"
[ "$(grep -n '^gh run rerun 505' "$T/calls" | cut -d: -f1)" -lt "$(grep -n -m 1 -F 'issues?state=open&labels=ready' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the refused run to be run again before the queue was read"
[ "$(grep -n '^gh run rerun 505' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh pr merge 7' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the refused run to be run again after the merge"

for words in "api --method GET repos/{owner}/{repo}/actions/runs -f created" "run rerun 505"; do
  scenario "still ships, and passes, when the refused runs are not all run again: the log says so, and when they will be: gh $words"
  ready_to_ship
  echo '[{"number":20}]' > "$T/ready.json"
  never_started 505 implement "$billing"
  echo "$words" > "$T/fail"
  ship
  expect_status 0
  expect_output "The jobs GitHub refused for billing were not all run again (\`rerun-refused.sh\` failed); \`flag-idle.yml\` runs them again at its next look."
  expect_call "gh workflow run implement.yml -f issue=20"
  expect_call "gh issue edit 12 --add-label deployed"
  expect_no_call "but not everything that follows a merge finished"
done

scenario "merges exactly the commit that was checked, never a later push"
ready_to_ship
ship 7:1234567
expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit 1234567"

scenario "ships a pull request that closes no ticket, and labels no ticket"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh pr comment 7 --body Deployed:"
expect_no_call "gh issue edit"

scenario "says on the ticket what it cost, in four lines, after everything else"
ready_to_ship
ship
expect_status 0
expect_call "gh issue comment 12 --body - **Claude usage:** \$1.50 at API prices, in 1 session on claude-fable-5-2"
expect_call "- **Actions minutes:** 4, in 1 run"
expect_call "- **Fix rounds:** 0"
expect_call "- **Ready to merged:** 30 min"
[ "$(tail -n 4 "$T/calls" | head -n 1 | cut -c1-20)" = "gh issue comment 12 " ] || fail "expected the cost comment to be the last call"

scenario "still ships, and passes, when what the ticket cost cannot be worked out: the log says so and no comment is posted"
ready_to_ship
echo "api repos/{owner}/{repo}/git/trees/sessions" > "$T/fail"
ship
expect_status 0
expect_call "gh issue edit 12 --add-label deployed"
expect_output "what ticket #12 cost could not be worked out, so it was not posted on it and its measures were not recorded"
expect_no_call "gh issue comment"
[ -z "$(recorded)" ] || fail "expected no line of measures"
expect_no_call "but not everything that follows a merge finished"

scenario "still passes when the cost cannot be posted on the ticket, and the log says so"
ready_to_ship
echo "issue comment 12" > "$T/fail"
ship
expect_status 0
expect_output "what ticket #12 cost could not be posted on it"
expect_no_call "but not everything that follows a merge finished"

scenario "a pull request that closes no ticket gets no cost comment and no line of measures"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_no_call "gh issue comment"
expect_no_call "git/trees"
[ -z "$(recorded)" ] || fail "expected no line of measures"

scenario "a merge appends one line of measures to the record on the sessions branch, before the cost comment"
ready_to_ship
echo '[{"number":15,"labels":[{"name":"proposal"}],"body":"Seen in pull request #7"}]' > "$T/issues.json"
ship
expect_status 0
[ "$(recorded | wc -l | tr -d ' ')" = 1 ] || fail "expected one line, found: $(recorded)"
[ "$(recorded | jq -c '[.pr, .issue, .cost_usd, .minutes, .fix_rounds, .seconds, .stops, .opened]')" = "[7,12,1.5,4,0,1800,0,[15]]" ] \
  || fail "expected the ticket's measures, found: $(recorded)"
expect_calls 1 "git/trees/sessions"
[ "$(tail -n 4 "$T/calls" | head -n 1 | cut -c1-20)" = "gh issue comment 12 " ] || fail "expected the cost comment to be the last call"

scenario "a line of measures that cannot be written is said, and does not stop the merge or the cost comment"
ready_to_ship
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/github/owner/myapp.git/hooks/pre-receive"
chmod +x "$T/github/owner/myapp.git/hooks/pre-receive"
ship
expect_status 0
expect_output "The measures of ticket #12 could not be written to measures.jsonl on the sessions branch, so no table will hold them."
expect_output "the measures of ticket #12 were not recorded"
[ -z "$(recorded)" ] || fail "expected no line of measures"
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh issue comment 12 --body - **Claude usage:**"
expect_no_call "but not everything that follows a merge finished"

scenario "merges nothing when the pull request cannot be read: it keeps its place, nobody is told, and its group is tested again"
ready_to_ship
echo "pr view 7 --json body" > "$T/fail"
ship
expect_status 0
expect_output "Could not read pull request #7"
expect_output "GitHub did not return the description of pull request #7, so the ticket it closes is not known"
expect_no_call "gh pr merge"
expect_no_call "gh pr comment 7"
expect_no_call "gh pr edit 7"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

scenario "tries a refused merge three times, then leaves the pull request its place, tells nobody and starts the test again"
ready_to_ship
echo "pr merge 7" > "$T/fail"
ship
expect_status 0
expect_calls 3 "gh pr merge 7"
expect_output "GitHub failed or refused the merge of pull request #7 three times, and \`main\` holds no commit for it. Its last answer was: gh: failed: pr merge 7"
expect_no_call "gh pr comment 7"
expect_no_call "gh pr edit 7 --add-label needs-human"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_no_call "gh issue edit"
expect_no_call "curl"

scenario "a fault that stays for three tries reaches a person, who is asked to start a workflow and is given no command"
ready_to_ship
echo "pr merge 7" > "$T/fail"
found passed "7:$head"
run env TRY=3 "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_failure
expect_no_call "gh workflow run merge-group.yml"
expect_first_line "gh pr comment 7 --body Start the \`merge-group\` workflow from the Actions tab: this pull request still waits to merge, and that run tests and merges" "it."
expect_call "Its last answer was: gh: failed: pr merge 7 --squash --delete-branch --match-head-commit $head, on each of three tries."
expect_call "gh pr edit 7 --add-label needs-human"
expect_no_call "factory:merge-queue removed"
expect_no_call "Approve this pull request again"

scenario "still confirms the deploy when the labels could not be tidied, then fails and names them on the pull request"
ready_to_ship
printf 'pr edit 7\nissue edit 12 --remove-label\n' > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- the \`needs-human\` label could not be taken off this pull request"
expect_call "- the \`in-progress\` and \`needs-human\` labels could not be taken off ticket #12"

scenario "says merged, and that the deploy was not checked, when the merge commit cannot be read anywhere"
ready_to_ship
echo "pr view 7 --json mergeCommit" > "$T/fail"
ship
expect_failure
expect_calls 1 "gh pr merge 7"
expect_call "- GitHub did not return the merge commit, so the deploy was not checked"
expect_no_call "gh pr comment 7 --body Deployed"
expect_no_call "--add-label deployed"

scenario "takes the merge commit from main when the pull request does not give it"
ready_to_ship
echo "pr view 7 --json mergeCommit" > "$T/fail"
echo "$put_on_main" > "$T/merge"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."

scenario "starts no retro after a run that needed one fix round"
ready_to_ship
echo "[$round,{\"id\":3,\"user\":{\"login\":\"repo-owner\"},\"body\":\"Looks good.\"}]" > "$T/rounds"
ship
expect_status 0
expect_no_call "gh workflow run retro.yml"

scenario "starts a retro after a run that needed two fix rounds"
ready_to_ship
echo "[$round,$round]" > "$T/rounds"
ship
expect_status 0
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "starts a retro after a run the owner sent back, whose rounds are not among the three"
ready_to_ship
echo "[{\"id\":2,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:owner-round -->The owner's fix round: the engineer's session ran.\"}]" > "$T/rounds"
ship
expect_status 0
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "starts no retro after a clean run whose reviews only quote the fix-round marker"
ready_to_ship
jq -c '.user.login = "claude[bot]"' <<<"$round" > "$T/quoted"
echo "[{\"id\":3,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"**Ryan (correctness): PASS**\\nThe count reads <!-- factory:fix-round --> only at the start.\"},$(cat "$T/quoted")]" > "$T/rounds"
ship
expect_status 0
expect_no_call "gh workflow run retro.yml"

scenario "confirms the deploy and then fails, naming it, when the fix rounds cannot be counted: that is not a clean run"
ready_to_ship
echo "api repos/{owner}/{repo}/issues/7/comments?per_page=100 --paginate --jq .[] " > "$T/fail"
ship
expect_failure
expect_output "Could not read the comments of pull request #7 from GitHub"
expect_no_call "gh workflow run retro.yml"
expect_call "gh pr comment 7 --body Deployed"
expect_call "- the fix rounds could not be counted, so no retro was started"

scenario "fails when the retro could not be started"
ready_to_ship
echo "[$round,$round]" > "$T/rounds"
echo "workflow run retro.yml" > "$T/fail"
ship
expect_failure
expect_call "- the retro could not be started"

# a_tweak <minutes> <dollars>: ticket #12 is a tweak, whose budget is that; the pull request cost 4 minutes and $1.50.
a_tweak() {
  echo '[{"event":"labeled","label":{"name":"tweak"},"created_at":"2026-11-16T08:00:00Z"},
         {"event":"labeled","label":{"name":"ready"},"created_at":"2026-11-16T08:30:00Z"}]' > "$T/events-12.json"
  printf 'tweak %s %s\n' "$1" "$2" > "$scripts/../budget.txt"
}

scenario "a pull request within both budgets: the cost comment gives each beside its figure, and no retro starts"
ready_to_ship
a_tweak 4 1.50
ship
expect_status 0
expect_call "- **Claude usage:** \$1.50 at API prices, in 1 session on claude-fable-5-2; the budget for a \`tweak\` ticket is \$1.50"
expect_call "- **Actions minutes:** 4, in 1 run; the budget for a \`tweak\` ticket is 4 minutes"
expect_no_call "gh workflow run retro.yml"

scenario "a pull request over its budget of minutes starts one retro, after the cost comment says so"
ready_to_ship
a_tweak 3 12
ship
expect_status 0
expect_call "- **Actions minutes:** 4, in 1 run; over the budget of 3 minutes for a \`tweak\` ticket"
expect_call "claude-fable-5-2; the budget for a \`tweak\` ticket is \$12.00"
expect_calls 1 "gh workflow run retro.yml -f pr=7"
[ "$(grep -n '^gh workflow run retro.yml' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh issue comment 12 ' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the retro to start after the cost comment"

scenario "a pull request over its budget of cost starts one retro"
ready_to_ship
a_tweak 60 1.49
ship
expect_status 0
expect_call "claude-fable-5-2; over the budget of \$1.49 for a \`tweak\` ticket"
expect_call "- **Actions minutes:** 4, in 1 run; the budget for a \`tweak\` ticket is 60 minutes"
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "a pull request over both budgets after two fix rounds starts one retro, not two"
ready_to_ship
a_tweak 3 1
echo "[$round,$round]" > "$T/rounds"
ship
expect_status 0
expect_calls 1 "gh workflow run retro.yml -f pr=7"

scenario "a ticket whose type has no budget: the cost comment gives no budget, and no retro starts"
ready_to_ship
a_tweak 3 1
printf 'bug 3 1\n' > "$scripts/../budget.txt"
ship
expect_status 0
expect_call "- **Actions minutes:** 4, in 1 run"
expect_no_call "budget"
expect_no_call "gh workflow run retro.yml"

scenario "fails when the retro of a pull request over its budget could not be started"
ready_to_ship
a_tweak 3 1
echo "workflow run retro.yml" > "$T/fail"
ship
expect_failure
expect_call "- the retro of a pull request over its budget could not be started"

scenario "a budget that cannot be read: the cost is not posted, no retro starts, and the merge stands"
ready_to_ship
a_tweak 3 1
echo "tweak sixty 12" > "$scripts/../budget.txt"
ship
expect_status 0
expect_output 'factory/budget.txt:1: a line is "<type> <minutes> <dollars>", and this is not: tweak sixty 12'
expect_output "what ticket #12 cost could not be worked out"
expect_no_call "gh issue comment"
expect_no_call "gh workflow run retro.yml"

a_changed_workflow_waits() {
  echo '[{"number":40}]' > "$T/waiting.json"
  echo '[{"user":{"login":"github-actions[bot]"},"created_at":"2026-11-16T10:00:00Z","body":"Installed in abc1234\n\n<!-- factory:installed ci.yml -->"}]' > "$T/rounds-40"
}

scenario "after a merge, starts a retro for the first run of a workflow an earlier pull request changed"
ready_to_ship
a_changed_workflow_waits
echo '[{"id":901,"created_at":"2026-11-16T10:05:00Z","conclusion":"success","html_url":"https://github.example/runs/901"}]' > "$T/first-runs.json"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh workflow run retro.yml -f pr=40 -f run=901"
expect_call "gh pr comment 40 --body <!-- factory:first-run ci.yml -->"
expect_call "gh pr edit 40 --remove-label proof"
expect_no_call "a retro was not started"

scenario "confirms the deploy and then fails, saying so on the merged pull request, when the first runs could not be looked for"
ready_to_ship
a_changed_workflow_waits
echo "api --method GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs" > "$T/fail"
ship
expect_status 1
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed:"
expect_no_call "gh workflow run retro.yml"
expect_call "- a retro was not started for every first run of a changed workflow"

scenario "a merge with no changed workflow waiting for its first run asks once and is told nothing"
ready_to_ship
ship
expect_status 0
expect_calls 1 "gh pr list --state merged --label proof"
expect_no_call "a retro was not started"

scenario "starts the workflow installer after a merge that changed a workflow's source"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"},{"filename":"factory/decisions.md"}]' > "$T/files.json"
ship
expect_status 0
expect_call "gh workflow run install-workflows.yml -f pr=7"

scenario "does not start the installer for a file that only looks like a workflow's source"
ready_to_ship
echo '[{"filename":"docs/factory/workflows/ci.yml"},{"filename":".github/workflows/ci.yml"}]' > "$T/files.json"
ship
expect_status 0
expect_no_call "gh workflow run install-workflows.yml"

scenario "confirms the deploy and then fails when the installer could not be started"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"},{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files.json"
echo "workflow run install-workflows.yml" > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- the workflow installer could not be started, so the changed workflows are not installed"

scenario "confirms the deploy and then fails when the changed files could not be listed"
ready_to_ship
# Both listings fail, apply-setup.sh's and ship.sh's own: neither may read as "changed nothing".
echo 'printf "api repos/owner/myapp/pulls/7/files\napi repos/{owner}/{repo}/pulls/7/files\n" > "$T/fail"' > "$T/merge"
ship
expect_status 1
expect_no_output "nothing to apply"
expect_no_call "gh workflow run install-workflows.yml"
expect_call "gh pr comment 7 --body Deployed:"

scenario "fails when only its own listing of the changed files failed: that is not a merge that changed no workflow"
ready_to_ship
echo 'echo "api repos/{owner}/{repo}/pulls/7/files" > "$T/fail"' > "$T/merge"
ship
expect_status 1
expect_output "changed no setup script; nothing to apply"
expect_call "gh pr comment 7 --body Deployed:"

scenario "confirms the deploy and then fails when the setup changes could not be applied"
ready_to_ship
echo "repo view" > "$T/fail"
ship
expect_status 1
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- the changes to setup scripts, if there were any, could not be applied"

scenario "says the deploy was not confirmed when there is no production to ask"
ready_to_ship
PRODUCTION_URL="" ship
expect_status 0
expect_output "merged; no PRODUCTION_URL is set, so the deploy was not confirmed"
expect_no_call "curl"
expect_no_call "--add-label deployed"
expect_no_call "gh pr comment"

scenario "after a merge and a failed deploy check, fails with one comment that says merged and names the deploy check, and marks nothing deployed"
ready_to_ship
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
ship
expect_status 1
expect_calls 1 "gh pr merge 7"
expect_calls 1 "gh pr comment 7"
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- the deploy check: production at https://myapp.example/ did not report abcdef0 within 10 minutes. Check the Vercel deployment"
expect_no_call "Not merged"
expect_no_call "gh pr comment 7 --body Deployed"
expect_no_call "--add-label deployed"

scenario "fails and marks nothing deployed when production cannot be reached"
ready_to_ship
rm "$T/health"
ship
expect_status 1
expect_call "gh pr comment 7 --body Merged as abcdef0, but not everything"
expect_call "- the deploy check: production at https://myapp.example/ did not report"
expect_no_call "--add-label deployed"

scenario "passes without waiting for production after a merge that changes no app code, says there was nothing to deploy, and does not mark the ticket deployed"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"},{"filename":"README.md"}]' > "$T/files.json"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
ship
expect_status 0
expect_no_call "curl"
expect_no_call "gh api repos/{owner}/{repo}/commits/$merged/statuses"
expect_call "gh pr comment 7 --body Merged as abcdef0. Nothing to deploy: this pull request changes no app code, so production at https://myapp.example/ serves the app it did before."
expect_no_call "not everything that follows a merge finished"
expect_no_call "--add-label deployed"

scenario "fails when Vercel skipped the deployment and the files the merge changes cannot be read"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
echo "api repos/owner/myapp/pulls/7/files" > "$T/fail"
ship
expect_status 1
expect_call "- the deploy check: Vercel skipped the deployment of this commit"
expect_no_call "Nothing to deploy"
expect_no_call "--add-label deployed"

scenario "fails when the merge changes no app code and the comment saying so cannot be posted"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
echo "pr comment 7 --body Merged as abcdef0. Nothing to deploy" > "$T/fail"
ship
expect_status 1
expect_output "the comment saying so could not be posted"
expect_no_call "--add-label deployed"

scenario "says at once that Vercel skipped the deployment of a merge that changes app code, and does not mark the ticket deployed"
ready_to_ship
echo '{"commit":"0000000000000000000000000000000000000000"}' > "$T/health"
echo '[{"context":"Vercel","state":"success","description":"Skipped - Not affected"}]' > "$T/statuses.json"
ship
expect_status 1
expect_calls 1 "curl "
expect_call "gh api repos/{owner}/{repo}/commits/$merged/statuses"
expect_call "- the deploy check: Vercel skipped the deployment of this commit"
expect_no_call "did not report abcdef0 within 10 minutes"
expect_no_call "--add-label deployed"

scenario "fails when the deploy was confirmed and the ticket could not be marked deployed"
ready_to_ship
echo "issue edit 12 --add-label deployed" > "$T/fail"
ship
expect_failure

scenario "fails when the deploy was confirmed and the comment could not be posted"
ready_to_ship
echo "pr comment 7" > "$T/fail"
ship
expect_failure
expect_call "gh issue edit 12 --add-label deployed"


scenario "merges when each read fails twice and then answers"
ready_to_ship
printf '2 %s\n' "pr view 7 --json body" "api repos/{owner}/{repo}/commits/main" \
  "api repos/{owner}/{repo}/commits?sha=main" "pr view 7 --json mergeCommit" > "$T/flaky"
ship
expect_status 0
expect_output "HTTP 502: Bad Gateway: api repos/{owner}/{repo}/commits/main"
expect_calls 3 "gh api repos/{owner}/{repo}/commits/main"
expect_calls 1 "gh pr merge 7"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"
expect_calls 1 "gh pr comment 7"

scenario "after a merge call that failed though GitHub made the commit, merges no second time, sets the labels and checks the deploy"
ready_to_ship
echo "$put_on_main; echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1" > "$T/merge"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_call "gh issue close 12"
expect_call "curl -fsS --max-time 10 https://myapp.example/api/health"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "gh pr view 7 --json mergeCommit"
expect_calls 1 "gh pr comment 7"

scenario "does not merge a pull request whose commit main already holds, when it is shipped again, and finishes what follows a merge"
ready_to_ship
on_main
echo app/github-actions > "$T/merged-by"
ship
expect_status 0
expect_output "\`main\` already holds the commit of pull request #7, abcdef0; not merged a second time"
expect_no_call "gh pr merge"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh issue edit 12 --add-label deployed"

scenario "leaves for a person a pull request GitHub still shows as open though main holds its commit"
ready_to_ship
on_main
echo OPEN > "$T/state"
ship
expect_status 1
expect_no_call "gh pr merge"
expect_call "gh issue edit 12 --add-label deployed"
expect_first_line "gh pr comment 7 --body" "Close this pull request and its ticket by hand: the factory leaves both open."
expect_call "Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- GitHub does not show this pull request as merged, though \`main\` holds its commit. It was not merged a second time"
expect_call "gh pr edit 7 --add-label needs-human"

scenario "merges on the second call when the first failed and left nothing on main"
ready_to_ship
echo 'if [ "$(grep -c "^gh pr merge" "$T/calls")" -eq 1 ]; then echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; fi' > "$T/merge"
ship
expect_status 0
expect_calls 2 "gh pr merge 7"
expect_calls 2 "gh api repos/{owner}/{repo}/commits?sha=main"
expect_call "gh issue edit 12 --add-label deployed"

scenario "does not call the merge again when main cannot be read after a merge call that failed: the group is tested again"
ready_to_ship
echo 'echo "api repos/{owner}/{repo}/commits?sha=main" > "$T/fail"; echo "gh: HTTP 502: Bad Gateway" >&2; exit 1' > "$T/merge"
ship
expect_status 0
expect_calls 1 "gh pr merge 7"
expect_no_call "gh pr comment 7"
expect_output "GitHub did not list the commits on \`main\`, so whether pull request #7 is already merged there is not known"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_no_call "curl"

scenario "does not merge when main cannot be read before the merge: the group is tested again"
ready_to_ship
echo "api repos/{owner}/{repo}/commits?sha=main" > "$T/fail"
ship
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh pr comment 7"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

scenario "ends with a failing exit and the reason in the log when, on the third try, GitHub takes no comment either"
ready_to_ship
printf '%s\n' "api repos/{owner}/{repo}/commits/main" "pr comment 7" "pr edit 7" > "$T/fail"
found passed "7:$head"
run env TRY=3 "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_failure
expect_output "Not merged: GitHub did not say which commit \`main\` is at, so nothing shows its group was tested with it, on each of three tries."
expect_output "and pull request #7 could not be told so"
expect_output "and needs-human could not be added to pull request #7"
expect_no_call "gh pr merge"


# not_begun: the merge job after a begin job that failed, with #7 and #8 waiting to merge.
not_begun() {
  ready_to_ship
  also_ships 8 13
  found passed "7:$head" "8:$head_8"
  rm "$T/result.json"
  run "$scripts/ship.sh" --not-begun
}

scenario "a group that could not be begun is begun again: each pull request keeps its place and nobody is told"
not_begun
expect_status 0
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_output "Each of 7:$head 8:$head_8 keeps its place"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"
expect_no_call "gh pr merge"

scenario "a group that could not be begun on the third try reaches a person on each pull request that waits, and the job starts no second retro"
TRY=3 not_begun
expect_status 0
expect_no_call "gh workflow run"
for number in 7 8; do
  expect_call "gh pr comment $number --body Start the \`merge-group\` workflow from the Actions tab"
  expect_call "gh pr edit $number --add-label needs-human"
done
expect_call "Not merged: the group it waits in could not be begun, on each of three tries."
expect_no_call "gh pr merge"

scenario "a group that could not be begun and cannot be started again reaches a person on the first try"
ready_to_ship
also_ships 8 13
found passed "7:$head" "8:$head_8"
echo "workflow run merge-group.yml" > "$T/fail"
run "$scripts/ship.sh" --not-begun
expect_status 0
expect_call "gh pr comment 7 --body Start the \`merge-group\` workflow from the Actions tab"
expect_call "Not merged: the group it waits in could not be begun, and \`merge-group.yml\` could not be started to test its group again."
expect_call "gh pr edit 8 --add-label needs-human"

scenario "when no group was begun and GitHub does not say which pull requests wait, the run is started again all the same"
ready_to_ship
echo "pr list --state open --base main" > "$T/fail"
run "$scripts/ship.sh" --not-begun
expect_status 0
expect_calls 6 "gh pr list --state open --base main"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_no_call "gh pr comment"

scenario "fails when, on the third try, no group was begun and GitHub does not say which pull requests wait: nobody was told"
ready_to_ship
echo "pr list --state open --base main" > "$T/fail"
run env TRY=3 "$scripts/ship.sh" --not-begun
expect_failure
expect_output "GitHub did not say which pull requests wait to merge, so none was told"
expect_no_call "gh workflow run"

scenario "does nothing when no group was begun and no pull request waits to merge"
ready_to_ship
run "$scripts/ship.sh" --not-begun
expect_status 0
expect_output "no pull request waits to merge"
expect_no_call "gh workflow run"
expect_no_call "gh pr comment"

scenario "after a merge, starts a fix round for each open factory pull request in conflict, and for no other"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 9 app/claude MERGEABLE
also_open 10 repo-owner CONFLICTING
also_open 11 app/claude CONFLICTING
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"
expect_no_call "gh workflow run fix.yml -f pr=9"
expect_no_call "gh workflow run fix.yml -f pr=10"
expect_calls 2 "gh workflow run"
expect_output "a fix round was started for pull request #8"
expect_no_call "gh run rerun"
expect_call "gh pr comment 7 --body Deployed:"

waits() {
  jq --argjson n "$1" --arg head "$2" '. + [{number: $n, headRefOid: $head, isDraft: false, reviews: []}]' "$T/queue.json" > "$T/queue.new"
  mv "$T/queue.new" "$T/queue.json"
}

scenario "after a merge, starts no fix round for a pull request in conflict that waits to merge: the test of its group says whether it fits"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
found passed "7:$head"
waits 8 "$(cat "$T/heads/8")"
run "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_status 0
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_output "pull request #8 conflicts with main as GitHub merges it, and waits to merge"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "a pull request in conflict that waited to merge at an earlier commit gets its fix round"
ready_to_ship
also_open 8 app/claude CONFLICTING
found passed "7:$head"
waits 8 "$older"
run "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_status 0
expect_call "gh workflow run fix.yml -f pr=8"

scenario "GitHub does not say which pull requests wait to merge after the merge: no fix round is started blind, and the merged one is told"
ready_to_ship
also_open 8 app/claude CONFLICTING
# From the merge on, GitHub fails the list that merge-queue.sh reads.
echo 'echo "pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews" >> "$T/fail"' > "$T/merge"
ship
expect_status 1
expect_call "gh pr merge 7 "
expect_no_call "gh workflow run fix.yml"
expect_call "a fix round was not started for every open pull request these merges left in conflict"

scenario "starts the fix round for a conflicting pull request without a ci run: its head, pushed in conflict, has none"
ready_to_ship
also_open 8 app/claude CONFLICTING
rm "$T/runs/$(cat "$T/heads/8")"
ship
expect_status 0
expect_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh run list --workflow ci.yml --commit 8888"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"

scenario "leaves a conflicting pull request that has used its three fix rounds, and still starts a fix round for one that has a round left"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "[$round,$round,$round,{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"Three fix rounds have not got this pull request to green.\"}]" > "$T/rounds-8"
echo "[$round,$round]" > "$T/rounds-11"
ship
expect_status 0
expect_output "pull request #8 conflicts with main, but has used its three fix rounds"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh pr comment 8"
expect_no_call "gh workflow run retro.yml"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "leaves a conflicting pull request a round for a conflict already ran for at its head, and starts one where that round was for an older head"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "[{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $(cat "$T/heads/8") -->The fix round for a conflict\"}]" > "$T/rounds-8"
echo "[{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $older -->The fix round for a conflict\"}]" > "$T/rounds-11"
ship
expect_status 0
expect_output "pull request #8 conflicts with main, but a fix round for a conflict already ran for its head 8888888"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_no_call "gh pr comment 8"
expect_no_call "gh workflow run retro.yml"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "confirms the deploy and then fails, starting nothing for it, when a conflicting pull request's fix rounds could not be read"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "api repos/{owner}/{repo}/issues/8/comments" > "$T/fail"
ship
expect_status 1
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "- a fix round was not started for every open pull request these merges left in conflict"

scenario "starts no fix round for a draft the merge left in conflict: its engineer is still building it"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo 8 > "$T/drafts"
ship
expect_status 0
expect_output "pull request #8 is a draft, which its engineer is still building: no fix round was started"
expect_no_call "gh workflow run fix.yml -f pr=8"
expect_call "gh workflow run fix.yml -f pr=11"

scenario "starts nothing when the merge left no pull request in conflict"
ready_to_ship
also_open 8 app/claude MERGEABLE
ship
expect_status 0
expect_no_call "gh workflow run"

scenario "asks again while GitHub is still working out which pull requests conflict"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo 2 > "$T/unknown"
ship
expect_status 0
expect_call "gh workflow run fix.yml -f pr=8"

scenario "leaves a pull request GitHub never gave an answer for, says so, and asks only six times"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo 99 > "$T/unknown"
ship
expect_status 0
expect_output "GitHub has not said whether pull request #8 conflicts with main"
expect_no_call "gh workflow run"
[ "$(calls "gh pr list --state open --base main --limit 100 --json number,mergeable")" = 6 ] || fail "expected six askings, got $(calls "gh pr list --state open --base main --limit 100 --json number,mergeable")"

scenario "confirms the deploy and then fails when the open pull requests could not be listed"
ready_to_ship
also_open 8 app/claude CONFLICTING
echo "pr list --state open --base main --limit 100 --json number,mergeable" > "$T/fail"
ship
expect_status 1
expect_no_call "gh workflow run"
expect_call "gh pr comment 7 --body Deployed:"
expect_call "gh issue edit 12 --add-label deployed"

scenario "confirms the deploy and then fails when the fix round could not be started for one, having still started it for the other"
ready_to_ship
also_open 8 app/claude CONFLICTING
also_open 11 app/claude CONFLICTING
echo "workflow run fix.yml -f pr=8" > "$T/fail"
ship
expect_status 1
expect_output "The fix round for pull request #8 could not be started"
expect_call "gh workflow run fix.yml -f pr=11"
expect_call "gh pr comment 7 --body Deployed:"

scenario "a merged revert reopens the ticket it took back as reverted, before the wait for production"
ready_to_ship
echo "Take back pull request #5" > "$T/title"
ship
expect_status 0
expect_call "gh issue reopen 3"
expect_call "gh issue edit 3 --add-label reverted --remove-label deployed"
expect_call "gh issue comment 3 --body Taken back: pull request #7 reverted pull request #5"
[ "$(grep -n "^gh issue reopen 3" "$T/calls" | cut -d: -f1)" -lt "$(grep -n "^curl" "$T/calls" | head -n 1 | cut -d: -f1)" ] \
  || fail "expected the ticket to be reopened before production was asked"
expect_call "gh issue edit 12 --add-label deployed"

scenario "a merged take-back of a merge made with the button puts the ticket it took back in progress again, with what the test printed"
ready_to_ship
echo "Take back the button merge of pull request #5" > "$T/title"
printf 'The test of `main` ended:\n\n```\nFAILED factory/tests/ship.test.sh\n```\n' > "$T/ticket-body"
ship
expect_status 0
expect_call "gh issue reopen 3"
expect_call "gh issue comment 3 --body Taken back: pull request #7 reverted pull request #5"
expect_call "FAILED factory/tests/ship.test.sh"
expect_call "gh issue edit 3 --add-label reverted --add-label ready --remove-label deployed --remove-label needs-human"
expect_calls 1 "gh workflow run implement.yml -f issue=3"
expect_no_call "gh issue edit 3 --add-label deployed"

scenario "any other merge reopens no ticket"
ready_to_ship
ship
expect_status 0
expect_call "gh issue view 12 --json title"
expect_no_call "gh issue reopen"

scenario "a pull request that closes no ticket is not asked whether it took one back"
ready_to_ship
echo "A person's own pull request." > "$T/body"
ship
expect_status 0
expect_no_call "gh issue view"

scenario "a merged revert whose ticket cannot be reopened still ships, says so and fails"
ready_to_ship
echo "Take back pull request #5" > "$T/title"
echo "issue reopen 3" > "$T/fail"
ship
expect_status 1
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- if this pull request took a ticket back, that ticket was not reopened as \`reverted\` (\`revert.sh\` failed)"
expect_output "Ticket #3 could not be reopened."

# waits <number> <who opened it> [draft]: an open pull request labelled waits-for-main, and flagged as one is.
waits() {
  jq --argjson n "$1" --arg login "$2" --argjson draft "${3:-false}" \
    '. + [{number: $n, author: {login: $login}, isDraft: $draft, labels: [{name: "needs-human"}, {name: "waits-for-main"}]}]' \
    <(cat "$T/marked.json" 2>/dev/null || echo "[]") > "$T/marked.new"
  mv "$T/marked.new" "$T/marked.json"
}

scenario "after a merge, starts the fix round that tests a pull request labelled waits-for-main again, and touches no other"
ready_to_ship
waits 8 app/claude
also_open 9 app/claude MERGEABLE
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_call "gh workflow run fix.yml -f pr=8"
expect_calls 1 "gh workflow run"
expect_output "started the fix round that tests pull request #8 with main again"
expect_no_call "gh pr edit 9"
expect_no_call "gh pr comment 9"
[ "$(grep -n '^gh workflow run fix.yml -f pr=8' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh pr merge 7' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the round to be started after the merge"

scenario "a labelled pull request the merge left in conflict gets one round, its retest, and not a second for the conflict"
ready_to_ship
waits 8 app/claude
also_open 8 app/claude CONFLICTING
ship
expect_status 0
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_output "pull request #8 is labelled waits-for-main, as what failed lies outside it: no fix round was started, and the next merge tests it again"

# sent_back <number> <submitted>: an open pull request in conflict, which had its round for the conflict at this head,
# and which the owner then sent back: GitHub ran no workflow for that review.
sent_back() {
  also_open "$1" app/claude CONFLICTING
  jq --argjson n "$1" '. + [{number: $n, author: {login: "app/claude"}, isDraft: false, labels: [{name: "needs-human"}]}]' \
    <(cat "$T/marked.json" 2>/dev/null || echo "[]") > "$T/marked.new"
  mv "$T/marked.new" "$T/marked.json"
  echo "[{\"id\":41,\"user\":{\"login\":\"owner\"},\"state\":\"CHANGES_REQUESTED\",\"commit_id\":\"$(cat "$T/heads/$1")\",\"submitted_at\":\"$2\"}]" > "$T/reviews-$1"
  echo "[{\"id\":1,\"created_at\":\"2026-11-18T08:00:00Z\",\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $(cat "$T/heads/$1") -->The fix round for a conflict: the engineer's session ran.\"}]" > "$T/rounds-$1"
}

scenario "after a merge, starts the owner's round of a pull request in conflict the owner sent back, which no review started"
ready_to_ship
sent_back 8 2026-11-18T09:00:00Z
ship
expect_status 0
expect_call "gh pr merge 7 "
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_output "started fix.yml for pull request #8, which its owner sent back"
[ "$(grep -n '^gh workflow run fix.yml -f pr=8' "$T/calls" | cut -d: -f1)" -gt "$(grep -n '^gh pr merge 7' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the round to be started after the merge"

scenario "ships and then fails, saying so on the pull request, when the labelled pull requests could not be listed"
ready_to_ship
echo "pr list --state open --limit 100 --json number,author,labels,isDraft" > "$T/fail"
ship
expect_status 1
expect_call "gh pr merge 7 "
expect_call "gh issue edit 12 --add-label deployed"
expect_call "- not every pull request labelled \`waits-for-main\`, or sent back by its owner, got its fix round (\`start-retests.sh\` failed); the next merge starts it"

# The pull requests of a group beside #7: #8 closes #13 and #9 closes #14, and each merge commit is its number forty times.
eight_merged=8888888888888888888888888888888888888888
nine_merged=9999999999999999999999999999999999999999
a_group() {
  ready_to_ship
  also_ships 8 13
  also_ships 9 14
  echo "{\"commit\":\"$nine_merged\"}" > "$T/health"
}
production_runs() { echo "{\"commit\":\"$1\"}" > "$T/health"; }
merges() { grep -o '^gh pr merge [0-9]*' "$T/calls" | sed 's/.* //' | tr '\n' ' '; }
left_out() {
  jq --argjson pr "$1" --arg result "$2" --arg detail "$3" \
    '(.pulls[] | select(.number == $pr)) |= . + {result: $result, detail: $detail}' "$T/result.json" > "$T/result.new"
  mv "$T/result.new" "$T/result.json"
}

scenario "a group that passed merges in the order its pull requests were added, with nothing between the merges"
a_group
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
[ "$(merges)" = "8 7 9 " ] || fail "expected #8, #7, #9 to merge in that order, got: $(merges)"
expect_call "gh pr merge 8 --squash --delete-branch --match-head-commit $head_8"
expect_call "gh pr merge 9 --squash --delete-branch --match-head-commit $head_9"
between=$(sed -n '/^gh pr merge 8 /,/^gh pr merge 9 /p' "$T/calls" | grep -cvE '^gh (pr merge|pr view [0-9]+ --json mergeCommit|api repos/\{owner\}/\{repo\}/commits\?sha=main)' || true)
[ "$between" = 0 ] || fail "expected nothing but the merges and the look at main between the first merge and the last, got $between other calls"
for ticket in 12 13 14; do expect_call "gh issue close $ticket"; done

scenario "a group's workflow changes get one installer, told to install them in the order they merged (decisions W469b)"
a_group
echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_calls 1 "gh workflow run install-workflows.yml"
expect_call "gh workflow run install-workflows.yml -f pr=8 -f then=7 9"

scenario "the installer is told of no pull request of the group that changed no workflow"
a_group
echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
echo '[{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files-8.json"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_calls 1 "gh workflow run install-workflows.yml"
expect_call "gh workflow run install-workflows.yml -f pr=7 -f then=9"

scenario "each pull request of a group whose workflow change was not installed is told, when the installer could not be started"
a_group
echo '[{"filename":"factory/workflows/ci.yml"}]' > "$T/files.json"
echo '[{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files-8.json"
echo "workflow run install-workflows.yml" > "$T/fail"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 1
expect_calls 2 "- the workflow installer could not be started, so the changed workflows are not installed"

scenario "each ticket of a group is marked deployed once production runs the last commit of the group"
a_group
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_call "gh pr comment 9 --body Deployed: production at https://myapp.example/ is running 9999999."
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running 9999999, which holds this pull request's commit abcdef0."
expect_call "gh pr comment 8 --body Deployed: production at https://myapp.example/ is running 9999999, which holds this pull request's commit 8888888."
for ticket in 12 13 14; do expect_call "gh issue edit $ticket --add-label deployed"; done

scenario "no ticket of a group is marked deployed while production still runs an earlier commit of it"
a_group
echo "{\"commit\":\"$merged\"}" > "$T/health"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_failure
expect_no_call "--add-label deployed"
for number in 7 8 9; do
  expect_call "gh pr comment $number --body Merged as "
done
expect_call "- the deploy check: production at https://myapp.example/ did not report 9999999 within 10 minutes. Check the Vercel deployment"

scenario "when the last commit changes no app code, the commit before it is the one waited for, and Vercel is not asked about the last"
a_group
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files-9.json"
echo "{\"commit\":\"$merged\"}" > "$T/health"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_no_call "gh api repos/{owner}/{repo}/commits/$nine_merged/statuses"
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "gh pr comment 8 --body Deployed: production at https://myapp.example/ is running abcdef0, which holds this pull request's commit 8888888."
expect_call "gh pr comment 9 --body Merged as 9999999. Nothing to deploy: this pull request changes no app code"
expect_call "gh issue edit 12 --add-label deployed"
expect_call "gh issue edit 13 --add-label deployed"
expect_no_call "gh issue edit 14 --add-label deployed"

scenario "when Vercel deploys the last commit though it changes no app code, production running it holds the commit before it"
a_group
echo '[{"filename":"README.md"}]' > "$T/files-9.json"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running 9999999, which holds this pull request's commit abcdef0."
expect_call "gh pr comment 8 --body Deployed: production at https://myapp.example/ is running 9999999, which holds this pull request's commit 8888888."
expect_call "gh pr comment 9 --body Merged as 9999999. Nothing to deploy"
expect_call "gh issue edit 12 --add-label deployed"
expect_no_call "gh issue edit 14 --add-label deployed"

scenario "when Vercel skips the last commit, which changes app code, the commit before it is waited for and the skipped one is not marked deployed"
a_group
echo '[{"context":"Vercel","description":"Skipped, no changes"}]' > "$T/skipped-statuses.json"
echo "$nine_merged" > "$T/skipped-commit"
echo "{\"commit\":\"$merged\"}" > "$T/health"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 1
expect_call "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_call "- the deploy check: Vercel skipped the deployment of this commit"
expect_no_call "gh issue edit 14 --add-label deployed"

scenario "main holds what was tested: the tree the last merge made is the tree that passed, and nothing is said"
a_group
found passed "7:$head" "8:$head_8"
jq '.tree = "1234567812345678123456781234567812345678"' "$T/result.json" > "$T/result.new"; mv "$T/result.new" "$T/result.json"
production_runs "$eight_merged"
echo 1234567812345678123456781234567812345678 > "$T/trees/$eight_merged"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_call "gh api repos/{owner}/{repo}/commits/$eight_merged --jq .commit.tree.sha"
expect_no_call "but not everything that follows a merge finished"

scenario "fails, and says so on the last pull request with no command to run, when the merges made another tree than the one that was tested"
a_group
found passed "7:$head" "8:$head_8"
jq '.tree = "1234567812345678123456781234567812345678"' "$T/result.json" > "$T/result.new"; mv "$T/result.new" "$T/result.json"
echo "{\"commit\":\"$eight_merged\"}" > "$T/health"
echo 9999999912345678123456781234567812345678 > "$T/trees/$eight_merged"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_failure
expect_call "- \`main\` does not hold what was tested: the merges of this group made tree 9999999, and the test passed on tree 1234567. The checks of the next pull request test what \`main\` now holds"
expect_no_call "gh pr edit 8 --add-label needs-human"
expect_no_call "\`pnpm "
expect_no_call "gh pr comment 7 --body Merged as"

scenario "fails when the tree the merges made cannot be read: that is not a tree that was tested"
a_group
found passed "7:$head" "8:$head_8"
jq '.tree = "1234567812345678123456781234567812345678"' "$T/result.json" > "$T/result.new"; mv "$T/result.new" "$T/result.json"
echo "{\"commit\":\"$eight_merged\"}" > "$T/health"
echo "api repos/{owner}/{repo}/commits/$eight_merged --jq .commit.tree.sha" > "$T/fail"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_failure
expect_call "so whether \`main\` holds what was tested is not known"

scenario "main moved while the group was tested: nothing merges on that test, nobody is told, and the group is tested again"
a_group
echo "$older" > "$T/main"
ship "8:$head_8" "7:$head" "9:$head_9"
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"
expect_calls 1 "gh workflow run merge-group.yml -f try=1"
expect_output "\`main\` moved from aaaaaaa to 0000000 while the group was tested, and nothing merges on a test of another \`main\`. Each of 8:$head_8 7:$head 9:$head_9 keeps its place"

scenario "main moved and the test cannot be started again, though asked six times: each pull request keeps its place, and a person is asked to start the workflow"
a_group
echo "$older" > "$T/main"
echo "workflow run merge-group.yml" > "$T/fail"
ship "8:$head_8" "7:$head"
expect_failure
expect_no_call "gh pr merge"
expect_calls 6 "gh workflow run merge-group.yml"
for number in 7 8; do
  expect_first_line "gh pr comment $number --body Start the \`merge-group\` workflow from the Actions tab: this pull request still waits to merge, and that run tests and merges" "it."
  expect_call "gh pr edit $number --add-label needs-human"
done
expect_no_call "factory:merge-queue removed"
expect_call "Not merged: \`main\` moved from aaaaaaa to 0000000 while the group was tested, and nothing merges on a test of another \`main\`, and \`merge-group.yml\` could not be started to test its group again."

scenario "one of three that conflicts is left out with what its engineer needs and gets one fix round, and the other two merge"
a_group
also_open 8 app/claude CONFLICTING
found passed "7:$head" "8:$head_8" "9:$head_9"
left_out 8 conflict "Git reports a conflict in:
apps/web/src/app/page.tsx"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8" "9:$head_9"
expect_status 0
[ "$(merges)" = "7 9 " ] || fail "expected #7 and #9 to merge, got: $(merges)"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $head_8 -->Not merged: it does not fit \`main\` with the pull requests merged before it. Its engineer merges \`main\` into the branch and fixes what is shown below in a fix round"
expect_call "apps/web/src/app/page.tsx"
# One round: the look for pull requests left in conflict, after the merges, starts no second.
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_no_call "gh pr edit 8 --add-label needs-human"
expect_no_call "gh issue close 13"
# The comment is there before the round that reads it is started.
[ "$(grep -n -m 1 '^gh pr comment 8 ' "$T/calls" | cut -d: -f1)" -lt "$(grep -n -m 1 '^gh workflow run fix.yml -f pr=8' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected #8 to be told before its fix round was started"
# After the merges: the round merges main as the two left it.
[ "$(grep -n '^gh pr merge 9 ' "$T/calls" | cut -d: -f1)" -lt "$(grep -n -m 1 '^gh workflow run fix.yml -f pr=8' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the fix round of #8 to be started after the merges"

scenario "one of three that breaks the checks goes back to its engineer with what failed, and the other two merge"
a_group
found passed "7:$head" "8:$head_8" "9:$head_9"
left_out 8 failed "lint: apps/web/broken is not allowed"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8" "9:$head_9"
expect_status 0
[ "$(merges)" = "7 9 " ] || fail "expected #7 and #9 to merge, got: $(merges)"
expect_call "gh pr comment 8 --body <!-- factory:merge-queue removed $head_8 -->Not merged: its checks failed when it was tested with \`main\` and the pull requests merged before it."
expect_call "lint: apps/web/broken is not allowed"
expect_calls 1 "gh workflow run fix.yml -f pr=8"

scenario "a group in which nothing passed merges nothing, and still sends each back"
a_group
found failed "8:$head_8"
run "$scripts/ship.sh" "$T/result.json" "8:$head_8"
expect_status 0
expect_no_call "gh pr merge"
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_no_call "curl"

scenario "one left out with no fix round left waits for a person, who is asked for a review and is given no command"
a_group
production_runs "$merged"
echo "[$round,$round,$round]" > "$T/rounds-8"
found passed "7:$head" "8:$head_8"
left_out 8 conflict "Git reports a conflict in:
apps/web/src/app/page.tsx"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_first_line "gh pr comment 8 --body <!-- factory:merge-queue removed $head_8 -->Submit a \"Request changes\" review saying what to change, or close this pull request: a review starts a fix round that is not one of the three, and its engineer is given what is shown" "below."
expect_no_call "git fetch"
expect_call "It gets no fix round, because it has used its three fix rounds."
expect_call "gh pr edit 8 --add-label needs-human"
expect_no_call "gh workflow run fix.yml"

scenario "one left out whose head already had its round for a conflict waits for a person"
a_group
production_runs "$merged"
echo "[{\"id\":5,\"user\":{\"login\":\"github-actions[bot]\"},\"body\":\"<!-- factory:conflict-round $head_8 -->A fix round for a conflict\"}]" > "$T/rounds-8"
found passed "7:$head" "8:$head_8"
left_out 8 failed "lint failed"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_call "It gets no fix round, because a fix round for a conflict already ran at ${head_8:0:7}."
expect_call "gh pr edit 8 --add-label needs-human"
expect_no_call "gh workflow run fix.yml"

scenario "one left out that a person opened gets no fix round, and its author is told what to fit, with no command"
a_group
production_runs "$merged"
echo repo-owner > "$T/author-8"
found passed "7:$head" "8:$head_8"
left_out 8 conflict "Git reports a conflict in:
README.md"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_first_line "gh pr comment 8 --body <!-- factory:merge-queue removed $head_8 -->Merge \`main\` into this pull request's branch and fix what is shown below: the new commit is checked and merged like any" "other."
expect_call "It gets no fix round, because the factory did not open it."
expect_no_call "git fetch"
expect_call "gh pr edit 8 --add-label needs-human"
expect_no_call "gh workflow run fix.yml"

scenario "asks six times for the fix round of one left out, then fails, having merged the others, and asks a person to start the workflow"
a_group
production_runs "$merged"
echo "workflow run fix.yml -f pr=8" > "$T/fail"
found passed "7:$head" "8:$head_8"
left_out 8 failed "lint failed"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_failure
expect_call "gh pr merge 7 "
expect_calls 6 "gh workflow run fix.yml -f pr=8"
expect_call "gh pr comment 8 --body Start the \`fix\` workflow from the Actions tab, with this pull request's number, 8: the fix round the comment before this one names could not be started."
expect_no_call "\`gh workflow run"
expect_call "gh pr edit 8 --add-label needs-human"
expect_call "gh issue edit 12 --add-label deployed"

scenario "one left out that could not be told so keeps its place and is tested again, and the others merge"
a_group
production_runs "$merged"
echo "pr comment 8" > "$T/fail"
found passed "7:$head" "8:$head_8"
left_out 8 failed "lint failed"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_output "pull request #8 was left out, because its checks failed when it was tested with \`main\` and the pull requests merged before it, and could not be told so. Each of 8:$head_8 keeps its place"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_no_call "gh workflow run fix.yml"
expect_call "gh pr merge 7 "

scenario "one left out whose fix rounds cannot be read keeps its place and is tested again"
a_group
production_runs "$merged"
found passed "7:$head" "8:$head_8"
left_out 8 failed "lint failed"
echo "pr view 8 --json author" > "$T/fail"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_no_call "gh pr comment 8"
expect_no_call "gh pr edit 8"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_no_call "gh workflow run fix.yml"
expect_call "gh pr merge 7 "

scenario "merges nothing when the test left no result: each pull request keeps its place, nobody is told, and the group is tested again"
a_group
run "$scripts/ship.sh" "$T/no-such-file.json" "7:$head" "8:$head_8"
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_output "the test of its group with \`main\` ended with no result. Each of 7:$head 8:$head_8 keeps its place"

scenario "a test that leaves no result on each of three tries reaches a person: each pull request keeps its place and is asked for no new approval"
a_group
run env TRY=3 "$scripts/ship.sh" "$T/no-such-file.json" "7:$head" "8:$head_8"
expect_failure
expect_no_call "gh pr merge"
expect_no_call "gh workflow run"
for number in 7 8; do
  expect_first_line "gh pr comment $number --body Start the \`merge-group\` workflow from the Actions tab: this pull request still waits to merge, and that run tests and merges" "it."
  expect_call "gh pr edit $number --add-label needs-human"
done
expect_call "Not merged: the test of its group with \`main\` ended with no result, on each of three tries."
expect_no_call "factory:merge-queue removed"
expect_no_call "Approve this pull request again"

scenario "merges nothing when the group was not tested because main's workflows were not installed: the group is tested again"
a_group
jq -n --arg main "$main" '{main: $main, not_tested: "`main` holds a workflow change that was not installed"}' > "$T/result.json"
run "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh pr comment"
expect_output "\`main\` holds a workflow change that was not installed. Each of 7:$head keeps its place"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

scenario "merges no commit the group was not begun with, whatever the result of the test names"
a_group
found passed "7:$older" "8:$head_8"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_no_call "gh pr merge"
expect_output "the test of its group named pull request #7 at a commit the group does not hold"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

scenario "merges no pull request the group does not hold, though the result names it as passed"
a_group
found passed "7:$head" "9:$head_9"
run "$scripts/ship.sh" "$T/result.json" "7:$head"
expect_status 0
expect_no_call "gh pr merge"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

scenario "one of a group that GitHub refuses to merge stops the merges: it keeps its place, and it and those behind it are tested again"
a_group
production_runs "$merged"
echo "pr merge 8" > "$T/fail"
ship "7:$head" "8:$head_8" "9:$head_9"
expect_status 0
[ "$(merges)" = "7 8 8 8 " ] || fail "expected #7 to merge and #8 to be tried three times, got: $(merges)"
expect_no_call "gh pr merge 9"
expect_no_call "gh pr comment 8"
expect_no_call "gh pr comment 9"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"
expect_output "Each of 8:$head_8 9:$head_9 keeps its place"
expect_call "gh issue edit 12 --add-label deployed"

scenario "a pull request added while its group was tested is not merged with it"
a_group
production_runs "$eight_merged"
ship "7:$head" "8:$head_8"
expect_status 0
[ "$(merges)" = "7 8 " ] || fail "expected #7 and #8 alone to merge, got: $(merges)"
expect_no_call "gh pr merge 9"

scenario "one its owner sent back, or that was pushed to, while its group was tested is not merged, and those behind it are tested again"
a_group
production_runs "$merged"
found passed "7:$head" "8:$head_8" "9:$head_9"
no_longer_waits 8
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8" "9:$head_9"
expect_status 0
[ "$(merges)" = "7 " ] || fail "expected #7 alone to merge, got: $(merges)"
expect_output "pull request #8 no longer waits to merge at the commit that was tested: it is not merged"
expect_no_call "gh pr comment 8"
expect_no_call "gh pr edit 8"
expect_calls 1 "gh workflow run merge-group.yml -f try=1"
expect_output "Each of 9:$head_9 keeps its place"
expect_call "gh issue edit 12 --add-label deployed"

scenario "one left out that no longer waits is not sent back: its new commit, or its owner's round, is what follows"
a_group
production_runs "$merged"
found passed "7:$head" "8:$head_8"
left_out 8 failed "lint failed"
no_longer_waits 8
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_no_call "gh pr comment 8"
expect_no_call "gh workflow run fix.yml"

scenario "merges nothing when the pull requests that still wait cannot be read: the group is tested again"
a_group
found passed "7:$head" "8:$head_8"
echo "pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews" > "$T/fail"
run "$scripts/ship.sh" "$T/result.json" "7:$head" "8:$head_8"
expect_status 0
expect_no_call "gh pr merge"
expect_output "GitHub did not say which pull requests still wait to merge"
expect_calls 1 "gh workflow run merge-group.yml -f try=2"

# The owner pressed GitHub's merge button, and approve-merge.yml runs this for the merged pull request (decisions M435a).
finish() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp PRODUCTION_URL=https://myapp.example/ "$scripts/ship.sh" --merged 7; }

scenario "after the merge button, does once everything that follows a merge, merges nothing and leaves the installer to the button"
ready_to_ship
echo '[{"filename":"factory/workflows/ci.yml"},{"filename":"apps/web/src/app/page.tsx"}]' > "$T/files.json"
echo '[{"number":20}]' > "$T/ready.json"
never_started 505 implement "$billing"
echo "[$round,$round]" > "$T/rounds"
a_changed_workflow_waits
echo '[{"id":901,"created_at":"2026-11-16T10:05:00Z","conclusion":"success","html_url":"https://github.example/runs/901"}]' > "$T/first-runs.json"
echo "Take back pull request #5" > "$T/title"
also_open 8 app/claude CONFLICTING
waits 9 app/claude
finish
expect_status 0
expect_no_call "gh pr merge"
expect_no_call "gh workflow run install-workflows.yml"
expect_calls 1 "gh pr edit 7 --remove-label needs-human"
expect_calls 1 "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_calls 1 "gh issue close 12"
expect_calls 1 "gh run rerun 505 --failed"
expect_calls 1 "gh workflow run implement.yml -f issue=20"
expect_calls 1 "gh workflow run retro.yml -f pr=7"
expect_calls 1 "gh workflow run retro.yml -f pr=40 -f run=901"
expect_calls 1 "gh repo view"
expect_calls 1 "gh issue reopen 3"
expect_calls 1 "gh workflow run fix.yml -f pr=8"
expect_calls 1 "gh workflow run fix.yml -f pr=9"
expect_calls 1 "gh pr comment 7 --body Deployed: production at https://myapp.example/ is running abcdef0."
expect_calls 1 "gh issue edit 12 --add-label deployed"
expect_calls 1 "gh issue comment 12 --body"
[ "$(recorded | wc -l)" -eq 1 ] || fail "expected one line of measures on the sessions branch, got: $(recorded)"

scenario "after the merge button on a pull request that changes no app code, says what was deployed and takes needs-human off the ticket"
ready_to_ship
echo '[{"filename":"factory/scripts/ship.sh"}]' > "$T/files.json"
rm "$T/health"
finish
expect_status 0
expect_call "gh pr comment 7 --body Merged as abcdef0. Nothing to deploy"
expect_call "gh issue edit 12 --remove-label in-progress --remove-label needs-human"
expect_no_call "gh issue edit 12 --add-label deployed"

scenario "does nothing for a pull request the factory merged, which got each step then"
ready_to_ship
echo app/github-actions > "$T/merged-by"
finish
expect_status 0
expect_output "the factory merged pull request #7, and did what follows a merge then; nothing to do"
expect_no_call "gh pr edit"
expect_no_call "gh issue"
expect_no_call "gh workflow run"
expect_no_call "gh run rerun"
expect_no_call "gh pr comment"
expect_no_call "curl"

scenario "does nothing for a pull request that is not merged"
ready_to_ship
echo CLOSED > "$T/state"
finish
expect_status 0
expect_output "pull request #7 is not merged; nothing to do"
expect_no_call "gh pr edit"
expect_no_call "gh issue"
expect_no_call "gh workflow run"

scenario "after the merge button, a pull request anyone opened gets each step, and one that closes no ticket labels none"
ready_to_ship
echo repo-owner > "$T/author"
printf 'Tidies the README.\n' > "$T/body"
finish
expect_status 0
expect_call "gh pr edit 7 --remove-label needs-human"
expect_call "gh pr comment 7 --body Deployed:"
expect_no_call "gh issue"

for words in "pr view 7 --json body" "pr view 7 --json state,mergedBy,mergeCommit"; do
  scenario "after the merge button, fails with one comment saying what to run again when GitHub never answers: gh $words"
  ready_to_ship
  echo "$words" > "$T/fail"
  finish
  expect_failure
  expect_calls 1 "gh pr comment 7"
  expect_first_line "gh pr comment 7 --body" "Run the failed \`approve-merge\` run for this pull request again: what follows a merge is done then."
  expect_call "Merged with GitHub's merge button, and nothing that follows a merge was done: GitHub did not "
  expect_no_call "Approve this pull request again"
  expect_no_call "gh pr edit"
  expect_no_call "gh issue"
  expect_no_call "gh workflow run"
done

scenario "after the merge button, a step that did not finish is named on the pull request, and the rest are still done"
ready_to_ship
echo "issue close 12" > "$T/fail"
finish
expect_status 1
expect_call "gh issue edit 12 --add-label deployed"
expect_call "Merged as abcdef0, but not everything that follows a merge finished:"
expect_call "- ticket #12 could not be closed"

scenario "a pull request a person merged with the button, after its group was tested, is left to the button's run: nothing is merged and no step done"
ready_to_ship
on_main
ship
expect_status 0
expect_output "a person merged pull request #7 with GitHub's merge button, and \`ship.sh --merged\` does what follows a merge for it"
expect_no_call "gh pr merge"
expect_no_call "gh pr edit"
expect_no_call "gh issue"
expect_no_call "gh workflow run"
expect_no_call "gh run rerun"
expect_no_call "gh pr comment"
expect_no_call "curl"

scenario "a group whose pull request is found on main, when who merged it cannot be read, gets no step: the pull request is told, and the run fails"
ready_to_ship
on_main
echo "pr view 7 --json state,mergedBy" > "$T/fail"
ship
expect_status 1
expect_calls 1 "gh pr comment 7"
expect_first_line "gh pr comment 7 --body" "Run the failed job of this run again: what follows a merge is done then, unless the merge button's run does it."
expect_call "GitHub did not say who merged this pull request"
expect_no_call "gh pr merge"
expect_no_call "gh pr edit"
expect_no_call "gh issue"
expect_no_call "gh workflow run"
expect_no_call "curl"

# A change to either side must fail here: nothing else does what follows a merge when a person presses the button.
scenario "approve-merge.yml runs it with main's scripts when a person merges a pull request, and the installer is started by the button alone"
workflow="$root/factory/workflows/approve-merge.yml"
grep -A1 -F 'pull_request_target:' "$workflow" | grep -qxF '    types: [closed]' || fail "approve-merge.yml does not start when a pull request is closed"
grep -qF "(github.event_name == 'pull_request_target' && github.event.pull_request.merged == true) ||" "$workflow" \
  || fail "the ship job of approve-merge.yml does not run for a merged pull request alone"
grep -B11 -F 'run: factory/scripts/button-merge.sh finish "$PR" "$MAIN" "$BEFORE"' "$workflow" | grep -qF "if: github.event_name == 'pull_request_target'" \
  || fail "approve-merge.yml does not run button-merge.sh, which runs ship.sh --merged, when a pull request is merged, and then alone"
grep -qF 'exec "$script_dir/ship.sh" --merged "$pr"' "$scripts/button-merge.sh" && [ "$(grep -cF '"$script_dir/ship.sh" --merged "$pr"' "$scripts/button-merge.sh")" = 3 ] \
  || fail "button-merge.sh does not run ship.sh --merged for each merge that stands"
grep -B8 -F 'run: factory/scripts/approve-merge.sh "$PR" "$OWNER"' "$workflow" | grep -qF "if: github.event_name != 'pull_request_target'" \
  || fail "approve-merge.yml also runs approve-merge.sh for a pull request that is already merged"
[ "$(grep -cF 'ref: ${{ github.event.repository.default_branch }}' "$workflow")" -eq 2 ] || fail "a job of approve-merge.yml runs the pull request's copy of the scripts"
installer="$root/factory/workflows/install-workflows.yml"
grep -A2 -F 'pull_request_target:' "$installer" | grep -qxF '    types: [closed]' || fail "install-workflows.yml does not start when a person merges a pull request"
grep -qF "github.event.pull_request.merged == true" "$installer" || fail "install-workflows.yml does not run for a merged pull request"
