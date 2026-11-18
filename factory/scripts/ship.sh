#!/usr/bin/env bash
# Ships a pull request: squash-merges it, closes its ticket, waits for production, marks the ticket deployed.
# Usage: ship.sh <pr-number> <head-sha>
#        Needs GH_TOKEN (contents, pull-requests, issues and actions: write; statuses: read) and PRODUCTION_URL.
#        GITHUB_REPOSITORY and GITHUB_RUN_ID, which a workflow sets, are read by needs-e2e.sh, rerun-fits-main.sh
#        and start-fix-round.sh.
#        BOARD_TOKEN, when set, lets apply-setup.sh re-run board.sh after a merge that changed it, and
#        start-waiting.sh read the order of the board.
set -euo pipefail

pr="$1"; head="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"
issue=$(retry "$script_dir/linked-issue.sh" "$pr") \
  || not_merged "GitHub did not return this pull request's description, so the ticket it closes is not known"

# Each answer is read on its own line, so a read GitHub never answers is never taken for "tested" (decisions H7).
base=$(retry gh pr view "$pr" --json baseRefName --jq .baseRefName) \
  || not_merged "GitHub did not say which branch this pull request merges into"
main=$(retry gh api "repos/{owner}/{repo}/commits/$base" --jq .sha) \
  || not_merged "GitHub did not say which commit \`$base\` is at, so nothing shows this was tested with it"
# Before the test with main, which a branch about to change would only repeat (decisions W281a, W281b).
overtaken=$(retry "$script_dir/overtaken.sh" "$pr" "$base" "$head") \
  || not_merged "GitHub did not say whether \`$base\` has changed a workflow source this pull request changes, and the installer refuses such a change once it is merged"
if [ -n "$overtaken" ]; then
  why="$(tr '\n' ' ' <<<"$overtaken")The installer would refuse the change once merged, and \`pnpm lint\` would fail on \`$base\` for every pull request"
  rounds=$(retry "$script_dir/fix-rounds.sh" "$pr") && before=$(retry "$script_dir/fix-rounds.sh" "$pr" conflict "$head") \
    || not_merged "$why. Its fix rounds could not be counted, so none was started to merge \`$base\` into the branch"
  # `app/claude` is how gh writes the app that opens the factory's pull requests.
  author=$(retry gh pr view "$pr" --json author --jq .author.login) \
    || not_merged "$why. GitHub did not say who opened this pull request, so no fix round was started to merge \`$base\` into the branch"
  if [ "$author" != app/claude ] || [ "$rounds" -ge 3 ] || [ "$before" -gt 0 ]; then
    # A person's own gets no round, nor one with none left, as for a conflict (decisions A124c, A124g).
    # Each comment that flags it says first what a person must do (decisions A371a).
    retry gh pr comment "$pr" --body "On this pull request's branch, run \`git fetch origin $base && git merge origin/$base\`, then push: the new commit is checked and merged like any other.

Not merged: $why. This pull request gets no fix round to merge \`$base\` into the branch." >/dev/null
    retry gh pr edit "$pr" --add-label needs-human >/dev/null
    exit 0
  fi
  message=$("$script_dir/start-fix-round.sh" "$pr") \
    || not_merged "$why. The fix round that merges \`$base\` into the branch could not be started"
  retry gh pr comment "$pr" --body "Not merged: $why. Its engineer merges \`$base\` into the branch first: $message. The new commit is then checked and merged like any other." >/dev/null
  exit 0
fi
run=$(retry "$script_dir/ci-run.sh" "$head" databaseId,status) \
  || not_merged "GitHub did not return the ci run for ${head:0:7}, so nothing shows it was tested"
[ -n "$run" ] || not_merged "there is no ci run for ${head:0:7}, so nothing shows it was tested"
run_status="${run##* }"; run="${run%% *}"
# A job that passes with main leaves an artifact on the ci run, named after that commit of main (decisions M19).
tested=$(retry gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" --paginate --jq '.artifacts[].name') \
  || not_merged "GitHub did not return the record of which \`$base\` the ci run for ${head:0:7} passed with"
if ! grep -qxF "tested-with-main-$main" <<<"$tested"; then
  if [ "$run_status" != completed ] && [ "$run" != "${GITHUB_RUN_ID:-}" ]; then
    # GitHub lists jobs only as it creates them, so one still going cannot show it predates fits-main (decisions M25).
    message="a newer ci run for ${head:0:7} is still going, and its own merge gate decides once it has tested this with \`$base\`"
    echo "$message; not merged"
    retry gh pr comment "$pr" --body "Not merged yet: $message." >/dev/null
    exit 0
  fi
  jobs=$(retry gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" --paginate --jq '.jobs[].name') \
    || not_merged "GitHub did not return the jobs of the ci run for ${head:0:7}, so whether it can be tested with \`$base\` again is not known"
  if ! grep -qxF fits-main <<<"$jobs"; then
    # Decisions M25.
    echo "the ci run for ${head:0:7} began before fits-main was installed; merging without a test against $base as it is now"
  else
    # The merge gate runs again after fits-main, so nobody has to approve twice (decisions M18).
    marker="<!-- factory:fits-main $main -->"
    rerun_requests=$(retry gh pr view "$pr" --json comments --jq "[.comments[] | select(.body | contains(\"$marker\"))] | length") \
      || not_merged "GitHub did not return this pull request's comments, so whether \`fits-main\` was already run again for \`$base\` at ${main:0:7} is not known"
    if [ "$rerun_requests" -ne 0 ]; then
      # Decisions M24.
      retry gh pr comment "$pr" --body "Read why the \`fits-main\` job of the ci run for ${head:0:7} left no result, then push a commit to this pull request: the new commit is checked and merged like any other.

Not merged: \`fits-main\` was already run again for \`$base\` at ${main:0:7} and left no result for that commit. Asking again would go round in a circle." >/dev/null
      retry gh pr edit "$pr" --add-label needs-human >/dev/null
      exit 1
    fi
    if ! message=$("$script_dir/rerun-fits-main.sh" "$pr"); then
      not_merged "\`$base\` has moved to ${main:0:7} since this pull request was last tested with it, and \`fits-main\` could not be started again"
    fi
    retry gh pr comment "$pr" --body "${marker}Not merged yet: \`$base\` has moved to ${main:0:7} since this pull request was last tested with it, so ${message}. If that passes, a pull request the factory opened merges with no new approval; anyone else's merges when the owner approves it again." >/dev/null
    exit 0
  fi
fi

# GitHub can fail the call having made the commit, so main is looked at before every call (decisions M27).
on_main() {
  # GitHub titles a squash commit "<title> (#<pr>)".
  gh api "repos/{owner}/{repo}/commits?sha=$base&per_page=30" \
    --jq "[.[] | select(.commit.message | split(\"\n\")[0] | endswith(\" (#$pr)\"))][0].sha // empty"
}
called=no
tries=0
while :; do
  commit=$(retry on_main) \
    || not_merged "GitHub did not list the commits on \`$base\`, so whether this pull request is already merged there is not known, and merging twice would add an empty commit"
  [ -z "$commit" ] || break
  # Three calls, a judgement (decisions M28).
  [ "$tries" -lt 3 ] || not_merged "GitHub failed or refused the merge three times, and \`$base\` holds no commit for this pull request. Its last answer was: $(tail -n 1 <<<"$response")"
  tries=$((tries + 1))
  # --match-head-commit: merge exactly what was checked and reviewed, never a later push (decisions M12).
  if response=$(gh pr merge "$pr" --squash --delete-branch --match-head-commit "$head" 2>&1); then
    called=yes
    commit=$(retry gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""') || commit=""
    [ -n "$commit" ] || commit=$(retry on_main) || commit=""
    break
  fi
  echo "$response" >&2
  sleep 10
done
[ "$called" = yes ] || echo "\`$base\` already holds this pull request's commit, ${commit:0:7}; not merged a second time"

# From here it is merged: every step is tried, and what did not finish is kept for one comment (decisions M14, M30).
incomplete=""
unfinished() { incomplete+="- $1"$'\n'; echo "did not finish: $1" >&2; }

retry gh pr edit "$pr" --remove-label needs-human >/dev/null \
  || unfinished "the \`needs-human\` label could not be taken off this pull request"
[ -z "$issue" ] || retry gh issue edit "$issue" --remove-label in-progress --remove-label needs-human >/dev/null \
  || unfinished "the \`in-progress\` and \`needs-human\` labels could not be taken off ticket #$issue"
# Closed here, before the queue is read, not in GitHub's own time after the merge (decisions T359b).
[ -z "$issue" ] || retry gh issue close "$issue" >/dev/null || unfinished "ticket #$issue could not be closed"

# The place this merge freed goes to a ticket that waits (decisions T269a), one that comes after this ticket
# included: GitHub may still list it as open (decisions T339f).
"$script_dir/start-waiting.sh" ${issue:+--closed "$issue"} || unfinished "the tickets that wait with \`ready\` were not all started (\`start-waiting.sh\` failed); each is started when a place next frees"

# A retro only after a fix round or an owner's round; a conflict's are in neither count (decisions A48d, A124b, A124g).
if rounds=$(retry "$script_dir/fix-rounds.sh" "$pr") && owner_rounds=$(retry "$script_dir/fix-rounds.sh" "$pr" owner); then
  [ "$((rounds + owner_rounds))" -eq 0 ] || gh workflow run retro.yml -f pr="$pr" || unfinished "the retro could not be started"
else
  unfinished "the fix rounds could not be counted, so no retro was started"
fi

# Started here because this already runs after every merge (decisions A185b).
"$script_dir/first-runs.sh" || unfinished "a retro was not started for every first run of a changed workflow (\`first-runs.sh\` failed)"

# Before the wait for production, as it does not depend on the deploy (decisions M14).
"$script_dir/apply-setup.sh" "$pr" ${commit:+"$commit"} || unfinished "the changes to setup scripts, if there were any, could not be applied (\`apply-setup.sh\` failed)"

# A merged revert reopens the ticket it took back (decisions T19a).
[ -z "$issue" ] || "$script_dir/revert.sh" shipped "$issue" "$pr" \
  || unfinished "if this pull request took a ticket back, that ticket was not reopened as \`reverted\` (\`revert.sh\` failed)"

# Only started here: its workflow checks what it may install and holds the one credential that can write a workflow.
if files=$(retry gh api "repos/{owner}/{repo}/pulls/$pr/files" --paginate --jq '.[].filename'); then
  if grep -q '^factory/workflows/' <<<"$files"; then
    gh workflow run install-workflows.yml -f pr="$pr" || unfinished "the workflow installer could not be started, so the changed workflows are not installed"
  fi
else
  unfinished "the changed files could not be listed, so a changed workflow was not installed"
fi

# A conflict stops a merge and nothing else sends it back to its engineer, so a fix round is started (decisions M21).
fix_conflicting() {
  local list number state head rounds before tries=0 status=0
  # GitHub answers UNKNOWN for `mergeable` until some time after the merge, so it is asked a few times.
  while :; do
    # `app/claude` is how gh writes the app that opens the factory's pull requests.
    list=$(gh pr list --state open --base "$base" --limit 100 --json number,mergeable,author,headRefOid \
      --jq '.[] | select(.author.login == "app/claude") | "\(.number) \(.mergeable) \(.headRefOid)"') || return 1
    tries=$((tries + 1))
    if ! grep -q ' UNKNOWN ' <<<"$list" || [ "$tries" -ge 6 ]; then break; fi
    sleep 5
  done
  while read -r number state head; do
    case "$state" in
      CONFLICTING)
        # Three rounds used (decisions A5), or a conflict round run at this head (A124g): a start would only be refused.
        if ! rounds=$("$script_dir/fix-rounds.sh" "$number") || ! before=$("$script_dir/fix-rounds.sh" "$number" conflict "$head"); then
          status=1
        elif [ "$rounds" -ge 3 ]; then
          echo "pull request #$number conflicts with $base, but has used its three fix rounds and waits for a person; no fix round is started"
        elif [ "$before" -gt 0 ]; then
          echo "pull request #$number conflicts with $base, but a fix round for a conflict already ran for its head ${head:0:7} and it waits for a person; no fix round is started"
        else
          "$script_dir/start-fix-round.sh" "$number" || status=1
        fi ;;
      UNKNOWN) echo "GitHub has not said whether pull request #$number conflicts with $base; it is tested with $base before it merges" ;;
    esac
  done <<<"$list"
  return "$status"
}
fix_conflicting || unfinished "a fix round was not started for every open pull request this merge left in conflict"

# This merge may be what a pull request labelled `waits-for-main` waited for (decisions A368a).
"$script_dir/start-retests.sh" || unfinished "not every pull request labelled \`waits-for-main\` is tested again (\`start-retests.sh\` failed); the next merge tests it"

if [ -z "$commit" ]; then
  unfinished "GitHub did not return the merge commit, so the deploy was not checked"
elif [ -z "${PRODUCTION_URL:-}" ]; then
  echo "merged as ${commit:0:7}; no PRODUCTION_URL is set, so the deploy was not confirmed"
else
  code=0
  message=$("$script_dir/wait-for-deploy.sh" "$PRODUCTION_URL" "$commit") || code=$?
  [ -z "$message" ] || echo "$message"
  case "$code" in
    0)
      retry gh pr comment "$pr" --body "Deployed: production at $PRODUCTION_URL is running ${commit:0:7}." >/dev/null \
        || unfinished "production at $PRODUCTION_URL is running ${commit:0:7}, and the comment saying so could not be posted"
      [ -z "$issue" ] || retry gh issue edit "$issue" --add-label deployed >/dev/null \
        || unfinished "production is running ${commit:0:7}, and ticket #$issue could not be labelled \`deployed\`" ;;
    2)
      # No app code changed means nothing to deploy (decisions M165c, M33); needs-e2e.sh says changed when unsure.
      if [ "$("$script_dir/needs-e2e.sh" "$pr" 2>/dev/null)" = run=false ]; then
        retry gh pr comment "$pr" --body "Merged as ${commit:0:7}. Nothing was deployed: this pull request changes no app code, so Vercel built nothing and production at $PRODUCTION_URL is as it was." >/dev/null \
          || unfinished "this pull request changes no app code, so Vercel deployed nothing, and the comment saying so could not be posted"
      else
        unfinished "the deploy check: Vercel skipped the deployment of this commit, so production at $PRODUCTION_URL will never report it and the ticket is not marked \`deployed\`"
      fi ;;
    *)
      unfinished "the deploy check: production at $PRODUCTION_URL did not report that commit within 10 minutes. Check the Vercel deployment" ;;
  esac
fi

# Decisions M221a, M221b, M246.
if [ -n "$issue" ]; then
  if figures=$("$script_dir/ticket-cost.sh" --json "$pr"); then
    "$script_dir/measures.sh" record <<<"$figures" || echo "the measures of ticket #$issue were not recorded" >&2
    cost=$("$script_dir/ticket-cost.sh" --comment <<<"$figures") && retry gh issue comment "$issue" --body "$cost" >/dev/null \
      || echo "what ticket #$issue cost could not be posted on it" >&2
  else
    echo "what ticket #$issue cost could not be worked out, so it was not posted on it and its measures were not recorded" >&2
  fi
fi

# GitHub may still show as open a pull request an earlier call merged: it is left open for a person (decisions M29).
# The comment that flags it says first what a person must do (decisions A371a).
todo=""
if [ "$called" = no ]; then
  state=$(retry gh pr view "$pr" --json state --jq .state) || state=""
  if [ "$state" != MERGED ]; then
    unfinished "GitHub does not show this pull request as merged, though \`$base\` holds its commit. It was not merged a second time, which would add an empty commit"
    todo="Close this pull request and its ticket by hand: the factory leaves both open."$'\n\n'
    retry gh pr edit "$pr" --add-label needs-human >/dev/null || true
  fi
fi

[ -n "$incomplete" ] || exit 0
body=$(printf '%sMerged as %s, but not everything that follows a merge finished:\n\n%s\n%s' "$todo" "${commit:0:7}" "$incomplete" "$(run_log)")
retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and the pull request could not be told so" >&2
exit 1
