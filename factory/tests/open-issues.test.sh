#!/usr/bin/env bash
# Tests for open-issues.sh, which lists only the open issues the owner or the bots opened (decisions A653a).
. "$(dirname "$0")/helpers.sh"

# an_issue <number> <login> <type> <association> [pull] [repo]: one GitHub lists, titled "Issue <number>", labelled factory.
an_issue() {
  jq -cn --argjson n "$1" --arg login "$2" --arg type "$3" --arg association "$4" --arg pull "${5:-}" \
    --arg repo "${6:-owner/myapp}" \
    '{number: $n, title: "Issue \($n)", labels: [{name: "factory"}], user: {login: $login, type: $type},
      author_association: $association, repository_url: "https://api.github.com/repos/\($repo)"}
      | if $pull != "" then .pull_request = {} else . end' >> "$T/issues"
}
# Everyone who may open an issue: the owner, the two bots, a stranger, and accounts named like a bot that are not one.
everyone() {
  an_issue 12 owner User OWNER
  an_issue 13 'github-actions[bot]' Bot NONE
  an_issue 14 'claude[bot]' Bot NONE
  an_issue 15 stranger User NONE
  an_issue 16 'claude[bot]' User NONE
  an_issue 17 github-actions User CONTRIBUTOR
  an_issue 11 collaborator User COLLABORATOR
}
# $T/fail holds words of the call to fail.
github() {
  : > "$T/issues"; echo none > "$T/fail"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --jq "* \
        | "api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 --paginate --jq "*)
        json "$(jq -sc . "$T/issues")" "$@" ;;
      "api repos/{owner}/{repo} --jq .full_name") echo owner/myapp ;;
      "api repos/{owner}/{repo}/collaborators/collaborator/permission") echo "{\"permission\":\"read\"}" ;;
      "api repos/{owner}/{repo}/collaborators/writer/permission") echo "{\"permission\":\"write\"}" ;;
      "api --method GET search/issues -f q=repo:owner/myapp is:open Driving the backlog in:title -f per_page=100 --paginate --jq "*)
        json "$(jq -sc "{items: .}" "$T/issues")" "$@" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
numbers() { jq -r '[.[].number] | join(" ")' <<<"$1"; }

scenario "the open issues the owner and the two bots opened are listed, lowest first, and a stranger's or a false bot's are not"
github
everyone
an_issue 18 owner User OWNER pull
run "$scripts/open-issues.sh"
expect_status 0
[ "$(numbers "$out")" = "12 13 14" ] || fail "expected issues 12, 13 and 14, got: $(numbers "$out")"
[ "$(jq -c '.[0]' <<<"$out")" = '{"number":12,"title":"Issue 12","labels":["factory"],"pull_request":false}' ] \
  || fail "expected each issue as its number, title, label names and whether it is a pull request, got: $(jq -c '.[0]' <<<"$out")"

scenario "an organisation member's issue is kept when they may write, and a collaborator's that may only read is not"
github
everyone
an_issue 22 writer User MEMBER
run "$scripts/open-issues.sh"
expect_status 0
[ "$(numbers "$out")" = "12 13 14 22" ] || fail "expected 12, 13, 14 and the writing member's 22, got: $(numbers "$out")"
expect_call "gh api repos/{owner}/{repo}/collaborators/writer/permission"
expect_no_call "gh api repos/{owner}/{repo}/collaborators/stranger/permission"

scenario "a label lists only the open issues with it"
github
everyone
run "$scripts/open-issues.sh" factory
expect_status 0
expect_call "gh api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 --paginate"
[ "$(numbers "$out")" = "12 13 14" ] || fail "expected issues 12, 13 and 14, got: $(numbers "$out")"

scenario "a search finds the owner's and the bots' issues and pull requests in this repository, and no stranger's"
github
everyone
an_issue 18 owner User OWNER pull
an_issue 19 stranger User NONE pull
run "$scripts/open-issues.sh" --search "Driving the backlog in:title"
expect_status 0
[ "$(numbers "$out")" = "12 13 14 18" ] || fail "expected 12, 13, 14 and the owner's pull request 18, got: $(numbers "$out")"
jq -e 'map(select(.number == 18))[0].pull_request' <<<"$out" >/dev/null || fail "expected 18 to be marked a pull request"

scenario "a search that names another repository keeps none of its issues, though its bot or owner opened them"
github
everyone
an_issue 20 'github-actions[bot]' Bot NONE "" attacker/r
an_issue 21 attacker User OWNER "" attacker/r
run "$scripts/open-issues.sh" --search "Driving the backlog in:title"
expect_status 0
[ "$(numbers "$out")" = "12 13 14" ] || fail "expected only this repository's 12, 13 and 14, got: $(numbers "$out")"

scenario "nothing found is an empty list"
github
an_issue 15 stranger User NONE
run "$scripts/open-issues.sh" --search "Driving the backlog in:title"
expect_status 0
[ "$out" = "[]" ] || fail "expected an empty list, got: $out"

for failing in "issues?state=open" "--jq .full_name" "search/issues"; do
  scenario "a call to GitHub that fails ($failing) stops it with a message and prints no list"
  github
  everyone
  echo "$failing" > "$T/fail"
  case "$failing" in "issues?state=open") args=() ;; *) args=(--search "Driving the backlog in:title") ;; esac
  printed=$("$scripts/open-issues.sh" ${args[@]+"${args[@]}"} 2>"$T/stderr") && status=0 || status=$?
  out=$(cat "$T/stderr")
  expect_status 1
  [ -z "$printed" ] || fail "expected nothing printed, got: $printed"
  expect_output "Could not"
done

scenario "a label that would change the address, or a search with no words, is refused before GitHub is asked"
github
run "$scripts/open-issues.sh" 'factory&state=closed'
expect_status 1
run "$scripts/open-issues.sh" --search ""
expect_status 1
expect_no_call "gh "

# The step, read from the source, so a change there fails here.
scenario "the retro's list of open tickets leaves out the ones a stranger opened"
github
everyone
mkdir .sessions
ln -s "$root/factory" factory
commands=$(awk '$0 == "      - name: List the open tickets" { on = 1; next } on && /^      (- |#)/ { on = 0 } on' "$root/factory/workflows/retro.yml" \
  | sed -n '/^        run: |$/,$p' | sed '1d; s/^          //')
run bash -c "$commands"
expect_status 0
[ "$(numbers "$(cat .sessions/tickets.json)")" = "12 13 14" ] \
  || fail "expected the retro's tickets to be 12, 13 and 14, got: $(cat .sessions/tickets.json)"
