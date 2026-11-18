#!/usr/bin/env bash
# Tests for factory/scripts/in-flight.sh: the tickets in flight, one per line.
. "$(dirname "$0")/helpers.sh"

# $T/issues and $T/pulls hold what gh prints; $T/fail holds the start of each call that should fail.
github() {
  echo '[]' > "$T/issues"
  echo '[]' > "$T/pulls"
  : > "$T/fail"
  stub gh '
    while read -r pattern; do
      case "$*" in "$pattern"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "$(cat "$T/issues")" "$@" ;;
      "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") cat "$T/pulls" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# pull <number> <branch> [author] [label] [draft]: one open pull request, as gh prints it.
pull() {
  jq -cn --argjson number "$1" --arg branch "$2" --arg author "${3:-app/claude}" --arg label "${4:-}" \
    --argjson draft "${5:-false}" \
    '{number: $number, headRefName: $branch, author: {login: $author}, isDraft: $draft,
      labels: (if $label == "" then [] else [{name: $label}] end)}'
}
pulls_are() { printf '%s\n' "$@" | jq -cs . > "$T/pulls"; }
expect_lines() {
  [ "$out" = "$1" ] || fail "expected exactly:"$'\n'"$1"
}

# full <line>...: asks whether a further build may start beside these lines.
full() { run "$scripts/in-flight.sh" full <<<"$(printf '%s\n' "$@")"; }

scenario "with two tickets being built or checked a further build may start: it prints nothing, and asks GitHub nothing"
github
full "20 #20 (being built)" "21 #21 (pull request #31)"
expect_status 0
expect_lines ""
expect_no_call "gh "

scenario "with nothing in flight a further build may start"
github
full ""
expect_status 0
expect_lines ""

scenario "three being built or checked are the limit: it says so, what frees a place, and which three"
github
full "20 #20 (being built, in draft pull request #30)" "21 #21 (pull request #31)" \
  "22 #22 (pull request #32, waiting for a person)" "23 #23 (draft pull request #33, left unfinished)"
expect_status 0
expect_lines "3 tickets are being built or checked
one of them has merged, been closed or been left for a person
20 #20 (being built, in draft pull request #30)
21 #21 (pull request #31)
23 #23 (draft pull request #33, left unfinished)"

scenario "a pull request waiting for the owner is not being built: four of them beside two builds leave a place"
github
full "20 #20 (being built)" "21 #21 (pull request #31)" "22 #22 (pull request #32, waiting for a person)" \
  "23 #23 (pull request #33, waiting for a person)" "24 #24 (pull request #34, waiting for a person)" \
  "25 #25 (pull request #35, waiting for a person)"
expect_status 0
expect_lines ""

scenario "five pull requests waiting for the owner are the limit: it says so, what frees a place, and which five"
github
full "20 #20 (being built)" "22 #22 (pull request #32, waiting for a person)" \
  "23 #23 (pull request #33, waiting for a person; pull request #36, waiting for a person)" \
  "24 #24 (pull request #34, waiting for a person)" "25 #25 (pull request #35, waiting for a person)"
expect_status 0
expect_lines "5 pull requests wait for the owner
the owner has merged or closed one of them
22 #22 (pull request #32, waiting for a person)
23 #23 (pull request #33, waiting for a person; pull request #36, waiting for a person)
24 #24 (pull request #34, waiting for a person)
25 #25 (pull request #35, waiting for a person)"

scenario "a ticket with one pull request waiting for the owner and another in review is still being checked"
github
full "20 #20 (being built)" "21 #21 (being built)" "22 #22 (pull request #32, waiting for a person; pull request #36)"
expect_status 0
expect_output "3 tickets are being built or checked"
expect_output "22 #22 (pull request #32, waiting for a person; pull request #36)"

scenario "a factory pull request that names no ticket is counted with those being built"
github
full "20 #20 (being built)" "21 #21 (being built)" "- pull request #120, which names no ticket"
expect_status 0
expect_output "3 tickets are being built or checked"
expect_output "- pull request #120, which names no ticket"

scenario "a factory pull request that names no ticket and waits for the owner is counted with those that wait"
github
full "20 #20 (being built)" "21 #21 (being built)" "- pull request #120, which names no ticket, waiting for a person"
expect_status 0
expect_lines ""
full "22 #22 (pull request #32, waiting for a person)" "23 #23 (pull request #33, waiting for a person)" \
  "24 #24 (pull request #34, waiting for a person)" "25 #25 (pull request #35, waiting for a person)" \
  "- pull request #120, which names no ticket, waiting for a person"
expect_output "5 pull requests wait for the owner"
expect_output "- pull request #120, which names no ticket, waiting for a person"

scenario "prints nothing when nothing is in flight"
github
run "$scripts/in-flight.sh"
expect_status 0
expect_lines ""

scenario "an issue labelled in-progress with no pull request yet is being built"
github
echo '[{"number":64}]' > "$T/issues"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "64 #64 (being built)"

scenario "a pull request labelled in-progress is not a ticket being built"
github
echo '[{"number":64},{"number":112,"pull_request":{}}]' > "$T/issues"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "64 #64 (being built)"

scenario "a ticket and the pull request from its branch are one line, not two"
github
echo '[{"number":64},{"number":70}]' > "$T/issues"
pulls_are "$(pull 112 feat/64-three-tickets-in-flight)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "64 #64 (pull request #112)
70 #70 (being built)"

scenario "a factory pull request waiting for the owner is in flight, though its ticket is not in-progress"
github
pulls_are "$(pull 111 fix/57-fits-main app/claude needs-human)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "57 #57 (pull request #111, waiting for a person)"

scenario "a draft whose ticket is in-progress is a build still running"
github
echo '[{"number":70}]' > "$T/issues"
pulls_are "$(pull 130 feat/70-other-ticket app/claude "" true)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "70 #70 (being built, in draft pull request #130)"

scenario "a draft whose ticket is not in-progress was left unfinished, and is still in flight"
github
pulls_are "$(pull 131 feat/71-other-ticket app/claude "" true)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "71 #71 (draft pull request #131, left unfinished)"

scenario "a person's pull request is not in flight, whatever its branch is called"
github
pulls_are "$(pull 30 feat/12-export-forecast-csv ada)" "$(pull 31 my-idea ada)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines ""

scenario "a factory pull request whose branch names no ticket is in flight by itself"
github
echo '[{"number":64}]' > "$T/issues"
pulls_are "$(pull 120 chore/tidy-12-things)" "$(pull 121 12-no-type)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "64 #64 (being built)
- pull request #120, which names no ticket
- pull request #121, which names no ticket"

scenario "a factory pull request whose branch names no ticket waits for the owner once it is ready for review and flagged"
github
pulls_are "$(pull 120 chore/tidy-12-things app/claude needs-human)" "$(pull 121 12-no-type app/claude needs-human true)"
run "$scripts/in-flight.sh"
expect_status 0
expect_lines "- pull request #120, which names no ticket, waiting for a person
- pull request #121, which names no ticket"

scenario "only open issues and open pull requests are asked for"
github
run "$scripts/in-flight.sh"
expect_call "gh api repos/{owner}/{repo}/issues?state=open&labels=in-progress"
expect_call "gh pr list --state open"

scenario "stops when the issues cannot be read: that is not 'nothing in flight'"
github
pulls_are "$(pull 111 fix/57-fits-main)"
echo "api repos/{owner}/{repo}/issues?state=open&labels=in-progress" > "$T/fail"
run "$scripts/in-flight.sh"
expect_status 1
expect_output "The issues labelled in-progress could not be read from GitHub"
expect_no_output "#57"

scenario "stops when the pull requests cannot be read, and prints no line"
github
echo '[{"number":64}]' > "$T/issues"
echo "pr list" > "$T/fail"
run "$scripts/in-flight.sh"
expect_status 1
expect_output "The open pull requests could not be read from GitHub"
expect_no_output "#64"

scenario "stops when GitHub answers with something that is not a list"
github
echo '{"message":"Server Error"}' > "$T/pulls"
run "$scripts/in-flight.sh"
expect_status 1
expect_output "could not be read, so it is not known what is in flight"
