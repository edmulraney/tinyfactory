#!/usr/bin/env bash
# Tests a group of pull requests with main, as the test job of merge-group.yml, and writes which may merge.
# Usage: test-group.sh <result-file> <pr>:<head>...   (from a checkout of main with its history; needs no token)
#        Writes JSON: `main`, the commit tested with; `tree`, the git tree that passed; and `pulls`, each with its
#        `number`, `head` and `result`: `passed`, or `conflict` or `failed` with a `detail` for its engineer.
#        A pull request that fails is a result and exits 0; exit 1 says that the test itself could not be made.
set -euo pipefail

usage="Usage: test-group.sh <result-file> <pr>:<head>..."
result="${1:?$usage}"; shift
[ $# -gt 0 ] || { echo "$usage" >&2; exit 1; }
# Run from a copy outside the checkout, which the pull requests change (merge-group.yml).
script_dir="$(cd "$(dirname "$0")" && pwd)"

die() { echo "$1" >&2; exit 1; }
git_as() { git -c user.name=merge-group -c user.email=merge-group@users.noreply.github.com "$@"; }
# What a check or a refused merge left in the checkout must not reach the next test.
restore() { git reset --quiet --hard "$1" && git clean --quiet -fd || die "The checkout could not be put back to ${1:0:7}, so the group was not tested."; }

main=$(git rev-parse HEAD)
log=$(mktemp)
trap 'rm -f "$log"' EXIT

group=""
for pull in "$@"; do
  pr="${pull%%:*}"; head="${pull#*:}"
  git fetch --quiet origin "refs/pull/$pr/head" \
    || die "The commits of pull request #$pr could not be fetched, so the group was not tested."
  # A push since it was added: the new commit is checked, and added when it passes.
  if [ "$(git rev-parse FETCH_HEAD)" != "$head" ]; then
    echo "pull request #$pr is no longer at ${head:0:7}: it is left to the group its new commit joins"
    continue
  fi
  group+="$pr $head"$'\n'
done

# apply <pr> <head>: adds it to the checkout as one squashed commit, as its merge would (decisions M6), or sets
# $detail and leaves the checkout as it was.
apply() {
  local settled code=0
  settled=$("$script_dir/settle-conflict.sh" HEAD "$2") || code=$?
  if [ "$code" -eq 1 ]; then
    detail="Git reports a conflict in:"$'\n'"$settled"
    return 1
  fi
  # Git's own merge stops at a conflict in a marked list, so the merge that settles it is taken as the script made it (decisions M485b).
  { [ "$code" -eq 0 ] && if [ -n "$settled" ]; then git read-tree --reset -u "$settled"; else git_as merge --squash "$2" >/dev/null 2>&1; fi; } \
    || die "Pull request #$1 could not be merged into the checkout, so the group was not tested."
  git_as commit --quiet --allow-empty --no-verify -m "pull request #$1 at $2" \
    || die "Pull request #$1 could not be committed to the checkout, so the group was not tested."
}

# check: runs what the `checks` job of ci.yml runs on one pull request, and keeps what it printed in $log.
check() {
  local needed status=0
  needed=$("$script_dir/checks-needed.sh" "$main")
  {
    pnpm install --frozen-lockfile && pnpm lint \
      && { grep -qx 'app=false' <<<"$needed" || pnpm typecheck; } \
      && { grep -qx 'factory=false' <<<"$needed" || factory/scripts/test-factory.sh "$main"; } \
      && { grep -qx 'app=false' <<<"$needed" || { pnpm -r test && pnpm build; }; }
  } > "$log" 2>&1 || status=$?
  cat "$log"
  restore HEAD
  return "$status"
}
# The end of what a failed check printed, without colour codes, as collect-failures.sh gives a failed job's, and
# cut to fit the comment that removes the pull request, as apply-setup.sh cuts what a script printed.
failure() {
  local text
  text=$(sed $'s/\033\\[[0-9;?]*[A-Za-z]//g' "$log" | tail -n 150)
  # Cut as a variable, not by `tail -c` (decisions M490).
  [ "${#text}" -le 20000 ] || text=${text: -20000}
  printf '%s\n' "$text"
}

pulls="[]"
# record <pr> <head> <result> [detail]
record() {
  pulls=$(jq -c --argjson pr "$1" --arg head "$2" --arg result "$3" --arg detail "${4:-}" \
    '. + [{number: $pr, head: $head, result: $result} + (if $detail == "" then {} else {detail: $detail} end)]' <<<"$pulls")
}

echo "::group::The whole group with main at ${main:0:7}"
applied=0
while read -r pr head; do
  [ -n "$pr" ] || continue
  detail=""
  if apply "$pr" "$head"; then
    applied=$((applied + 1))
    record "$pr" "$head" passed
  else
    echo "pull request #$pr does not fit: $detail"
    record "$pr" "$head" conflict "$detail"
  fi
done <<<"$group"
whole=pass
[ "$applied" -eq 0 ] || check || whole=fail
echo "::endgroup::"

if [ "$whole" = fail ]; then
  # A tree that failed is not tested twice: the last of a group that fails together is the one that fails.
  failed_tree=$(git rev-parse 'HEAD^{tree}')
  failed_with=$(failure)
  # Each alone, on top of those that passed (decisions M455e): one that conflicted with the one that failed may fit now.
  restore "$main"
  pulls="[]"
  while read -r pr head; do
    [ -n "$pr" ] || continue
    echo "::group::Pull request #$pr on top of those that passed"
    before=$(git rev-parse HEAD)
    detail=""
    if ! apply "$pr" "$head"; then
      echo "pull request #$pr does not fit: $detail"
      record "$pr" "$head" conflict "$detail"
    elif [ "$(git rev-parse 'HEAD^{tree}')" = "$failed_tree" ]; then
      echo "pull request #$pr makes the tree that failed"
      record "$pr" "$head" failed "$failed_with"
      restore "$before"
    elif check; then
      record "$pr" "$head" passed
    else
      record "$pr" "$head" failed "$(failure)"
      restore "$before"
    fi
    echo "::endgroup::"
  done <<<"$group"
fi

jq -n --arg main "$main" --arg tree "$(git rev-parse 'HEAD^{tree}')" --argjson pulls "$pulls" \
  '{main: $main, tree: $tree, pulls: $pulls}' > "$result"
jq -r '.pulls[] | "pull request #\(.number): \(.result)"' "$result"
