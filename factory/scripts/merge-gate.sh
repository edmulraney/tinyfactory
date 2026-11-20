#!/usr/bin/env bash
# The merge gate: a pull request both reviews passed waits to merge, or for the owner when only they may decide it.
# Usage: merge-gate.sh <pr-number> <head-sha> <owner-login>
#        Needs GH_TOKEN (pull-requests, issues and actions: write; contents: read) and, when set, BOARD_TOKEN, by which
#        start-waiting.sh reads the order of the board. Run from the root of main's checkout.
set -euo pipefail

pr="$1"; head="$2"; owner="$3"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

# What the pull request changes is read from git, as the installer reads it (decisions M373).
# GitHub keeps the pull request's last commit at this ref.
# A run that a ci.yml from before M373 started checks out main's last commit alone, so the rest is fetched too.
whole=()
[ "$(git rev-parse --is-shallow-repository)" = false ] || whole=(--unshallow)
retry git fetch --quiet "${whole[@]}" origin "refs/pull/$pr/head" \
  || not_merged "GitHub did not return this pull request's commits, so what it changes is not known"
# Read on a line of its own (decisions H7).
base=$(git merge-base HEAD "$head") && files=$(git diff --name-only "$base" "$head") \
  || not_merged "Git could not list the files this pull request changes, so whether it needs a person is not known"
# Any end of protected-paths.sh but a clean "none" is a change to the factory's files (decisions M2).
if protected=$("$script_dir/protected-paths.sh" <<<"$files"); then touches=false; else touches=true; fi
# The installer that runs is the installed copy, and an older one refuses what nobody approved (decisions W272c).
behind=false
if grep -q '^factory/workflows/' <<<"$files" \
    && ! cmp -s factory/workflows/install-workflows.yml .github/workflows/install-workflows.yml; then
  behind=true
fi

# Read on a line of its own (decisions H7).
reviews=$(retry gh pr view "$pr" --json reviews) \
  || not_merged "GitHub did not return this pull request's reviews, so whether the owner approved it or sent it back is not known"
# The commit the owner's latest review approved, if it approves. The gate runs again for a commit already approved (decisions M23).
approved=$(jq -r --arg owner "$owner" \
  '[.reviews[] | select(.author.login == $owner)] | last | select(.state == "APPROVED") | .commit.oid // ""' <<<"$reviews")
# An approval stands over commits that only merge main (decisions M456a), unless an older installer runs (M456b).
if [ -n "$approved" ] && [ "$approved" != "$head" ] && [ "$behind" = false ]; then
  status=0
  why=$("$script_dir/only-merged-main.sh" "$approved" "$head" HEAD 2>&1) || status=$?
  case "$status" in
    0) approved="$head" ;;
    1) echo "The owner approved ${approved:0:7} and is asked to approve ${head:0:7}: $why." ;;
    *) echo "$why" >&2
       not_merged "Git could not compare this pull request's change with the one the owner approved at ${approved:0:7}, so whether that approval still stands is not known" ;;
  esac
fi
if [ "$approved" = "$head" ]; then
  exec "$script_dir/merge-queue.sh" add "$pr" "$head"
fi
# A review that only comments is no verdict, and dismissing the review takes the request back (decisions M48).
sent_back=$(jq -r --arg owner "$owner" \
  '[.reviews[] | select(.author.login == $owner and .state != "COMMENTED" and .state != "PENDING")] | last | .state == "CHANGES_REQUESTED"' <<<"$reviews")

issue=$(retry "$script_dir/linked-issue.sh" "$pr") \
  || not_merged "GitHub did not return this pull request's description, so the ticket it closes is not known"
# undoes_button_merge: whether the pull request only puts back what main held before a merge the owner made with
# GitHub's merge button, which needs no approval (decisions M439f). The installer makes the same test.
undoes_button_merge() {
  local ticket taken merge commit paths path
  [ -n "$issue" ] || return 1
  ticket=$(retry gh issue view "$issue" --json title,author) \
    || not_merged "GitHub did not return ticket #$issue, so whether this pull request takes back a merge made with the merge button is not known"
  # Only a workflow files a ticket as `app/github-actions`, and revert.sh titles it so (decisions M439d).
  [ "$(jq -r .author.login <<<"$ticket")" = app/github-actions ] || return 1
  [[ "$(jq -r .title <<<"$ticket")" =~ ^"Take back the button merge of pull request #"([0-9]+)$ ]] || return 1
  taken="${BASH_REMATCH[1]}"
  merge=$(retry gh pr view "$taken" --json mergedBy,mergeCommit) \
    || not_merged "GitHub did not say who merged pull request #$taken, so whether this pull request takes back a merge made with the merge button is not known"
  [ "$(jq -r '.mergedBy.login // ""' <<<"$merge")" = "$owner" ] || return 1
  commit=$(jq -r '.mergeCommit.oid // ""' <<<"$merge")
  [ -n "$commit" ] || return 1
  paths=$(git -c core.quotePath=false diff --no-renames --name-only "$base" "$head" \
    && git -c core.quotePath=false diff --no-renames --name-only "$commit^" "$commit") && [ -n "$paths" ] || return 1
  # Nothing has changed a file since that merge, and each goes back to what main held before it.
  while IFS= read -r path; do
    [ "$(git ls-tree "$base" -- "$path")" = "$(git ls-tree "$commit" -- "$path")" ] \
      && [ "$(git ls-tree "$head" -- "$path")" = "$(git ls-tree "$commit^" -- "$path")" ] || return 1
  done <<<"$paths"
}
# What holds it, and the lines that show it.
hold=""; shown=""
if [ "$touches" = true ]; then
  factory=false
  [ -z "$issue" ] || factory=$(retry gh issue view "$issue" --json labels --jq '[.labels[].name] | index("factory") != null') \
    || not_merged "GitHub did not return the labels of ticket #$issue, so whether it is a \`factory\` ticket, which may change the factory's files, is not known"
  # Decisions M272c.
  [ "$factory" = true ] || { hold="changes files only a \`factory\` ticket may change, and it closes none"; shown="$protected"; }
fi
if [ -z "$hold" ]; then
  # Asked of every pull request: the product's bar is held on any type of ticket (decisions M272e).
  diff=$(git diff "$base" "$head") \
    || not_merged "Git could not read this pull request's diff, so whether it changes what only the owner may decide is not known"
  # Any end of owner-decides.sh but a clean "nothing" holds the pull request (decisions M272a).
  if ! shown=$("$script_dir/owner-decides.sh" <<<"$diff" 2>&1) && ! undoes_button_merge; then
    hold="changes what only the repo owner may decide"
  elif [ "$behind" = true ]; then
    hold="changes a workflow while the installer that runs is not yet the one \`main\` holds, and that one may refuse a change nobody approved"
    shown=$(grep '^factory/workflows/' <<<"$files")
  fi
fi
if [ -z "$hold" ] && [ "$sent_back" != true ]; then
  exec "$script_dir/merge-queue.sh" add "$pr" "$head"
fi

# Each reviewer's latest verdict counts, and its list is the hidden last line of it (decisions A55b, A55c).
# A verdict from before the install holds `unverified` claims in three parts (decisions A224b).
# A verdict is the factory's own comment, and the REST list names its account in full (decisions U563l).
verdicts=$(retry gh api "repos/{owner}/{repo}/issues/$pr/comments?per_page=100" --paginate \
    --jq '.[] | select(.user.login == "github-actions[bot]") | {body: (.body // "")}') \
  || not_merged "GitHub did not return this pull request's comments, so the reviewers' assumptions cannot be shown to the owner"
assumptions=$(jq -rs '
  reduce (.[].body | select(test("^\\*\\*[^*\n]+: (PASS|FAIL)\\*\\*"))) as $body ({};
    .[$body | capture("^\\*\\*(?<who>[^*\n]+): ").who] =
      [$body | [split("\n")[] | select(. != "")] | last
       | capture("^<!-- factory:(assumptions|unverified) (?<list>.*) -->$") | .list | fromjson | .[]])
  | to_entries[] | .key as $reviewer | .value[]
  | "- **\($reviewer):** Assumes: \(.assumes // .claim)\n  If wrong: \(.if_wrong // .risk)"' <<<"$verdicts") \
  || not_merged "The reviewers' assumptions could not be read from their verdicts, so the owner cannot be shown them"
[ -z "$assumptions" ] || assumptions="**Before you approve, what the reviewers could not check:**"$'\n\n'"$assumptions"$'\n\n'
# The first line says what a person must do (decisions A371a).
if [ -n "$hold" ]; then
  body=$(printf 'Approve this pull request: it merges as soon as the repo owner approves.\n\n%sBoth reviews passed, but this pull request %s:\n\n```\n%s\n```\n' "$assumptions" "$hold" "$shown")
else
  body="Approve this pull request, or submit a \"Request changes\" review: an approval merges it, and a review sends it back to its engineer.

${assumptions}Both reviews passed, but the repo owner asked for changes to this pull request, so only they can say it is now right."
fi
retry gh pr comment "$pr" --body "$body" >/dev/null
retry gh pr edit "$pr" --add-label needs-human >/dev/null
# The build is over; what is left is a person's decision, so the ticket is no longer in progress.
[ -z "$issue" ] || retry gh issue edit "$issue" --remove-label in-progress --add-label needs-human >/dev/null
# It holds no place among the tickets being built now, so a ticket that waits takes it (decisions T361c).
"$script_dir/start-waiting.sh" || {
  echo "Pull request #$pr waits for the owner, and the tickets that wait with ready were not all started; each is started when a place next frees." >&2
  exit 1
}
