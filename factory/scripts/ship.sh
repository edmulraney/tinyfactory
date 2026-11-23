#!/usr/bin/env bash
# Ships a tested group of pull requests: squash-merges each in turn, closes its ticket and marks it deployed.
# Usage: ship.sh <result-file> <pr>:<head>...
#        The pull requests are the group begin-group.sh listed, and the file holds what test-group.sh found of them.
#        ship.sh --merged <pr-number>   does what follows a merge for a pull request a person merged with GitHub's
#                                       merge button, and nothing for one this script merged (decisions M435a)
#        Needs GH_TOKEN (contents, pull-requests, issues and actions: write; statuses and checks: read) and PRODUCTION_URL.
#        GITHUB_REPOSITORY, which a workflow sets, is read by merge-queue.sh, needs-e2e.sh, start-fix-round.sh and start-retests.sh.
#        BOARD_TOKEN, when set, lets apply-setup.sh re-run board.sh after a merge that changed it, and
#        start-waiting.sh read the order of the board.
#        ship.sh --not-begun            starts merge-group.yml again when begin-group.sh failed, so that no group
#                                       was begun, or on the third try tells each pull request that waits
#        TRY, when set, says which test of the group this is after a fault: 1, 2 or 3 (decisions M455j).
set -euo pipefail

usage="Usage: ship.sh <result-file> <pr>:<head>... | --merged <pr> | --not-begun"
result="${1:?$usage}"; shift
[ $# -gt 0 ] || [ "$result" = --not-begun ] || { echo "$usage" >&2; exit 1; }
if [ "$result" = --merged ]; then already_merged=yes; pr="$1"; else already_merged=no; group="$*"; fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"
base=main
status=0
try="${TRY:-1}"
[[ "$try" =~ ^[0-9]+$ ]] || { echo "TRY is \"$try\", and must be a number" >&2; exit 1; }
# What is known of each pull request, in files named <pr>.<what>.
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# test_again <try> <why> <pr>:<head>...: each keeps its place, and merge-group.yml tests them again as that try.
# A fault that stays for three tries, or a run that cannot be started, reaches a person (decisions M455j).
test_again() {
  local next="$1" why="$2" pull number body group_page; shift 2
  if [ "$next" -le 3 ] && start_merge_group "$next"; then
    echo "$why. Each of $* keeps its place, and merge-group.yml was started to test them again, as try $next of 3"
    return 0
  fi
  if [ "$next" -le 3 ]; then why+=", and \`merge-group.yml\` could not be started to test its group again"; else why+=", on each of three tries"; fi
  group_page=$("$script_dir/workflow-page.sh" merge-group.yml)
  for pull; do
    number="${pull%%:*}"
    # The first line says what a person must do (decisions A371a).
    body="Start the test of this pull request's group on $group_page. This pull request still waits to merge, and that run tests and merges it.

Not merged: $why.$(run_log)"
    echo "pull request #$number: $body" >&2
    retry gh pr comment "$number" --body "$body" >/dev/null || echo "and pull request #$number could not be told so" >&2
    retry gh pr edit "$number" --add-label needs-human >/dev/null || echo "and needs-human could not be added to pull request #$number" >&2
  done
  status=1
}
# none_merged <why>: a fault that is no pull request's own, so the whole group is tested again.
none_merged() {
  # shellcheck disable=SC2086
  test_again "$((try + 1))" "$1" $group
  exit "$status"
}

# not_finished <why>: stops the script as failed for a pull request a person merged, having said why.
not_finished() {
  local body
  body="Run the failed \`approve-merge\` run for this pull request again: what follows a merge is done then.

Merged with GitHub's merge button, and nothing that follows a merge was done: $1.$(run_log)"
  echo "$body" >&2
  retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and the pull request could not be told so" >&2
  exit 1
}

# GitHub can fail the call having made the commit, so main is looked at before every call (decisions M27).
on_main() {
  # GitHub titles a squash commit "<title> (#<pr>)".
  gh api "repos/{owner}/{repo}/commits?sha=$base&per_page=30" \
    --jq "[.[] | select(.commit.message | split(\"\n\")[0] | endswith(\" (#$1)\"))][0].sha // empty"
}
# settle <pr> <head>: pushes to the pull request's branch the merge with main that keeps the lines both added to a
# marked list, and prints its commit (decisions M485a). Exit 1 when no such conflict is known to stand; exit 2, having
# kept why in $state/<pr>.detail, when the merge could not be pushed.
settle() {
  local pr="$1" head="$2" tip tree branch commit pushed whole=""
  # The merge job's checkout holds one commit of main, and a merge reads the commit both began from.
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != true ] || whole=--unshallow
  if ! { git fetch --quiet $whole origin "$base" && tip=$(git rev-parse FETCH_HEAD) \
    && git fetch --quiet origin "refs/pull/$pr/head" && [ "$(git rev-parse FETCH_HEAD)" = "$head" ]; }; then
    echo "\`$base\` and pull request #$pr at ${head:0:7} could not be fetched, so whether a conflict in a list stops its merge is not known" >&2
    return 1
  fi
  tree=$("$script_dir/settle-conflict.sh" "$tip" "$head") && [ -n "$tree" ] || return 1
  # The owner approved the commit they read, and the installer carries that approval to no merge that settles a list (decisions M485f).
  if ! git diff "$(git merge-base "$tip" "$head")" "$head" | "$script_dir/owner-decides.sh" >/dev/null 2>&1; then
    echo "It changes what only the repo's owner may decide, and they approved it as it reads at ${head:0:7}: the merge with \`$base\` that keeps the lines both added to a list is its engineer's to push, and the owner's to approve." > "$state/$pr.detail"
    return 2
  fi
  if ! branch=$(retry gh pr view "$pr" --json headRefName,isCrossRepository --jq '"\(.isCrossRepository) \(.headRefName)"') || [ -z "${branch#* }" ]; then
    echo "GitHub did not name the branch of pull request #$pr, so the merge that settles its conflict in a list was not pushed" >&2
    return 1
  fi
  # A fork's branch is in another repository, and a push here would write a branch of this one with its name.
  if [ "${branch%% *}" != false ]; then
    echo "The merge with \`$base\` that keeps the lines both added to a list cannot be pushed to a branch of another repository." > "$state/$pr.detail"
    return 2
  fi
  branch="${branch#* }"
  commit=$(git -c user.name=merge-group -c user.email=merge-group@users.noreply.github.com \
    commit-tree "$tree" -p "$head" -p "$tip" -m "Merge $base into $branch") || return 1
  if ! pushed=$(git push --quiet origin "$commit:refs/heads/$branch" 2>&1); then
    echo "The merge with \`$base\` that keeps the lines both added to a list could not be pushed to the branch:"$'\n'"$pushed" > "$state/$pr.detail"
    return 2
  fi
  echo "$commit"
}

# merge <pr> <head>: squash-merges it and keeps its commit, or says why it is not shipped here; $fault holds a fault
# of GitHub's that stopped it.
merge() {
  local pr="$1" head="$2" commit called=no tries=0 response="" merged body settled="" code
  while :; do
    if ! commit=$(retry on_main "$pr"); then
      fault="GitHub did not list the commits on \`$base\`, so whether pull request #$pr is already merged there is not known, and merging twice would add an empty commit"
      return 1
    fi
    [ -z "$commit" ] || break
    # Three tries is a judgement, not a measurement (decisions M28).
    if [ "$tries" -ge 3 ]; then
      fault="GitHub failed or refused the merge of pull request #$pr three times, and \`$base\` holds no commit for it. Its last answer was: $(tail -n 1 <<<"$response")"
      return 1
    fi
    tries=$((tries + 1))
    # --match-head-commit: merge exactly what was checked and reviewed, never a later push (decisions M12).
    if response=$(gh pr merge "$pr" --squash --delete-branch --match-head-commit "$head" 2>&1); then
      called=yes
      commit=$(retry gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // ""') || commit=""
      [ -n "$commit" ] || commit=$(retry on_main "$pr") || commit=""
      break
    fi
    echo "$response" >&2
    # GitHub's merge reads no .gitattributes, so it refuses what the test merged: that merge is pushed, once (decisions M485a).
    if [ -z "$settled" ]; then
      code=0
      settled=$(settle "$pr" "$head") || code=$?
      [ "$code" -ne 2 ] || return 1
      if [ "$code" -eq 0 ]; then
        echo "pull request #$pr conflicts with \`$base\` only where both added to a marked list: the merge that keeps both was pushed to its branch as ${settled:0:7}"
        echo "$settled" > "$state/$pr.head"
        head="$settled"; tries=0
        continue
      fi
      settled=no
    fi
    sleep 10
  done
  if [ "$called" = no ]; then
    echo "\`$base\` already holds the commit of pull request #$pr, ${commit:0:7}; not merged a second time"
    # A person's merge gets what follows it from `ship.sh --merged`, and a second time here would repeat every step
    # (decisions M435a). After a call of its own this script made the commit (decisions M27).
    if [ "$tries" -eq 0 ]; then
      if ! merged=$(retry gh pr view "$pr" --json state,mergedBy); then
        body="Run the failed job of this run again: what follows a merge is done then, unless the merge button's run does it.

\`$base\` already holds this pull request's commit, ${commit:0:7}, and nothing that follows a merge was done here: GitHub did not say who merged this pull request, so whether the merge button's run does it is not known.$(run_log)"
        echo "pull request #$pr: $body" >&2
        retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and pull request #$pr could not be told so" >&2
        status=1
        return 1
      fi
      if [ "$(jq -r .state <<<"$merged")" = MERGED ] && [ "$(jq -r '.mergedBy.login // "app/github-actions"' <<<"$merged")" != app/github-actions ]; then
        echo "a person merged pull request #$pr with GitHub's merge button, and \`ship.sh --merged\` does what follows a merge for it"
        return 1
      fi
    fi
  fi
  echo "$commit" > "$state/$pr.commit"
  echo "$called" > "$state/$pr.called"
}


# send_back <pr> <head> <result>: it waits to merge no longer, and gets the fix round for a conflict (decisions M455d).
send_back() {
  local pr="$1" head="$2" why detail rounds before author person="" body
  if [ "$3" = conflict ]; then
    why="it does not fit \`$base\` with the pull requests merged before it"
  else
    why="its checks failed when it was tested with \`$base\` and the pull requests merged before it"
  fi
  detail=$(jq -r --argjson pr "$pr" '.pulls[] | select(.number == $pr) | .detail // ""' "$result")
  # The test passed it, and its merge was refused (decisions M485a).
  [ -n "$detail" ] || detail=$(of "$pr" detail)
  # A person's own gets no round, nor one with none left, as for any conflict (decisions A124c, A124g).
  # `app/claude` is how gh writes the app that opens the factory's pull requests.
  if ! rounds=$(retry "$script_dir/fix-rounds.sh" "$pr") || ! before=$(retry "$script_dir/fix-rounds.sh" "$pr" conflict "$head") \
    || ! author=$(retry gh pr view "$pr" --json author --jq .author.login); then
    test_again "$((try + 1))" "pull request #$pr was left out, because $why, and its fix rounds and who opened it could not be read from GitHub" "$pr:$head"
    return
  elif [ "$author" != app/claude ]; then
    person="Merge \`$base\` into this pull request's branch and fix what is shown below: the new commit is checked and merged like any other.

Not merged: $why. It gets no fix round, because the factory did not open it."
  elif [ "$rounds" -ge 3 ]; then person="it has used its three fix rounds"
  elif [ "$before" -gt 0 ]; then person="a fix round for a conflict already ran at ${head:0:7}"
  fi
  if [ -z "$person" ]; then
    body="Not merged: $why. Its engineer merges \`$base\` into the branch and fixes what is shown below in a fix round, and the new commit is checked and merged like any other."
  elif [ "$author" != app/claude ]; then
    body="$person"
  else
    body="Submit a \"Request changes\" review saying what to change, or close this pull request: a review starts a fix round that is not one of the three, and its engineer is given what is shown below.

Not merged: $why. It gets no fix round, because $person."
  fi
  body+=$'\n\n```\n'"$detail"$'\n```'
  echo "pull request #$pr: not merged: $why"
  # The comment is posted before the fix round starts, because the round reads it (collect-failures.sh).
  if ! retry "$script_dir/merge-queue.sh" remove "$pr" "$head" "$body"; then
    test_again "$((try + 1))" "pull request #$pr was left out, because $why, and could not be told so" "$pr:$head"
  elif [ -n "$person" ]; then
    retry gh pr edit "$pr" --add-label needs-human >/dev/null || { echo "needs-human could not be added to pull request #$pr" >&2; status=1; }
  # Asked again when it fails: a second round for one commit is refused when it begins (decisions M455k, A124g).
  elif ! retry "$script_dir/start-fix-round.sh" "$pr"; then
    fix_page=$("$script_dir/workflow-page.sh" fix.yml pr="$pr")
    retry gh pr comment "$pr" --body "Start the fix round on $fix_page. The fix round the comment before this one names could not be started.$(run_log)" >/dev/null \
      || echo "and pull request #$pr could not be told that its fix round was not started" >&2
    retry gh pr edit "$pr" --add-label needs-human >/dev/null || echo "and needs-human could not be added to pull request #$pr" >&2
    status=1
  fi
}

# From here they are merged: every step is tried, and what did not finish is kept for one comment each (decisions M14, M30).
unfinished() { echo "- $2" >> "$state/$1.incomplete"; echo "did not finish for pull request #$1: $2" >&2; }
of() { cat "$state/$1.$2" 2>/dev/null || true; }

if [ "$already_merged" = yes ]; then
  retry "$script_dir/linked-issue.sh" "$pr" > "$state/$pr.issue" \
    || not_finished "GitHub did not return this pull request's description, so the ticket it closes is not known"
  merged=$(retry gh pr view "$pr" --json state,mergedBy,mergeCommit) \
    || not_finished "GitHub did not say who merged this pull request, so whether what follows a merge was already done is not known"
  if [ "$(jq -r .state <<<"$merged")" != MERGED ]; then echo "pull request #$pr is not merged; nothing to do"; exit 0; fi
  # `app/github-actions` is how gh writes the workflows' own token, which this script merges with (decisions M435b).
  if [ "$(jq -r '.mergedBy.login // ""' <<<"$merged")" = app/github-actions ]; then
    echo "the factory merged pull request #$pr, and did what follows a merge then; nothing to do"
    exit 0
  fi
  jq -r '.mergeCommit.oid // ""' <<<"$merged" > "$state/$pr.commit"
  echo yes > "$state/$pr.called"
  shipped="$pr "; newest_first="$pr "; last="$pr"; left_out=""
else
  if [ "$result" = --not-begun ]; then
    if ! waiting=$(retry "$script_dir/merge-queue.sh" list); then
      # Nobody can be told, so the run is started again all the same.
      if [ "$try" -lt 3 ] && start_merge_group "$((try + 1))"; then
        echo "No group was begun, and GitHub did not say which pull requests wait to merge. merge-group.yml was started to begin again, as try $((try + 1)) of 3"
        exit 0
      fi
      echo "No group was begun, GitHub did not say which pull requests wait to merge, so none was told, and merge-group.yml was not started again." >&2
      exit 1
    fi
    group=$(awk 'NF { printf "%s%s:%s", sep, $1, $2; sep = " " }' <<<"$waiting")
    [ -n "$group" ] || { echo "No group was begun, and no pull request waits to merge."; exit 0; }
    # shellcheck disable=SC2086
    test_again "$((try + 1))" "the group it waits in could not be begun" $group
    # The begin job failed, and has started the retro of this run: failing here would start a second.
    exit 0
  fi
  [ -s "$result" ] || none_merged "the test of its group with \`$base\` ended with no result"
  tested=$(jq -r '.main // empty' "$result") && [ -n "$tested" ] \
    || none_merged "the result of the test of its group with \`$base\` could not be read"
  not_tested=$(jq -r '.not_tested // empty' "$result")
  [ -z "$not_tested" ] || none_merged "$not_tested"

  # Each answer is read on its own line, so a read GitHub never answers is never taken for "tested" (decisions H7).
  now=$(retry gh api "repos/{owner}/{repo}/commits/$base" --jq .sha) \
    || none_merged "GitHub did not say which commit \`$base\` is at, so nothing shows its group was tested with it"
  if [ "$now" != "$tested" ]; then
    # Nothing merges on a test of another main (decisions M18). No fault, so the next test is a first try.
    # shellcheck disable=SC2086
    test_again 1 "\`$base\` moved from ${tested:0:7} to ${now:0:7} while the group was tested, and nothing merges on a test of another \`$base\`" $group
    exit "$status"
  fi

  # Since the group was begun its owner may have sent one back, or its engineer pushed to it (decisions M48, M12).
  waiting=$(retry "$script_dir/merge-queue.sh" list) \
    || none_merged "GitHub did not say which pull requests still wait to merge, so whether its owner has sent it back since its group was begun is not known"
  still_waits() { grep -qxF "${1%%:*} ${1#*:}" <<<"$waiting"; }

  # The job that wrote the result ran the pull requests' code, so it names no commit the group was not begun with (decisions M25).
  found=$(jq -r '.pulls[] | "\(.number):\(.head):\(.result)"' "$result") \
    || none_merged "the result of the test of its group with \`$base\` could not be read"
  to_merge=""; left_out=""
  for pull in $found; do
    kind="${pull##*:}"; pull="${pull%:*}"
    case " $group " in
      *" $pull "*) ;;
      *) none_merged "the test of its group named pull request #${pull%%:*} at a commit the group does not hold" ;;
    esac
    if [ "$kind" = passed ]; then to_merge+="$pull "; else left_out+="$pull:$kind "; fi
  done
  for pull in $to_merge; do
    pr="${pull%%:*}"
    retry "$script_dir/linked-issue.sh" "$pr" > "$state/$pr.issue" \
      || none_merged "GitHub did not return the description of pull request #$pr, so the ticket it closes is not known"
  done

  # One after another with no test between: the group was tested as it merges (decisions M455a).
  shipped=""; newest_first=""; stopped=""; behind=""; fault=""
  for pull in $to_merge; do
    pr="${pull%%:*}"
    if [ -n "$stopped" ]; then
      behind+="$pull "
    elif ! still_waits "$pull"; then
      echo "pull request #$pr no longer waits to merge at the commit that was tested: it is not merged"
      stopped="$pr"
    elif merge "$pr" "${pull#*:}"; then
      shipped+="$pr "; newest_first="$pr $newest_first"; last="$pr"
    else
      stopped="$pr"
      pushed=$(of "$pr" head)
      if [ -n "$fault" ] && [ -n "$pushed" ]; then
        # Nothing else checks a commit a workflow pushed, so it waits to merge at that one (decisions M485d).
        "$script_dir/merge-queue.sh" add "$pr" "$pushed" || status=1
        behind="$pr:$pushed "
      elif [ -n "$fault" ]; then
        behind="$pull "
      fi
      # One whose settled merge could not be pushed goes back like one the test left out (decisions M485a).
      [ ! -e "$state/$pr.detail" ] || left_out+="$pull:conflict "
    fi
  done
  # Those behind one that did not merge were tested on top of it, so they are tested again; so is one a fault stopped.
  # shellcheck disable=SC2086
  if [ -n "$fault" ]; then test_again "$((try + 1))" "$fault" $behind
  elif [ -n "$behind" ]; then test_again 1 "pull request #$stopped, before them in the group, did not merge" $behind
  fi

  # The merges must have made the tree that was tested; a group of one its own checks tested names none (decisions M455c, M17).
  tree=$(jq -r '.tree // empty' "$result")
  if [ -n "$shipped" ] && [ -z "$stopped" ] && [ -n "$tree" ] && [ -n "$(of "$last" commit)" ]; then
    if ! holds=$(retry gh api "repos/{owner}/{repo}/commits/$(of "$last" commit)" --jq .commit.tree.sha); then
      unfinished "$last" "GitHub did not return the tree of $(of "$last" commit), so whether \`$base\` holds what was tested is not known"
    elif [ "$holds" != "$tree" ]; then
      unfinished "$last" "\`$base\` does not hold what was tested: the merges of this group made tree ${holds:0:7}, and the test passed on tree ${tree:0:7}. The checks of the next pull request test what \`$base\` now holds, and the retro of this run looks for what changed it"
    fi
  fi

  for pull in $left_out; do
    kind="${pull##*:}"; pull="${pull%:*}"
    ! still_waits "$pull" || send_back "${pull%%:*}" "${pull#*:}" "$kind"
  done
fi

[ -n "$shipped" ] || exit "$status"

closed=""
for pr in $shipped; do
  issue=$(of "$pr" issue)
  retry gh pr edit "$pr" --remove-label needs-human >/dev/null \
    || unfinished "$pr" "the \`needs-human\` label could not be taken off this pull request"
  [ -n "$issue" ] || continue
  retry gh issue edit "$issue" --remove-label in-progress --remove-label needs-human >/dev/null \
    || unfinished "$pr" "the \`in-progress\` and \`needs-human\` labels could not be taken off ticket #$issue"
  # Closed here, before the queue is read, not in GitHub's own time after the merge (decisions T359b).
  retry gh issue close "$issue" >/dev/null || unfinished "$pr" "ticket #$issue could not be closed"
  closed+="--closed $issue "
  # Closing the ticket here starts no workflow, so the idea it is the last open slice of is closed here (decisions T569b).
  retry "$script_dir/close-idea.sh" "$issue" || unfinished "$pr" "whether ticket #$issue was the last open slice of an idea is not known, so no idea was closed; close the idea by hand if every ticket under its \"Sub-issues\" has closed"
done

# A merge shows that jobs start again, and the sweep still runs again what this leaves (decisions H386a, H386b).
"$script_dir/rerun-refused.sh" \
  || echo "The jobs GitHub refused for billing were not all run again (\`rerun-refused.sh\` failed); \`flag-idle.yml\` runs them again at its next look." >&2

# Before start-waiting.sh, which starts the ticket this labels `ready`; a failure fails no merge (decisions H476c).
"$script_dir/cut-rule-files.sh" \
  || echo "Not every rule file over its word budget got its ticket (\`cut-rule-files.sh\` failed); the next merge files it." >&2

# The places these merges freed go to tickets that wait (decisions T269a), one that comes after a merged ticket
# included: GitHub may still list that one as open (decisions T339f).
# shellcheck disable=SC2086
"$script_dir/start-waiting.sh" $closed || unfinished "$last" "the tickets that wait with \`ready\` were not all started (\`start-waiting.sh\` failed); each is started when a place next frees"

# Started here because this already runs after every merge (decisions A185b).
"$script_dir/first-runs.sh" || unfinished "$last" "a retro was not started for every first run of a changed workflow (\`first-runs.sh\` failed)"

changed_workflows=""
for pr in $shipped; do
  issue=$(of "$pr" issue); commit=$(of "$pr" commit)
  # A retro only after two fix rounds or an owner's round; a conflict's are in neither count (decisions A430a, A48d, A124b).
  if rounds=$(retry "$script_dir/fix-rounds.sh" "$pr") && owner_rounds=$(retry "$script_dir/fix-rounds.sh" "$pr" owner); then
    if [ "$rounds" -ge 2 ] || [ "$owner_rounds" -gt 0 ]; then
      # Kept, so a pull request also over its budget gets no second retro (decisions M612).
      : > "$state/$pr.retro"
      gh workflow run retro.yml -f pr="$pr" || unfinished "$pr" "the retro could not be started"
    fi
  else
    unfinished "$pr" "the fix rounds could not be counted, so no retro was started"
  fi

  # Before the wait for production, as it does not depend on the deploy (decisions M14).
  "$script_dir/apply-setup.sh" "$pr" ${commit:+"$commit"} || unfinished "$pr" "the changes to setup scripts, if there were any, could not be applied (\`apply-setup.sh\` failed)"

  # A merged revert reopens the ticket it took back (decisions T19a).
  [ -z "$issue" ] || "$script_dir/revert.sh" shipped "$issue" "$pr" \
    || unfinished "$pr" "if this pull request took a ticket back, that ticket was not reopened as \`reverted\` (\`revert.sh\` failed)"

  # The merge button has started the installer already (decisions W14).
  if [ "$already_merged" = yes ]; then
    :
  elif files=$(retry gh api "repos/{owner}/{repo}/pulls/$pr/files" --paginate --jq '.[].filename'); then
    ! grep -q '^factory/workflows/' <<<"$files" || changed_workflows+="$pr "
  else
    unfinished "$pr" "the changed files could not be listed, so a changed workflow was not installed"
  fi
done

# Only started here: its workflow checks what it may install and holds the one credential that can write a workflow.
# One run installs the first merge and starts the next, so they install in the order they merged (decisions W469b).
if [ -n "$changed_workflows" ]; then
  read -r first later <<<"$changed_workflows"
  gh workflow run install-workflows.yml -f pr="$first" ${later:+-f then="$later"} || for pr in $changed_workflows; do
    unfinished "$pr" "the workflow installer could not be started, so the changed workflows are not installed"
  done
fi

# A conflict stops a merge and nothing else sends it back to its engineer, so a fix round is started (decisions M21).
fix_conflicting() {
  local list number state head rounds before tries=0 result=0 waiting=""
  # GitHub answers UNKNOWN for `mergeable` until some time after the merge, so it is asked a few times.
  while :; do
    list=$(gh pr list --state open --base "$base" --limit 100 --json number,mergeable,author,headRefOid \
      --jq '.[] | select(.author.login == "app/claude") | "\(.number) \(.mergeable) \(.headRefOid)"') || return 1
    tries=$((tries + 1))
    if ! grep -q ' UNKNOWN ' <<<"$list" || [ "$tries" -ge 6 ]; then break; fi
    sleep 5
  done
  if grep -q ' CONFLICTING ' <<<"$list"; then
    waiting=$(retry "$script_dir/merge-queue.sh" list) || return 1
  fi
  while read -r number state head; do
    # One this group left out was sent back above.
    case " $left_out" in *" $number:"*) continue ;; esac
    case "$state" in
      CONFLICTING)
        # The test of its group settles a conflict in a list, and sends any other back (decisions M485c).
        if grep -qxF "$number $head" <<<"$waiting"; then
          echo "pull request #$number conflicts with $base as GitHub merges it, and waits to merge: the test of its group says whether it fits; no fix round is started"
          continue
        fi
        # Three rounds used (decisions A5), or a conflict round run at this head (A124g): a start would only be refused.
        if ! rounds=$("$script_dir/fix-rounds.sh" "$number") || ! before=$("$script_dir/fix-rounds.sh" "$number" conflict "$head"); then
          result=1
        elif [ "$rounds" -ge 3 ]; then
          echo "pull request #$number conflicts with $base, but has used its three fix rounds and waits for a person; no fix round is started"
        elif [ "$before" -gt 0 ]; then
          echo "pull request #$number conflicts with $base, but a fix round for a conflict already ran for its head ${head:0:7} and it waits for a person; no fix round is started"
        else
          "$script_dir/start-fix-round.sh" "$number" || result=1
        fi ;;
      UNKNOWN) echo "GitHub has not said whether pull request #$number conflicts with $base; the test of its group says so before it merges" ;;
    esac
  done <<<"$list"
  return "$result"
}
fix_conflicting || unfinished "$last" "a fix round was not started for every open pull request these merges left in conflict"

# A merge may be what a pull request labelled `waits-for-main` waited for, or one its owner sent back (decisions A368a, A396a).
"$script_dir/start-retests.sh" || unfinished "$last" "not every pull request labelled \`waits-for-main\`, or sent back by its owner, got its fix round (\`start-retests.sh\` failed); the next merge starts it"

# Production comes to run the last commit of the group that changes app code, or a later one that holds it:
# a commit that changes none is not waited for, and one Vercel skipped is passed over (decisions M597, M455g, M33).
live=""; skipped=""; unchanged=""; later=""; code=0
if [ -n "${PRODUCTION_URL:-}" ]; then
  for pr in $newest_first; do
    commit=$(of "$pr" commit)
    [ -n "$commit" ] || continue
    # needs-e2e.sh says changed when unsure.
    if [ "$("$script_dir/needs-e2e.sh" "$pr" 2>/dev/null | sed -n 1p)" = run=false ]; then
      unchanged+="$pr "
    else
      code=0
      # shellcheck disable=SC2086 # $later is a list of commits, one argument each.
      message=$("$script_dir/wait-for-deploy.sh" "$PRODUCTION_URL" "$commit" $later) || code=$?
      [ -z "$message" ] || echo "$message"
      if [ "$code" -eq 0 ]; then live="${message##* }"; break; fi
      if [ "$code" -ne 2 ]; then live="$commit"; break; fi
      skipped+="$pr "
    fi
    later+="$commit "
  done
else
  echo "merged; no PRODUCTION_URL is set, so the deploy was not confirmed"
fi

for pr in $shipped; do
  issue=$(of "$pr" issue); commit=$(of "$pr" commit)
  if [ -z "$commit" ]; then
    unfinished "$pr" "GitHub did not return the merge commit, so the deploy was not checked"
  elif [ -z "${PRODUCTION_URL:-}" ]; then
    :
  elif [[ " $unchanged" == *" $pr "* ]]; then
    retry gh pr comment "$pr" --body "Merged as ${commit:0:7}. Nothing to deploy: this pull request changes no app code, so production at $PRODUCTION_URL serves the app it did before." >/dev/null \
      || unfinished "$pr" "this pull request changes no app code, so there was nothing to deploy, and the comment saying so could not be posted"
  elif [[ " $skipped" == *" $pr "* ]]; then
    unfinished "$pr" "the deploy check: Vercel skipped the deployment of this commit, so production at $PRODUCTION_URL will never report it and the ticket is not marked \`deployed\`"
  elif [ "$code" -eq 0 ]; then
    holds=""
    [ "$commit" = "$live" ] || holds=", which holds this pull request's commit ${commit:0:7}"
    retry gh pr comment "$pr" --body "Deployed: production at $PRODUCTION_URL is running ${live:0:7}$holds." >/dev/null \
      || unfinished "$pr" "production at $PRODUCTION_URL is running ${live:0:7}, and the comment saying so could not be posted"
    [ -z "$issue" ] || retry gh issue edit "$issue" --add-label deployed >/dev/null \
      || unfinished "$pr" "production is running ${live:0:7}, and ticket #$issue could not be labelled \`deployed\`"
  else
    unfinished "$pr" "the deploy check: production at $PRODUCTION_URL did not report ${live:0:7} within 10 minutes. Check the Vercel deployment"
  fi

  # Decisions M221a, M221b, M246.
  if [ -n "$issue" ]; then
    if figures=$("$script_dir/ticket-cost.sh" --json "$pr"); then
      "$script_dir/measures.sh" record <<<"$figures" || echo "the measures of ticket #$issue were not recorded" >&2
      cost=$("$script_dir/ticket-cost.sh" --comment <<<"$figures") && retry gh issue comment "$issue" --body "$cost" >/dev/null \
        || echo "what ticket #$issue cost could not be posted on it" >&2
      # After the comment, which tells the retro what the pull request went over (decisions M612).
      over=$("$script_dir/ticket-cost.sh" --over-budget <<<"$figures") || over=""
      if [ -n "$over" ] && [ ! -e "$state/$pr.retro" ]; then
        gh workflow run retro.yml -f pr="$pr" || unfinished "$pr" "the retro of a pull request over its budget could not be started"
      fi
    else
      echo "what ticket #$issue cost could not be worked out, so it was not posted on it and its measures were not recorded" >&2
    fi
  fi

  # GitHub may still show as open a pull request an earlier call merged: it is left open for a person (decisions M29).
  if [ "$(of "$pr" called)" = no ]; then
    shown=$(retry gh pr view "$pr" --json state --jq .state) || shown=""
    if [ "$shown" != MERGED ]; then
      unfinished "$pr" "GitHub does not show this pull request as merged, though \`$base\` holds its commit. It was not merged a second time, which would add an empty commit"
      echo "Close this pull request and its ticket by hand: the factory leaves both open." > "$state/$pr.todo"
    fi
  fi

  [ -s "$state/$pr.incomplete" ] || continue
  status=1
  todo=$(of "$pr" todo)
  if [ -n "$todo" ]; then
    todo+=$'\n\n'
    retry gh pr edit "$pr" --add-label needs-human >/dev/null || true
  fi
  body=$(printf '%sMerged as %s, but not everything that follows a merge finished:\n\n%s\n%s' "$todo" "${commit:0:7}" "$(of "$pr" incomplete)" "$(run_log)")
  retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and pull request #$pr could not be told so" >&2
done
exit "$status"
