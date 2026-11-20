#!/usr/bin/env bash
# Tests for factory/scripts/trusted.sh, which says whether the factory acts for an account, and for the jobs that ask.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/trusted-on-github.sh"

# github <answer>: what GitHub says of the account's permission on the repo; `unknown` and `down` are its two failures.
github() {
  echo "$1" > "$T/answer"
  stub gh '
    case "$*" in
      "api repos/{owner}/{repo}/collaborators/"*"/permission")
        case "$(cat "$T/answer")" in
          unknown) echo "{\"message\":\"Not Found\",\"status\":\"404\"}"; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
          down) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
          *) cat "$T/answer" ;;
        esac ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# may <permission> [role]: GitHub's answer for an account with that base permission, and that role's name.
may() { jq -cn --arg permission "$1" --arg role "${2:-$1}" '{permission: $permission, role_name: $role, user: {login: "someone"}}'; }
trusted() { run env GH_TOKEN=workflow-token "$scripts/trusted.sh" "$@"; }

scenario "an account that may write to the repo is trusted: admin, maintain or write"
for permission in admin maintain write; do
  github "$(may "$permission")"
  trusted octocat
  expect_status 0
done
expect_call "gh api repos/{owner}/{repo}/collaborators/octocat/permission"

scenario "an account that may only read, or has no access, is not trusted, and the message says what it may do"
github "$(may read)"
trusted octocat
expect_status 1
expect_output 'octocat is not trusted: its permission on this repository is "read"'
github "$(may none)"
trusted octocat
expect_status 1

scenario "the base permission decides, not the role's name: a custom role that may write is trusted, triage is not"
github "$(may write release-manager)"
trusted octocat
expect_status 0
github "$(may read triage)"
trusted octocat
expect_status 1
github "$(may read admin)"
trusted octocat
expect_status 1

scenario "the factory's own two bots are trusted by their full login, and GitHub is not asked"
github "$(may none)"
trusted 'github-actions[bot]'
expect_status 0
trusted 'claude[bot]'
expect_status 0
expect_no_call "gh"

scenario "a short form of a bot's login, which a person could hold or gh prints, is not the bot"
github unknown
for login in github-actions claude; do
  trusted "$login"
  expect_status 1
done
expect_calls 2 "gh api"
: > "$T/calls"
for login in app/github-actions app/claude 'Claude[bot]' 'github-actions[bot] ' 'dependabot[bot]'; do
  trusted "$login"
  expect_status 1
  expect_output "is not trusted"
done
expect_no_call "gh"

scenario "an empty login, or none, is not trusted, and GitHub is not asked"
github "$(may admin)"
trusted ""
expect_status 1
trusted
expect_status 1
expect_no_call "gh"

scenario "a login GitHub does not know is not trusted"
github unknown
trusted nobody-by-this-name
expect_status 1
expect_output "nobody-by-this-name is not trusted: GitHub knows no such account"

scenario "a login is data: one that could reach another address or run a command is not trusted, and GitHub is not asked"
github "$(may admin)"
for login in '../../../orgs/acme' 'octocat/permission?x=' 'octo cat' '$(touch injected)' '"; touch injected; "' 'octocat
admin' '--hostname'; do
  trusted "$login"
  expect_status 1
done
expect_no_call "gh"
[ ! -e injected ] || fail "expected the login never to be run as a command"

scenario "exits 2 with a message when GitHub would not say: a failed call is neither yes nor no"
github down
trusted octocat
expect_status 2
expect_output "GitHub would not say whether octocat may write to this repository"
expect_output "HTTP 502"

scenario "exits 2 when GitHub's answer names no permission"
github '{"user":{"login":"octocat"}}'
trusted octocat
expect_status 2
expect_output "names no permission for octocat"
github 'not json'
trusted octocat
expect_status 2
github '{"permission":null}'
trusted octocat
expect_status 2

# A change to either side must fail here: nothing runs a workflow before it is installed.
workflows="$root/factory/workflows"
name="Stop unless the account that started this run"
jobs_of() { sed -n '/^jobs:$/,$p' "$workflows/$1.yml" | sed -n 's/^  \([a-z0-9-]*\):$/\1/p'; }
job() { awk -v job="  $2:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflows/$1.yml"; }
# condition <workflow> <job>: the job's `if:`, on one line.
condition() { job "$1" "$2" | awk '/^    if:/ { on = 1; print; next } on && /^      / { print; next } { on = 0 }' | sed 's/^ *//' | paste -sd' ' -; }
# trust_step <workflow> <job>: the lines of the step that asks trusted.sh.
trust_step() { job "$1" "$2" | awk -v first="      - name: $name" 'index($0, first) == 1 { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() {
  if grep -qx '        run: |' <<<"$1"; then sed -n '/^        run: |$/,$p' <<<"$1" | sed '1d; s/^          //'
  else sed -n 's/^        run: //p' <<<"$1"
  fi
}
# Each job of each workflow that one of the five events anyone can raise starts.
each_job() {
  local file workflow job
  for file in $(grep -lE '^  (issues|issue_comment|pull_request_review|pull_request_review_comment|pull_request_target):' "$workflows"/*.yml); do
    workflow=$(basename "$file" .yml)
    for job in $(jobs_of "$workflow"); do echo "$workflow $job"; done
  done
}
# started_by <sender> [author]: runs the step's commands, from the repo's root as the job does, for an event those accounts raised.
started_by() {
  status=0
  out=$(cd "$root" && env GH_TOKEN=workflow-token SENDER="$1" AUTHOR="${2:-}" bash -e -c "$(commands "$found")" 2>&1) || status=$?
}
github() {
  echo owner > "$T/writers"
  stub gh 'case "$*" in "api repos/{owner}/{repo}/collaborators/"*) permission_on_github "$@" ;; *) echo "unexpected call: gh $*" >&2; exit 1 ;; esac'
}

scenario "the workflows anyone's event can start are the seven the factory holds, nine jobs in all"
[ "$(each_job | cut -d' ' -f1 | sort -u | xargs)" = "approve-merge claude implement install-workflows refine revert start-waiting" ] \
  || fail "expected the seven workflows, got: $(each_job | cut -d' ' -f1 | sort -u | xargs)"
[ "$(each_job | grep -c .)" = 9 ] || fail "expected nine jobs, got $(each_job | grep -c .)"

while read -r workflow job; do
  scenario "the $job job of $workflow stops unless the account that started its run may write to the repo"
  found=$(trust_step "$workflow" "$job")
  [ "$(grep -c -- "- name: $name" <<<"$found")" = 1 ] || fail "expected the job to hold the step once"
  grep -qx '        id: trusted' <<<"$found" || fail "expected the step to be the one later steps read"
  ! grep -q '^        if: ' <<<"$found" || fail "expected the step to run for every event"
  # shellcheck disable=SC2016
  for field in '          GH_TOKEN: ${{ github.token }}' '          SENDER: ${{ github.event.sender.login }}'; do
    grep -qxF -- "$field" <<<"$found" || fail "expected the step to hold: $field"
  done
  # Nothing of the factory's runs, and no secret is read, before the account is known to be trusted.
  before=$(job "$workflow" "$job" | sed -n "/^    steps:\$/,/^      - name: $name/p")
  ! grep -E 'factory/scripts/|secrets\.|(^|[^a-z])gh ' <<<"$before" | grep -v "name: $name" | grep -q . \
    || fail "expected no script, secret or call to GitHub before the step"
  grep -q 'uses: actions/checkout@v4' <<<"$before" || fail "expected the checkout that holds trusted.sh before the step"
  github
  started_by owner owner
  expect_status 0
  : > "$T/calls"
  started_by 'github-actions[bot]' 'claude[bot]'
  expect_status 0
  expect_no_call "gh"
  started_by stranger owner
  expect_status 1
  expect_output "stranger is not trusted"
  touch "$T/permission-fails"
  started_by owner owner
  expect_status 2
  expect_output "GitHub would not say whether owner may write"

  scenario "once that step of the $job job of $workflow has failed, no later step comments, starts a ticket or starts a retro"
  # After a failed step GitHub runs only a step whose condition holds failure(), always() or !cancelled().
  job "$workflow" "$job" | sed -n "/^      - name: $name/,\$p" | awk '
    /^      - / { step = $0; sub(/^      - (name: )?/, "", step) }
    /^        if: .*(failure\(\)|always\(\)|!cancelled\(\))/ { print step "\t" $0 }' > "$T/after-failure"
  while IFS=$'\t' read -r step runs_if; do
    case "$runs_if" in
      "        if: steps.trusted.outcome != 'failure' && "*) ;;
      # Its condition needs what a later step wrote, and no later step ran.
      "        if: always() && steps."*".outputs."*) ;;
      # A run started by number was started by an account that may write, and the next run asks again (decisions W469b).
      "        if: always() && inputs.then != ''") ;;
      *) fail "expected the step \"$step\" not to run after the account was refused, and its condition is: ${runs_if#        }" ;;
    esac
  done < "$T/after-failure"
done < <(each_job)

while read -r workflow job; do
  scenario "the $job job of $workflow also asks about the account that opened the ticket or pull request, which its session reads"
  found=$(trust_step "$workflow" "$job")
  # shellcheck disable=SC2016
  grep -qxF '          AUTHOR: ${{ github.event.issue.user.login || github.event.pull_request.user.login }}' <<<"$found" \
    || fail "expected the step to be given who opened it"
  github
  started_by owner stranger
  expect_status 1
  expect_output "stranger is not trusted"
  started_by owner ""
  expect_status 1
done < <(printf '%s\n' "claude claude")

# shellcheck disable=SC2016
associated='contains(fromJSON('"'"'["OWNER","MEMBER","COLLABORATOR"]'"'"'), github.event.issue.author_association'
bots='contains(fromJSON('"'"'["claude[bot]","github-actions[bot]"]'"'"'), github.event.issue.user.login'

while read -r workflow job; do
  scenario "the $job job of $workflow is skipped for a ticket the event does not say a trusted account opened"
  found=$(condition "$workflow" "$job")
  [[ "$found" == *"($associated"*") || $bots"*"))"* ]] \
    || fail "expected the job's condition to need the ticket's author to be the owner, a member, a collaborator or one of the two bots, got: $found"
  [[ "$found" != *"github.event.sender.login"* ]] || fail "expected no account but the ticket's author to stand in for it, got: $found"
done < <(printf '%s\n' "claude claude" "refine refine")

# The script each runs answers the owner on the ticket, which a skipped job cannot.
owner_asked="github.event.sender.login == github.repository_owner"

scenario "refine.yml needs a trusted author for the label and for a comment alike, and still nobody's comment but the owner's"
found=$(condition refine refine)
[[ "$found" == "if: >- ($associated) || $bots)) && ((github.event_name == 'issues' && "*") || (github.event_name == 'issue_comment' && "*"))" ]] \
  || fail "expected the author's test to stand before both events, got: $found"
[[ "$found" == *"github.event.comment.user.login == github.repository_owner"* ]] || fail "expected a comment to start Peta only when the owner wrote it"

scenario "implement.yml needs the label to be on a trusted account's ticket or added by the owner, and nothing for a start by number"
[[ "$(condition implement implement)" == "if: >- github.event_name == 'workflow_dispatch' || (github.event.label.name == 'ready' && ($associated) || $bots) || $owner_asked))" ]] \
  || fail "expected the label to need the ticket's author or the owner, got: $(condition implement implement)"

scenario "revert.yml needs the label to be on a trusted account's ticket or added by the owner"
[[ "$(condition revert revert)" == "if: >- github.event.label.name == 'revert' && ($associated) || $bots) || $owner_asked)" ]] \
  || fail "expected the label to need the ticket's author or the owner, got: $(condition revert revert)"

scenario "a review starts a job of approve-merge.yml only when the owner wrote it, and no job runs for another account's"
[[ "$(condition approve-merge ship)" == *"(github.event.review.state == 'approved' && github.event.review.user.login == github.repository_owner))"* ]] \
  || fail "expected an approval to count only when the owner wrote it"
[[ "$(condition approve-merge send-back)" == *"github.event.review.state == 'changes_requested' && github.event.review.user.login == github.repository_owner"* ]] \
  || fail "expected a request for changes to count only when the owner wrote it"
[[ "$(condition approve-merge test-main)" == *"github.event_name == 'pull_request_target' && "* ]] || fail "expected test-main to run for no review"

scenario "a run of approve-merge.yml whose jobs are skipped takes the place of none that waits: the group is on each job"
! grep -q '^concurrency:' "$workflows/approve-merge.yml" || fail "expected approve-merge.yml to hold no group on the workflow"
for job in $(jobs_of approve-merge); do
  # shellcheck disable=SC2016
  job approve-merge "$job" | grep -A1 -x '    concurrency:' | grep -qxF '      group: approve-merge-${{ inputs.pr || github.event.pull_request.number }}' \
    || fail "expected the $job job to hold the pull request's group"
done
[ "$(jobs_of approve-merge | xargs)" = "test-main ship send-back" ] || fail "expected the three jobs, got: $(jobs_of approve-merge | xargs)"
