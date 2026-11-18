#!/usr/bin/env bash
# Tests for factory/scripts/unfinished-work.sh: the branch an earlier build left with no pull request or only a draft.
. "$(dirname "$0")/helpers.sh"

# $T/heads holds the branches, one per line, and $T/pulls the pull requests; $T/fail holds the command that should fail.
github_holds() {
  printf '%s\n' "$@" > "$T/heads"
  echo '[]' > "$T/pulls"
  : > "$T/fail"
  stub git '
    ! grep -qx git "$T/fail" || { echo "git: could not connect" >&2; exit 128; }
    case "$*" in
      "ls-remote --heads origin") while read -r name; do printf "%s\trefs/heads/%s\n" 5555555555555555555555555555555555555555 "$name"; done < "$T/heads" ;;
      *) echo "unexpected call: git $*" >&2; exit 1 ;;
    esac'
  stub gh '
    ! grep -qx gh "$T/fail" || { echo "gh: could not connect" >&2; exit 1; }
    case "$*" in
      "pr list --state all --head "*" --json state,isDraft "*) json "$(cat "$T/pulls")" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "prints the branch an earlier build left with no pull request"
github_holds main feat/12-export-forecast-csv
run "$scripts/unfinished-work.sh" 12
expect_status 0
[ "$out" = feat/12-export-forecast-csv ] || fail "expected exactly: feat/12-export-forecast-csv"
expect_call "gh pr list --state all --head feat/12-export-forecast-csv"

scenario "prints nothing when no branch is named for the issue: #112 and #1 are not #12"
github_holds main fix/112-other-ticket feat/1-first-ticket chore/tidy-12-things sessions
run "$scripts/unfinished-work.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
expect_no_call "gh "

scenario "prints the branch whose pull request is still an open draft: the build that opened it never finished"
github_holds main feat/12-export-forecast-csv
echo '[{"state":"OPEN","isDraft":true}]' > "$T/pulls"
run "$scripts/unfinished-work.sh" 12
expect_status 0
[ "$out" = feat/12-export-forecast-csv ] || fail "expected exactly: feat/12-export-forecast-csv"

scenario "prints nothing when the branch's pull request is ready for review: that work was handed over"
github_holds main feat/12-export-forecast-csv
echo '[{"state":"OPEN","isDraft":false}]' > "$T/pulls"
run "$scripts/unfinished-work.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "prints nothing when the branch's pull request was closed, draft or not: what became of it was decided there"
github_holds main feat/12-export-forecast-csv
echo '[{"state":"CLOSED","isDraft":true},{"state":"OPEN","isDraft":true}]' > "$T/pulls"
run "$scripts/unfinished-work.sh" 12
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"

scenario "stops when the branches cannot be listed: that is not 'no earlier work'"
github_holds main feat/12-export-forecast-csv
echo git > "$T/fail"
run "$scripts/unfinished-work.sh" 12
expect_status 1
expect_output "Could not list the branches on GitHub"

scenario "stops when the pull requests cannot be read: that is not 'no pull request'"
github_holds main feat/12-export-forecast-csv
echo gh > "$T/fail"
run "$scripts/unfinished-work.sh" 12
expect_status 1
expect_output "Could not read the pull requests for feat/12-export-forecast-csv"
expect_no_output "feat/12-export-forecast-csv"$'\n'
