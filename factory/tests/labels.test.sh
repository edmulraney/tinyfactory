#!/usr/bin/env bash
# Tests for bootstrap's labels.sh: the factory's labels are created, GitHub's defaults deleted unless a ticket has one.
. "$(dirname "$0")/helpers.sh"

labels="$root/.claude/skills/bootstrap/scripts/labels.sh"

# github_holds <label>...; an open ticket carries each label in $T/carried; $T/fail holds a word of the call to fail.
github_holds() {
  printf '%s\n' "$@" > "$T/have"
  : > "$T/carried"
  echo none > "$T/fail"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "label create "*) ;;
      "label list -R owner/myapp "*) json "$(jq -R "{name: .}" "$T/have" | jq -s .)" "$@" ;;
      "api --method GET repos/owner/myapp/issues -f labels="*)
        all="$*"; label=${all#*-f labels=}; label=${label% -f state=open*}
        case "$*" in *"-f state=open -f per_page=1 "*) ;; *) echo "not asked for open tickets only: gh $*" >&2; exit 1 ;; esac
        if grep -qxF -- "$label" "$T/carried"; then json "[{\"number\":3}]" "$@"; else json "[]" "$@"; fi ;;
      "label delete "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "creates every label the factory uses, the six types, proposal, retro and proof among them, in the repo it is given"
github_holds ready
run "$labels" owner/myapp
expect_status 0
for label in ready needs-human factory initiative tweak bug chore research in-progress deployed reverted proposal retro waits-for-main proof; do
  expect_call "gh label create $label -R owner/myapp --force"
done
expect_output "labels ok: owner/myapp"
expect_no_call "gh label delete"

scenario "deletes a default label no open ticket carries"
github_holds ready wontfix "good first issue"
run "$labels" owner/myapp
expect_status 0
expect_call "gh label delete wontfix -R owner/myapp --yes"
expect_call "gh label delete good first issue -R owner/myapp --yes"
expect_output 'deleted the default label "good first issue"'
expect_output "labels ok: owner/myapp"

scenario "leaves a default label an open ticket carries, says so, and deletes the others"
github_holds question duplicate
echo question > "$T/carried"
run "$labels" owner/myapp
expect_status 0
expect_no_call "gh label delete question"
expect_output 'left the default label "question": an open ticket carries it'
expect_call "gh label delete duplicate -R owner/myapp --yes"

scenario "does not look for a default label the repo no longer has"
github_holds ready proposal
run "$labels" owner/myapp
expect_status 0
expect_no_call "repos/owner/myapp/issues"
expect_no_call "gh label delete"

scenario "deletes no label that is not one of GitHub's defaults"
github_holds accessibility ready proposal proof documentation
run "$labels" owner/myapp
expect_status 0
expect_call "gh label delete documentation -R owner/myapp --yes"
[ "$(grep -c '^gh label delete' "$T/calls")" = 1 ] || fail "expected one label to be deleted, and no other"

scenario "stops when a label cannot be created"
github_holds wontfix
echo "label create proposal" > "$T/fail"
run "$labels" owner/myapp
expect_failure
expect_no_call "gh label delete"
expect_no_output "labels ok"

scenario "stops when the labels cannot be listed, and deletes none"
github_holds wontfix
echo "label list" > "$T/fail"
run "$labels" owner/myapp
expect_failure
expect_output "Could not list the labels of owner/myapp"
expect_no_call "gh label delete"
expect_no_output "labels ok"

scenario "stops without deleting a label when it cannot ask whether a ticket carries it"
github_holds wontfix
echo "repos/owner/myapp/issues" > "$T/fail"
run "$labels" owner/myapp
expect_failure
expect_output 'Could not ask whether an open ticket carries "wontfix"'
expect_no_call "gh label delete"
expect_no_output "labels ok"

scenario "stops when a label cannot be deleted"
github_holds invalid wontfix
echo "label delete invalid" > "$T/fail"
run "$labels" owner/myapp
expect_failure
expect_output 'Could not delete the default label "invalid"'
expect_no_output 'deleted the default label "invalid"'
expect_no_output "labels ok"
