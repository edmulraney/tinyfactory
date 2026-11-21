#!/usr/bin/env bash
# Tests for factory/scripts/flag-public.sh, which tells the owner in one ticket that the repository became public.
. "$(dirname "$0")/helpers.sh"

title="Protect the repository now that it is public"
# $T/issues is what GitHub lists as open; $T/fail holds words of the call to fail.
github() {
  echo '[]' > "$T/issues"
  echo none > "$T/fail"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "issue create --title Protect the repository now that it is public --label needs-human --body "*)
        printf "%s\n" "$8" > "$T/body"; echo https://github.com/owner/repo/issues/50 ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
issue() { echo "{\"number\":$1,\"title\":\"$2\",\"user\":{\"login\":\"$3\",\"type\":\"$4\"}}"; }
expect_part() {
  sed -n "/^## $1\$/,/^## /p" "$T/body" 2>/dev/null | grep -qF -- "$2" || fail "expected under \"$1\": $2"
}

scenario "files one ticket for the owner, which starts with what they must do"
github
echo "[$(issue 7 "Another ticket" owner User)]" > "$T/issues"
run "$scripts/flag-public.sh"
expect_status 0
expect_calls 1 "gh issue create"
expect_call "gh issue create --title $title --label needs-human --body"
[ "$(sed -n 1p "$T/body")" = 'Add a `SECURITY.md` and switch on private vulnerability reporting, then close this ticket: the factory does neither.' ] \
  || fail "expected the first line to say what the owner must do, got: $(sed -n 1p "$T/body")"
[ -z "$(sed -n 2p "$T/body")" ] || fail "expected the first line to stand alone"
expect_output "https://github.com/owner/repo/issues/50"

scenario "the ticket says what anyone can now read, what the factory still refuses, and the two things left to the owner"
github
run "$scripts/flag-public.sh"
expect_part "What anyone can now read" "Every ticket and pull request"
expect_part "What anyone can now read" "the decision record"
expect_part "What anyone can now read" "Every agent's transcript"
expect_part "What anyone can now read" "open an issue or a pull request"
expect_part "What the factory still refuses" "only for an account with write access"
expect_part "What the factory still refuses" "decisions U563a"
expect_part "What the factory still refuses" "starts no build, no agent and no merge"
expect_part "What is left to you" '1. **Add a `SECURITY.md`**'
expect_part "What is left to you" "2. **Switch on private vulnerability reporting,**"

scenario "a repository that holds a SECURITY.md is asked only for private vulnerability reporting"
github
touch SECURITY.md
run "$scripts/flag-public.sh"
expect_status 0
[ "$(sed -n 1p "$T/body")" = 'Switch on private vulnerability reporting, then close this ticket: the factory cannot.' ] \
  || fail "expected the first line to ask only for private vulnerability reporting, got: $(sed -n 1p "$T/body")"
expect_part "What is left to you" "1. **Switch on private vulnerability reporting,**"
! grep -qF 'Add a `SECURITY.md`' "$T/body" || fail "expected no step that adds a SECURITY.md"

scenario "a second time, the ticket is open: none is filed"
github
echo "[$(issue 7 "Another ticket" owner User),$(issue 50 "$title" 'github-actions[bot]' Bot)]" > "$T/issues"
run "$scripts/flag-public.sh"
expect_status 0
expect_no_call "issue create"
expect_output "issue #50 already tells the owner"

scenario "a ticket with the same title that another account opened stops none: the ticket is filed"
github
echo "[$(issue 48 "$title" stranger User),$(issue 49 "$title" github-actions User)]" > "$T/issues"
run "$scripts/flag-public.sh"
expect_status 0
expect_calls 1 "gh issue create"

scenario "a pull request with the same title stops none: the ticket is filed"
github
jq -c '. + {pull_request: {}}' <<<"$(issue 48 "$title" 'github-actions[bot]' Bot)" | jq -sc . > "$T/issues"
run "$scripts/flag-public.sh"
expect_status 0
expect_calls 1 "gh issue create"

scenario "the open tickets cannot be read: it stops, says the owner was not told, and files nothing"
github
echo "api repos" > "$T/fail"
run "$scripts/flag-public.sh"
expect_status 1
expect_output "The owner was not told that the repository is public: the open tickets could not be read"
expect_no_call "issue create"

scenario "the ticket cannot be filed: it stops and says the owner was not told"
github
echo "issue create" > "$T/fail"
run "$scripts/flag-public.sh"
expect_status 1
expect_output "The owner was not told that the repository is public: the ticket that says so could not be filed"
expect_no_output "told the owner that the repository is public: "

scenario "the workflow that runs it starts on GitHub's public event, as events.sh lists it"
cd "$root" || exit 1
run "$scripts/events.sh"
expect_status 0
grep -qE '^\| `flag-public\.yml` \| public \| .* \| no script or workflow \|$' <<<"$out" \
  || fail "expected events.sh to list flag-public.yml under the public event"
grep -qF 'run: factory/scripts/flag-public.sh' "$root/factory/workflows/flag-public.yml" \
  || fail "expected flag-public.yml to run flag-public.sh"
