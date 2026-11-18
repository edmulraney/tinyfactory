#!/usr/bin/env bash
# The last step of a build or a fix round: keeps work that was not handed over, says where it is and asks for a person.
# Usage: flag-unfinished.sh build <issue-number> <execution-file>
#        flag-unfinished.sh fix   <pr-number>    <execution-file> <head-before> [counted]
#        The execution file is the last session's saved result, read for the cause.
#        `counted` is what begin-fix-round.sh wrote: only `false` says the round is the owner's.
#        Needs GH_TOKEN (issues, pull requests, contents and actions: write) and GITHUB_REPOSITORY.
#        A GitHub call that fails stops it with a message and exit 1; work already pushed stays pushed.
set -euo pipefail

kind="$1"; number="$2"; file="${3:-}"; before="${4:-}"; counted="${5:-true}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }

case "$kind" in
  build)
    what="issue #$number"
    # Open and no draft, which is still being built (decisions A50a); one closed before a rebuild is not this build's.
    tries=0
    # GitHub answers UNKNOWN for `mergeable` until some time after a push, so it is asked a few times.
    while :; do
      ready=$(gh pr list --state open --json number,headRefName,isDraft,mergeable --jq ".[] | select(.isDraft | not) | select(.headRefName | test(\"^[a-z]+/$number-\")) | \"\(.number) \(.mergeable)\"") \
        || die "The pull requests could not be read from GitHub, so it is not known whether one is ready for review for issue #$number."
      tries=$((tries + 1))
      if ! grep -q ' UNKNOWN$' <<<"$ready" || [ "$tries" -ge 6 ]; then break; fi
      sleep 5
    done
    if [ -n "$ready" ]; then
      echo "handed over: a pull request is ready for review for issue #$number"
      # One marked ready while it conflicts gets no ci run, so nothing would send it back for a fix (decisions A124a).
      while read -r pr state; do
        case "$state" in
          CONFLICTING)
            "$script_dir/start-fix-round.sh" "$pr" \
              || die "Pull request #$pr is ready for review and conflicts with its base, and no fix round could be started for it: it waits with no checks until a person acts." ;;
          UNKNOWN) echo "GitHub has not said whether pull request #$pr conflicts with its base; if it does, the next merge starts its fix round" ;;
        esac
      done <<<"$ready"
      exit 0
    fi
    flagged=$(gh issue view "$number" --json labels --jq '[.labels[].name] | index("needs-human") != null') \
      || die "Issue #$number could not be read from GitHub, so it is not known whether the engineer stopped on purpose."
    if [ "$flagged" = true ]; then
      gh issue edit "$number" --remove-label in-progress >/dev/null \
        || die "Could not take in-progress off issue #$number."
      echo "the engineer stopped on purpose and flagged issue #$number"
      # The place it gave back goes to a ticket that waits (decisions T297a).
      "$script_dir/start-waiting.sh" \
        || die "Issue #$number gave its place back, and the tickets that wait with ready were not all started; each is started when a place next frees."
      exit 0
    fi
    ;;
  fix)
    what="pull request #$number"
    pull=$(gh pr view "$number" --json headRefOid,labels --jq '"\(.headRefOid) \([.labels[].name] | index("waits-for-main") != null)"') \
      || die "Pull request #$number could not be read from GitHub, so it is not known whether a fix was pushed."
    read -r head marked <<<"$pull"
    if [ "$head" != "$before" ]; then echo "handed over: a fix was pushed to pull request #$number"; exit 0; fi
    ;;
  *) echo "usage: flag-unfinished.sh build <issue-number> <execution-file> | fix <pr-number> <execution-file> <head-before>" >&2; exit 2 ;;
esac

ended=""; cause=""; resets=""; answer=""
while IFS='=' read -r name value; do
  case "$name" in ended) ended=$value ;; cause) cause=$value ;; resets) resets=$value ;; answer) answer=$value ;; esac
done < <("$script_dir/session-outcome.sh" "$file")

# kept: `branch` (the work is on a branch on GitHub), `nothing` (there was none), or `lost`.
kept=nothing; branch=""
if branch=$("$script_dir/keep-work.sh" "$what"); then
  if [ -n "$branch" ]; then
    kept=branch
    # A fix round's branch was on GitHub before the round: it holds work only with a commit the round began without.
    if [ "$kind" = fix ] && git merge-base --is-ancestor HEAD "$before" 2>/dev/null; then kept=nothing; fi
  fi
else
  kept=lost
fi

run_link=""
[ -z "${GITHUB_RUN_ID:-}" ] || run_link=" See $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
lost="What the engineer had could not be pushed, and is lost with the runner."
# Nothing starts before the usage limit resets (decisions A231b).
after=""
[ -z "$resets" ] || after=" after $(jq -rn --argjson at "$resets" '$at | strftime("%Y-%m-%d %H:%M UTC")')"

# Each comment's first line says what a person must do (decisions A371a).
if [ "$kind" = build ]; then
  case "$kept" in
    branch)
      todo="Add the \`ready\` label again$after: the next build starts from the branch \`$branch\`."
      message="What the engineer had is on the branch \`$branch\`, unfinished and unverified; its pull request, if it has one, is still a draft." ;;
    nothing)
      todo="Add the \`ready\` label again$after: the build starts again from the beginning."
      message="There was no work to keep: the engineer had not started a branch, or had changed nothing on it." ;;
    lost)
      todo="Add the \`ready\` label again$after: the build starts again from the beginning."
      message=$lost ;;
  esac
  # start-build.sh reads the reset time from the start of this comment (decisions A231b).
  until=""
  [ -z "$resets" ] || until="<!-- factory:usage-limit $resets -->"
  gh issue comment "$number" --body "${until}$todo

The build ended with no pull request ready for review: $cause. $message$run_link" >/dev/null \
    || die "Could not comment on issue #$number: the build ended with no pull request ready for review ($cause)."
  gh issue edit "$number" --add-label needs-human --remove-label in-progress >/dev/null \
    || die "Could not add needs-human to issue #$number."
  echo "the build ended with no pull request ready for review: $cause"
  # The place goes to a ticket that waits, when the ending was this ticket's own (decisions T297a, T297b).
  case "$ended" in
    completed|max_turns)
      "$script_dir/start-waiting.sh" \
        || echo "Issue #$number gave its place back, and the tickets that wait with ready were not all started; each is started when a place next frees." >&2 ;;
    *) echo "no waiting ticket was started: its build could end the same way" ;;
  esac
  # So that a retro learns from it (decisions A20), unless its session would meet the same limit (decisions A231c).
  [ "$ended" = usage_limit ] && [ "$kept" != lost ] && exit 0
  exit 1
fi

again="Run \`gh workflow run fix.yml -f pr=$number\`$after: a new fix round starts."
case "$kept" in
  branch)
    todo="Submit a \"Request changes\" review$after saying what is left to do: the engineer carries on from the branch in a fix round that is not one of the three."
    message="The fix round ended without handing over a fix: $cause. What the engineer had is on the branch \`$branch\`, unfinished and unverified; no checks ran on it." ;;
  lost)
    todo=$again
    message="The fix round ended without handing over a fix: $cause. $lost" ;;
  nothing)
    if [ "$ended" = completed ] && [ "$marked" = true ]; then
      # Flagged all the same, so that it holds no place while it waits (decisions A368b).
      todo="Nothing to do: the next merge to \`main\` tests this pull request again."
      message="The fix round pushed nothing: the engineer labelled this pull request \`waits-for-main\`, as what failed lies outside it, and the comment above says what it waits for."
    elif [ "$ended" = completed ]; then
      # The engineer stopped on purpose, so its answer says what it needs (decisions A371b).
      todo=${answer:-"Read the engineer's comment above, then submit a \"Request changes\" review saying what to change: that starts a fix round that is not one of the three."}
      message="The fix round pushed nothing: the engineer ended the session with no change to the pull request, which is as the checks and reviews last saw it. If the findings were rebutted, the reasons are in the comments above."
    else
      todo=$again
      message="The fix round ended without pushing a fix: $cause. The engineer left no work to keep, and the pull request is as the checks and reviews last saw it."
    fi ;;
esac
gh pr comment "$number" --body "$todo

$message$run_link" >/dev/null \
  || die "Could not comment on pull request #$number: the fix round pushed nothing ($cause)."
gh pr edit "$number" --add-label needs-human >/dev/null \
  || die "Could not add needs-human to pull request #$number."
# The owner's round took `needs-human` off the ticket as it began (decisions A48c).
[ "$counted" != false ] || "$script_dir/flag-ticket.sh" "$number" || exit 1
echo "the fix round pushed nothing: $cause"
# Any ending but the engineer's own or the usage limit's, and any work lost, is the factory's failure (decisions A20, A231c).
{ [ "$ended" = completed ] || [ "$ended" = usage_limit ]; } && [ "$kept" != lost ]
