#!/usr/bin/env bash
# Decides, as the first step of a fix round (fix.yml), whether the round goes ahead and for whom.
# Usage: begin-fix-round.sh <pr-number> <failures-file> [owner-login]
#        Needs GH_TOKEN (pull-requests, issues and actions: write) and GITHUB_REPOSITORY.
set -euo pipefail

usage="Usage: begin-fix-round.sh <pr-number> <failures-file> [owner-login]"
pr="${1:?$usage}"; failures="${2:?$usage}"; owner="${3:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
outputs="${GITHUB_OUTPUT:-/dev/null}"

skip() { echo "go=false" >> "$outputs"; echo "no fix round: $1"; exit 0; }
die() { echo "go=false" >> "$outputs"; echo "$1" >&2; exit 1; }

# The number goes into a prompt and into calls, and no caller is taken on trust (decisions A89f).
[[ "$pr" =~ ^[0-9]+$ ]] || die "\"$pr\" is not a pull request number."

# Read on a line of its own (decisions H7). gh writes the app that opens the factory's pull requests as `app/claude`.
pull=$(gh pr view "$pr" --json state,author,headRefOid,headRefName,labels \
    --jq '"\(.state) \(.author.login) \(.headRefOid) \(.headRefName) \([.labels[].name] | index("waits-for-main") != null)"') \
  || die "Could not read pull request #$pr from GitHub, so no fix round was begun."
read -r state author head branch marked <<<"$pull"
[ "$state" = OPEN ] || skip "pull request #$pr is not open"
[ "$author" = app/claude ] || skip "pull request #$pr was not opened by the factory, and is its author's to fix"

"$script_dir/collect-failures.sh" "$failures" "$pr" >&2 \
  || die "What failed on pull request #$pr could not be read, so no fix round was begun."
requested=""
if [ -n "$owner" ]; then
  # The file is the engineer's evidence, and is not left without part of it.
  requested=$("$script_dir/owner-review.sh" "$pr" "$owner" "$failures") \
    || { rm -f "$failures"; die "What $owner asked for on pull request #$pr could not be read, so no fix round was begun."; }
fi
[ -s "$failures" ] || skip "nothing is there to fix on pull request #$pr: the latest ci run for its head ${head:0:7} has no failed job, GitHub reports no conflict, and its owner has not sent it back"

# Before the rounds are counted, so that one with none left is not stopped for this (decisions A134a).
alarm=$("$script_dir/false-alarm.sh" "$pr" "$failures") \
  || die "Whether an engineer can fix what failed on pull request #$pr is not known, so no fix round was begun."
if [ "$alarm" = true ]; then
  # 120 seconds: the job that asked for this round is in that ci run, and has only to finish.
  "$script_dir/rerun-checks.sh" "$pr" 120 >&2 \
    || die "No fix round was begun for pull request #$pr: its checks failed because the workflows on main had not settled, and could not be run again."
  skip "the checks of pull request #$pr failed because the workflows on main had not settled after a merged change, which no engineer can fix: checks is running again"
fi

# Before the rounds are counted as well (decisions A142a).
fresh=$("$script_dir/needs-fresh-run.sh" "$pr" "$failures") \
  || die "Whether pull request #$pr needs only a fresh ci run is not known, so no fix round was begun."
workflow=""
[ "${fresh%% *}" != true ] || workflow="${fresh#true }"

# The owner's round is the owner's whatever the label says, and merges main too; any other for a labelled pull request is its retest (decisions A368a).
retest=false
[ "$marked" != true ] || [ -n "$requested" ] || retest=true

conflict=false
if [ -z "$requested" ] && [ "$retest" = false ] && [ -z "$workflow" ]; then
  # No failed job but `fits-main` leaves only a conflict to fix (decisions A124b).
  others=$(awk '/^===== failed job: / && $0 != "===== failed job: fits-main =====" { n++ } END { print n + 0 }' "$failures")
  [ "$others" -ne 0 ] || conflict=true
  # After the check above: a pull request its third round got to green is not told it stopped (decisions A89h).
  rounds=$("$script_dir/fix-rounds.sh" "$pr") \
    || die "The fix rounds of pull request #$pr could not be counted, so no fix round was begun."
  if [ "$rounds" -ge 3 ]; then
    "$script_dir/stop-fix-rounds.sh" "$pr" || die "No fix round was begun for pull request #$pr."
    skip "pull request #$pr has used its three fix rounds, and waits for a person"
  fi
  if [ "$conflict" = true ]; then
    # Nothing else bounds these rounds, so a head gets one (decisions A124g).
    before=$("$script_dir/fix-rounds.sh" "$pr" conflict "$head") \
      || die "The fix rounds for a conflict of pull request #$pr could not be counted, so no fix round was begun."
    [ "$before" -eq 0 ] || skip "a fix round for a conflict already ran for pull request #$pr at ${head:0:7} and left it in conflict: it waits for a person"
  fi
fi

# Whoever built it fixes it, Rosa with the tools her build had (decisions A33a, A33b).
issue=$("$script_dir/linked-issue.sh" "$pr") \
  || die "The ticket pull request #$pr closes could not be read, so who built it is not known."
type=""
if [ -n "$issue" ]; then
  type=$(gh issue view "$issue" --json labels --jq '[.labels[].name] | map(select(. == "factory" or . == "research")) | first // ""') \
    || die "Issue #$issue could not be read from GitHub, so who built pull request #$pr is not known."
fi
tools="Read,Write,Edit,Glob,Grep,Bash"
case "$type" in
  factory) name=Fred; role=fred-fix; skill=.claude/skills/factory-engineer/SKILL.md ;;
  research)
    name=Rosa; role=rosa-fix; skill=.claude/skills/research/SKILL.md
    tools="Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(git:*),Bash(gh:*),Bash(pnpm lint),Bash(factory/scripts/check-research.sh:*),Bash(factory/scripts/check-pr-conventions.sh:*)" ;;
  *) name=Esme; role=esme-fix; skill=.claude/skills/implement/SKILL.md ;;
esac

run_link=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_link=" ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
if [ -n "$requested" ]; then
  counted=false; label="the owner's fix round"
  message="The owner's fix round: $name is making the changes the owner asked for. It is not one of the three fix rounds."
  if [ "$marked" = true ]; then
    # This round is the retest as well: left labelled, each merge would begin the owner's round again.
    {
      echo "===== waits for main ====="
      echo "This pull request is labelled waits-for-main: its engineer found that a job above failed for a reason outside it, and main has changed since."
      echo "Merge main into the branch as well (git fetch origin main && git merge origin/main), and resolve a conflict if there is one."
      echo "Your push runs the checks again, with main as it is now."
    } >> "$failures"
  fi
elif [ "$retest" = true ]; then
  counted=retest; label="fix round for a retest"
  message="A fix round for a retest: $name is merging \`main\` into the branch, which runs its checks again. What failed lay outside this pull request and \`main\` has changed since, so it is not one of the three fix rounds."
  # The engineer judged what failed to be outside the pull request, so this round is given the merge alone.
  {
    echo "===== waits for main ====="
    echo "This pull request is labelled waits-for-main: its engineer found that what failed lay outside it, and main has changed since."
    echo "Merge main into the branch (git fetch origin main && git merge origin/main), resolve a conflict if there is one, and push."
    echo "The push runs the checks again, with main as it is now. Change nothing else in this round."
  } > "$failures"
elif [ -n "$workflow" ]; then
  counted="fresh-run:$workflow"; label="fix round for a fresh run"
  message="A fix round for a fresh run: $name is merging the base into the branch. Its checks ran with a workflow the base no longer holds, in which no reviewer is given a token, and only a push starts a run with the one it holds now. Nothing else failed, so it is not one of the three fix rounds."
elif [ "$conflict" = true ]; then
  counted=conflict; label="fix round for a conflict"
  message="A fix round for a conflict: $name is fitting the branch to its base. Nothing else failed, so it is not one of the three fix rounds."
else
  counted=true; label="fix round $((rounds + 1)) of 3"
  message="Fix round $((rounds + 1)) of 3: $name is addressing what failed."
  # Said to the one session that can act on it, and not in every engineer's skill (decisions A368d).
  {
    echo "===== when no change to this pull request can fix what failed ====="
    echo "A job may have failed for a reason outside this pull request: a setting, a secret, a service, or code on main that only another ticket may change."
    echo "If no push of yours would then make it pass, push nothing. Run: gh pr edit $pr --add-label waits-for-main"
    echo "Then say in one pull request comment what the pull request waits for. The next merge to main starts a round that tests it again."
  } >> "$failures"
fi
gh pr comment "$pr" --body "$message$run_link" >/dev/null \
  || die "Could not say on pull request #$pr that a fix round has begun, so it was not begun."

# Last, so that a pull request no round was begun for still waits for its owner.
# It is worked on again, so it takes a place among the tickets being built (decisions T361b).
# The label comes off with it: one retest for each time a pull request is labelled (decisions A368a).
unmark=""
[ "$marked" != true ] || unmark=waits-for-main
gh pr edit "$pr" --remove-label needs-human ${unmark:+--remove-label "$unmark"} >/dev/null \
  || die "Could not take needs-human off pull request #$pr, so no fix round was begun."
if [ -n "$requested" ] && [ -n "$issue" ]; then
  gh issue edit "$issue" --remove-label needs-human --add-label in-progress >/dev/null \
    || die "Could not mark issue #$issue as in progress again, so the owner's fix round on pull request #$pr was not begun."
fi

{
  echo "go=true"
  echo "counted=$counted"
  [ "$counted" != true ] || echo "round=$((rounds + 1))"
  echo "label=$label"
  echo "branch=$branch"
  echo "head=$head"
  echo "name=$name"
  echo "role=$role"
  echo "skill=$skill"
  echo "tools=$tools"
} >> "$outputs"
echo "$label for pull request #$pr: $name fixes ${branch} at ${head:0:7}"
