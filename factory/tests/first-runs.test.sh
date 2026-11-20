#!/usr/bin/env bash
# Tests for factory/scripts/first-runs.sh, which starts a retro for each changed workflow (decisions A185a to A185c).
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/trusted-on-github.sh"

# $T/waiting, $T/comments-<n> and $T/runs-<file> answer gh; $T/fail lists the gh calls, by their first words, that fail.
# $T/writers lists the accounts that may write to the repo.
github() {
  : > "$T/fail"; : > "$T/waiting"
  echo owner > "$T/writers"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr list --state merged --label proof --limit 100 --json number "*) json "$(jq -Rn "[inputs | {number: tonumber}]" "$T/waiting")" "$@" ;;
      "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate "*) n=${2#*/issues/}; json "$(cat "$T/comments-${n%/comments*}")" "$@" ;;
      "api --method GET repos/{owner}/{repo}/actions/workflows/"*"/runs -f status=completed -f created=>=2026-11-16T10:00:00Z -f per_page=100 --paginate "*)
        file=${4#*/workflows/}; json "{\"workflow_runs\":$(cat "$T/runs-${file%/runs}" 2>/dev/null || echo "[]")}" "$@" ;;
      "api repos/{owner}/{repo}/collaborators/"*) permission_on_github "$@" ;;
      "workflow run retro.yml "* | "pr comment "* | "pr edit "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  stub sleep ':'
}
# comment <author> <text>: one comment, made at ten o'clock.
comment() { jq -nc --arg login "$1" --arg body "$2" '{user: {login: $login}, created_at: "2026-11-16T10:00:00Z", body: $body}'; }
# installed <file>...: the comment install-workflows.yml leaves.
installed() { comment 'github-actions[bot]' "Installed in abc1234, the workflow changes this pull request merged:"$'\n\n'"<!-- factory:installed $* -->"; }
# looked_at <file>: the comment this script leaves once a file's retro was started.
looked_at() { comment 'github-actions[bot]' "<!-- factory:first-run $1 -->A retro is looking at the first run of \`$1\`"; }
# waits <n> <comment>...: pull request <n> is labelled, and holds these comments.
waits() {
  local n="$1"; shift
  echo "$n" >> "$T/waiting"
  printf '%s\n' "$@" | jq -sc . > "$T/comments-$n"
}
# a_run <id> <hh:mm> <conclusion> [event] [actor] [head repository]: a run in this repo that the owner's push started, unless said.
a_run() {
  jq -nc --argjson id "$1" --arg at "2026-11-16T$2:00Z" --arg conclusion "$3" --arg event "${4:-push}" --arg actor "${5:-owner}" --arg head "${6-owner/myapp}" \
    '{id: $id, created_at: $at, conclusion: $conclusion, html_url: "https://github.example/runs/\($id)", event: $event, actor: {login: $actor},
      repository: {full_name: "owner/myapp"}, head_repository: (if $head == "" then null else {full_name: $head} end)}'
}
runs_of() { local file="$1"; shift; printf '%s\n' "$@" | jq -sc . > "$T/runs-$file"; }
first_runs() { run env GH_TOKEN=workflow-token "$scripts/first-runs.sh"; }

scenario "asks GitHub one thing and starts nothing when no pull request waits"
github
first_runs
expect_status 0
[ "$(wc -l < "$T/calls" | tr -d ' ')" = 1 ] || fail "expected one call to GitHub"

scenario "starts a retro with the pull request and the run, says so on the pull request, and takes the label off"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
first_runs
expect_status 0
expect_call "gh workflow run retro.yml -f pr=40 -f run=901"
expect_call "gh pr comment 40 --body <!-- factory:first-run ci.yml -->A retro is looking at the first run of \`ci.yml\` since this pull request changed it, and will say here what it finds: https://github.example/runs/901"
expect_call "gh pr edit 40 --remove-label proof"

scenario "the first run is the earliest that ran to its end, failed or not: one skipped or cancelled shows nothing"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 904 10:40 success)" "$(a_run 903 10:30 failure)" "$(a_run 902 10:20 cancelled)" "$(a_run 901 10:10 skipped)"
first_runs
expect_call "gh workflow run retro.yml -f pr=40 -f run=903"
expect_no_call "run=904"

scenario "a run of a fork's pull request is never the first run, whoever started it: the next run of this repo is"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:10 failure pull_request stranger stranger/myapp)" "$(a_run 902 10:20 success pull_request_review owner stranger/myapp)" \
  "$(a_run 903 10:30 success pull_request owner "")" "$(a_run 904 10:40 success pull_request 'claude[bot]')"
first_runs
expect_status 0
expect_call "gh workflow run retro.yml -f pr=40 -f run=904"
expect_no_call "run=901"
expect_no_call "run=902"
expect_no_call "run=903"

scenario "with only a fork's runs the pull request keeps its label, and no retro is started"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:10 failure pull_request stranger stranger/myapp)"
first_runs
expect_status 0
expect_output "no run of ci.yml has finished since pull request #40 changed it"
expect_no_call "workflow run"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"

scenario "with only runs that accounts not trusted started, the pull request keeps its label, and no retro is started"
github; waits 40 "$(installed claude.yml)"
runs_of claude.yml "$(a_run 901 10:10 failure issue_comment stranger)"
first_runs
expect_status 0
expect_output "no run of claude.yml that a trusted account started has finished since pull request #40 changed it"
expect_no_call "workflow run"
expect_no_call "gh pr edit"

scenario "a run an account that is not trusted started, by an event anyone can raise, is never the first run"
for event in issues issue_comment pull_request pull_request_review pull_request_review_comment pull_request_target; do
  github; waits 40 "$(installed claude.yml)"
  : > "$T/calls"
  runs_of claude.yml "$(a_run 901 10:10 failure "$event" stranger)" "$(a_run 902 10:20 success "$event" owner)"
  first_runs
  expect_status 0
  expect_call "gh workflow run retro.yml -f pr=40 -f run=902"
  expect_no_call "run=901"
done

scenario "a run that a schedule, a push or a start by number began counts whoever GitHub names for it: no outsider raises those"
for event in schedule push workflow_dispatch; do
  github; waits 40 "$(installed flag-idle.yml)"
  : > "$T/calls"
  runs_of flag-idle.yml "$(a_run 901 10:10 success "$event" 'workflow-app[bot]')"
  first_runs
  expect_status 0
  expect_call "gh workflow run retro.yml -f pr=40 -f run=901"
  expect_no_call "collaborators"
done

scenario "fails and keeps the label when GitHub would not say whether a trusted account started the run: not known is not trusted"
github; waits 40 "$(installed claude.yml)"
runs_of claude.yml "$(a_run 901 10:10 success issue_comment owner)" "$(a_run 902 10:20 success push owner)"
touch "$T/permission-fails"
first_runs
expect_status 1
expect_output "Whether a trusted account started run 901 of claude.yml could not be read from GitHub"
expect_no_call "workflow run"
expect_no_call "gh pr edit"

scenario "a pull request that changed two workflows keeps its label until both have run"
github; waits 40 "$(installed ci.yml fix.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
first_runs
expect_status 0
expect_call "gh workflow run retro.yml -f pr=40 -f run=901"
expect_output "no run of fix.yml has finished since pull request #40 changed it"
expect_no_call "gh pr edit"

scenario "a workflow whose retro was started gets no second one, and the other's first run ends the wait"
github; waits 40 "$(installed ci.yml fix.yml)" "$(looked_at ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
runs_of fix.yml "$(a_run 950 11:00 failure)"
first_runs
expect_status 0
expect_no_call "run=901"
expect_call "gh workflow run retro.yml -f pr=40 -f run=950"
expect_call "gh pr edit 40 --remove-label proof"

scenario "only the workflow's own account counts, for the record of an install and for a retro already started"
github
waits 40 "$(comment 'claude[bot]' '<!-- factory:installed ci.yml -->')"
waits 41 "$(installed ci.yml)" "$(comment repo-owner '<!-- factory:first-run ci.yml -->done')"
runs_of ci.yml "$(a_run 901 10:05 success)"
first_runs
expect_status 0
expect_output "pull request #40 is labelled \`proof\` and holds no record of an install"
expect_no_call "pr=40"
expect_call "gh workflow run retro.yml -f pr=41 -f run=901"

scenario "a record that only quotes the marker is none, and a name that is no workflow file's is not looked for"
github
waits 40 "$(comment 'github-actions[bot]' 'The last line is `<!-- factory:installed ci.yml -->`, read by first-runs.sh.')"
waits 41 "$(installed '../../pulls' ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
first_runs
expect_status 0
expect_no_call "pr=40"
expect_no_call "pulls"
expect_call "gh workflow run retro.yml -f pr=41 -f run=901"

scenario "fails, having started nothing, when the waiting pull requests cannot be listed"
github; waits 40 "$(installed ci.yml)"
echo "pr list" > "$T/fail"
first_runs
expect_failure
expect_output "Could not list the merged pull requests labelled \`proof\`"
expect_no_call "gh workflow run"

scenario "says which pull request's comments it could not read, goes on to the next, and fails"
github; waits 40 "$(installed ci.yml)"; waits 41 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
echo "api repos/{owner}/{repo}/issues/40/comments" > "$T/fail"
first_runs
expect_failure
expect_output "Could not read the comments of pull request #40"
expect_no_call "pr=40"
expect_call "gh workflow run retro.yml -f pr=41 -f run=901"

scenario "runs that could not be listed are not taken for none: it fails and keeps the label"
github; waits 40 "$(installed ci.yml)"
echo "api --method GET repos/{owner}/{repo}/actions/workflows/ci.yml/runs" > "$T/fail"
first_runs
expect_failure
expect_output "Could not list the runs of ci.yml since pull request #40 changed it"
expect_no_output "no run of ci.yml has finished"
expect_no_call "gh workflow run"
expect_no_call "gh pr edit"

scenario "a retro that could not be started is asked for once, and leaves no comment saying it was"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
echo "workflow run retro.yml" > "$T/fail"
first_runs
expect_failure
expect_output "The retro of run 901, the first of ci.yml since pull request #40 changed it, could not be started."
[ "$(grep -c "gh workflow run" "$T/calls")" = 1 ] || fail "expected the retro to be asked for once"
expect_no_call "gh pr comment"
expect_no_call "gh pr edit"

scenario "says the next merge will start it again when the comment that records a started retro cannot be posted"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
echo "pr comment 40" > "$T/fail"
first_runs
expect_failure
expect_output "the comment that records it could not be posted: the next merge starts it again"
expect_no_call "gh pr edit"

scenario "fails when the label could not be taken off"
github; waits 40 "$(installed ci.yml)"
runs_of ci.yml "$(a_run 901 10:05 success)"
echo "pr edit 40" > "$T/fail"
first_runs
expect_failure
expect_output "the \`proof\` label could not be taken off it"
