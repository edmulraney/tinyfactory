#!/usr/bin/env bash
# Tests for quality.sh: fix rounds, who failed each, and rework, read from GitHub and git (decisions H573a).
. "$(dirname "$0")/helpers.sh"

marker='<!-- factory:fix-round -->'

# github: a repo that stands for the one on GitHub, in $T/origin, and a gh that answers from $T/pulls and $T/comments.
github() {
  git init -q -b main "$T/origin"
  git -C "$T/origin" commit -q --allow-empty -m "chore: start"
  mkdir "$T/comments"
  : > "$T/pulls"
  merges=0
  stub gh 'case "$*" in
    "api graphql --paginate -F owner={owner} -F name={repo} -f query="*)
      [ ! -e "$T/no-pulls" ] || { echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; }
      json "{\"data\":{\"repository\":{\"pullRequests\":{\"nodes\":$(jq -sc . "$T/pulls")}}}}" "$@" ;;
    "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*)
      n=${2#*/issues/}; n=${n%/comments*}
      [ ! -e "$T/no-comments" ] || { echo "gh: HTTP 502: Bad Gateway" >&2; exit 1; }
      [ -e "$T/comments/$n" ] || echo "[]" > "$T/comments/$n"
      json "$(cat "$T/comments/$n")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
write() {
  local file="$T/origin/$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}
# merge <pr> [label]...: squash-merges what the repo's folder holds as that pull request, the next to merge. Its
# ticket carries the labels; with `none` it closes no ticket.
merge() {
  local pr="$1" tickets
  shift
  git -C "$T/origin" add -A && git -C "$T/origin" commit -q --allow-empty -m "feat: change $pr (#$pr)"
  merges=$((merges + 1))
  if [ "${1:-}" = none ]; then tickets='[]'
  else tickets=$(printf '%s\n' "$@" | jq -Rsc '[{labels: {nodes: (split("\n") | map(select(. != "") | {name: .}))}}]'); fi
  jq -nc --argjson number "$pr" --arg at "$(printf '2026-11-01T00:00:%02dZ' "$merges")" \
    --arg oid "$(git -C "$T/origin" rev-parse HEAD)" --argjson tickets "$tickets" \
    '{number: $number, title: "feat: change \($number)", mergedAt: $at, mergeCommit: {oid: $oid}, closingIssuesReferences: {nodes: $tickets}}' >> "$T/pulls"
}
# comments <pr> <author> <text> [<author> <text>]...: the comments of the pull request, as GitHub's REST API lists them.
comments() {
  local pr="$1" all=""
  shift
  while [ $# -gt 0 ]; do
    all+=$(jq -nc --arg login "$1" --arg body "$2" '{user: {login: $login}, body: $body}')$'\n'
    shift 2
  done
  jq -sc . <<<"$all" > "$T/comments/$pr"
}
report() {
  rm -rf "$T/work/clone"
  git clone -q "$@" "file://$T/origin" "$T/work/clone" 2>/dev/null
  cd "$T/work/clone" || exit 1
  run "$scripts/quality.sh"
  cd "$T/work" || exit 1
}
expect_row() {
  grep -qxF "| #$1 feat: change $1 | $2 |" <<<"$out" || fail "expected the row: | #$1 feat: change $1 | $2 |"
}
ten_lines() { write "$1" one two three four five six seven eight nine ten; }

scenario "a fix round is a record of the factory's, failed by the reviewers whose FAIL came since the round before"
github
ten_lines app.ts; merge 7
comments 7 \
  'github-actions[bot]' "**Adam (architecture and taste): FAIL**"$'\n\n'"1. **Design:** a second copy of the helper." \
  'github-actions[bot]' "**Ryan (correctness): PASS**" \
  'github-actions[bot]' "Fix round 1 of 3: Esme is addressing what failed." \
  'github-actions[bot]' "${marker}Fix round 1 of 3: the engineer's session ran." \
  'github-actions[bot]' "**Ryan (correctness): FAIL**"$'\r\n\r\n'"1. **Bug:** the count is one short." \
  'github-actions[bot]' "**Adam (architecture and taste): FAIL**" \
  'github-actions[bot]' "**Adam (architecture and taste): FAIL**" \
  'github-actions[bot]' "${marker}Fix round 2 of 3: the engineer's session ran." \
  'github-actions[bot]' "**Adam (architecture and taste): PASS**" \
  'github-actions[bot]' "**Ryan (correctness): PASS**"$'\n\n'"**Adam (architecture and taste): FAIL** is quoted here." \
  'github-actions[bot]' "${marker}Fix round 3 of 3: the engineer's session ran." \
  'github-actions[bot]' "**Ryan (correctness): PASS**"
report
expect_status 0
expect_output "| Pull request | Fix rounds | Failed by | Rework |"
expect_row 7 "3 | round 1: Adam; round 2: Adam and Ryan; round 3: no reviewer | not known: no pull request has merged since"

scenario "a round or a verdict by any other account, an owner's round, and a quoted marker count as none"
github
ten_lines app.ts; merge 7
comments 7 \
  'claude[bot]' "**Ryan (correctness): FAIL**" \
  'repo-owner' "${marker}Fix round 1 of 3" \
  'github-actions' "${marker}Fix round 1 of 3" \
  'github-actions[bot]' "<!-- factory:owner-round -->The owner's fix round: the engineer's session ran." \
  'github-actions[bot]' "<!-- factory:conflict-round 5555555 -->The fix round for a conflict: the engineer's session ran." \
  'github-actions[bot]' "**Ryan (correctness): review not finished.** Run the failed jobs again." \
  'github-actions[bot]' "**Adam (architecture and taste): PASS**"$'\n'"$marker is quoted here."
report
expect_status 0
expect_row 7 "0 |  | not known: no pull request has merged since"

scenario "rework is the share of the lines a pull request added that later pull requests changed or deleted"
github
write other.ts kept; merge 1
ten_lines app.ts; write other.ts kept added; merge 2
# One line changed and one deleted, of the eleven that pull request 2 added; a line pull request 1 added is changed too.
write app.ts one TWO three four five six seven eight ten; write other.ts KEPT added; merge 3
report
expect_status 0
expect_row 1 "0 |  | 100% of 1 added line, after 2 of the ten pull requests"
expect_row 2 "0 |  | 18% of 11 added lines, after 1 of the ten pull requests"
expect_row 3 "0 |  | not known: no pull request has merged since"

scenario "a file a later pull request renames, and a line it adds, are not rework"
github
ten_lines src/app.ts; merge 5 factory
write src/app.ts one two three four five six seven eight nine ten eleven twelve; merge 1
git -C "$T/origin" mv src/app.ts src/main.ts
write src/main.ts one two three four five six seven eight nine ten eleven twelve thirteen; merge 2
report
expect_status 0
expect_row 1 "0 |  | 0% of 2 added lines, after 1 of the ten pull requests"

scenario "the eleventh pull request to merge after one changes none of its rework, and one of a factory ticket is among the ten"
github
ten_lines app.ts; merge 1
for pr in 2 3 4 5 6 7 8 9 10; do write "file-$pr.ts" "$pr"; merge "$pr" factory; done
write app.ts ONE two three four five six seven eight nine ten; merge 11
write app.ts ONE TWO THREE four five six seven eight nine ten; merge 12
report
expect_status 0
expect_row 1 "0 |  | 10% of 10 added lines"
expect_row 11 "0 |  | 0% of 1 added line, after 1 of the ten pull requests"

scenario "only the pull request of a product ticket gets a row, in the order they merged"
github
write a.ts a; merge 9
write b.ts b; merge 4 factory
write c.ts c; merge 5 research
write d.ts d; merge 6 none
write e.ts e; merge 3 bug
report
expect_status 0
[ "$(grep -c '^| #' <<<"$out")" = 2 ] || fail "expected two rows"
[ "$(grep '^| #' <<<"$out" | cut -d' ' -f2 | tr '\n' ' ')" = "#9 #3 " ] || fail "expected the row of #9 before that of #3"

scenario "a binary file holds no added line, and a pull request that only deletes added none"
github
ten_lines app.ts; printf 'a\0b\n' > "$T/origin/logo.png"; merge 1
printf 'a\0b\nc\0d\n' > "$T/origin/logo.png"; merge 2
rm "$T/origin/logo.png"; merge 3
report
expect_status 0
expect_row 1 "0 |  | 0% of 10 added lines, after 2 of the ten pull requests"
expect_row 2 "0 |  | it added no line"
expect_row 3 "0 |  | it added no line"

scenario "a clone that holds only the last commit of main fetches the rest"
github
ten_lines app.ts; merge 1
write app.ts one two three four five; merge 2
report --depth 1
expect_status 0
expect_row 1 "0 |  | 50% of 10 added lines, after 1 of the ten pull requests"

scenario "a title cannot add a column"
github
ten_lines app.ts; merge 1
jq -c '.title = "feat: a | b"' "$T/pulls" > "$T/pulls.new" && mv "$T/pulls.new" "$T/pulls"
report
expect_status 0
expect_output "| #1 feat: a   b | 0 |"

scenario "says so when no pull request has merged"
github
report
expect_status 0
expect_output "No pull request has merged."

scenario "stops with a message when the pull requests cannot be listed: that is not a repo with none merged"
github
ten_lines app.ts; merge 1
touch "$T/no-pulls"
report
expect_status 1
expect_output "Could not list the merged pull requests from GitHub"
expect_no_output "| Pull request"
expect_no_output "No pull request has merged."

scenario "stops with a message when a pull request's comments cannot be read: that is not a pull request with no fix round"
github
ten_lines app.ts; merge 1
touch "$T/no-comments"
report
expect_status 1
expect_output "Could not read the comments of pull request #1 from GitHub, so its fix rounds are not known."
expect_no_output "| #1"

scenario "stops with a message when the history of main cannot be fetched"
github
ten_lines app.ts; merge 1
git clone -q "file://$T/origin" "$T/work/clone"
cd "$T/work/clone" || exit 1
git remote set-url origin "file://$T/gone"
run "$scripts/quality.sh"
expect_status 1
expect_output "Could not fetch the history of main, so no pull request's rework is known."
expect_no_output "| Pull request"

scenario "stops with a message when main does not hold the commit a pull request left"
github
ten_lines app.ts; merge 1
jq -c '.mergeCommit.oid = "1234567890123456789012345678901234567890"' "$T/pulls" > "$T/pulls.new" && mv "$T/pulls.new" "$T/pulls"
report
expect_status 1
expect_output "The history of main does not hold the commit a merged pull request left"
expect_no_output "| Pull request"
