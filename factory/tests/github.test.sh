#!/usr/bin/env bash
# Tests for bootstrap's github.sh: the repo is created public or private as PURPOSE.md says, and an existing one kept.
. "$(dirname "$0")/helpers.sh"

github="$root/.claude/skills/bootstrap/scripts/github.sh"

# a_project: a folder with a first commit and a remote; GitHub has the repo only when $T/exists is there, and refuses
# a ruleset unless $T/rulesets is there; $T/fail holds a word of the call to fail.
a_project() {
  echo none > "$T/fail"
  stub git '
    if grep -qF -- "$(cat "$T/fail")" <<<"git $*"; then echo "git: could not connect" >&2; exit 1; fi'
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"gh $*"; then echo "gh: could not connect" >&2; exit 1; fi
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "repo view owner/myapp") [ -e "$T/exists" ] ;;
      "repo create owner/myapp --public" | "repo create owner/myapp --private") touch "$T/exists" ;;
      "api -X PATCH repos/owner/myapp "*) ;;
      "api repos/owner/myapp/rulesets "*) [ -e "$T/rulesets" ] || exit 1; json "[]" "$@" ;;
      "api -X POST repos/owner/myapp/rulesets --input -") cat > /dev/null; [ -e "$T/rulesets" ] ;;
      "label list "*) json "[]" "$@" ;;
      "label create "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "creates a private repository when PURPOSE.md does not say it is public"
a_project
printf '%s\n' "# Purpose" "## What it will not do" "- **Have accounts.** It is a calculator." > PURPOSE.md
run "$github" myapp
expect_status 0
expect_call "gh repo create owner/myapp --private"
expect_no_call "--public"
expect_output "github ok: https://github.com/owner/myapp"

scenario "creates a public repository when PURPOSE.md says it is public"
a_project
printf '%s\n' "# Purpose" "## What it will not do" "- **Keep its repository private.** It is built in the open." > PURPOSE.md
run "$github" myapp
expect_status 0
expect_call "gh repo create owner/myapp --public"
expect_no_call "--private"

scenario "creates a private repository when there is no PURPOSE.md"
a_project
run "$github" myapp
expect_status 0
expect_call "gh repo create owner/myapp --private"
expect_no_call "--public"

scenario "creates a private repository when PURPOSE.md only speaks of a public repository in other words"
a_project
printf '%s\n' "# Purpose" "The repository is public." "- **Keep its repository private**, perhaps." > PURPOSE.md
run "$github" myapp
expect_status 0
expect_call "gh repo create owner/myapp --private"

scenario "keeps a repository that exists as it is, whatever PURPOSE.md says"
a_project
touch "$T/exists"
echo "- **Keep its repository private.**" > PURPOSE.md
run "$github" myapp
expect_status 0
expect_no_call "gh repo create"
expect_no_call "visibility"
expect_call "git push -u origin main"

scenario "stops, with nothing created, when GitHub will not say who is signed in"
a_project
echo "api user" > "$T/fail"
run "$github" myapp
expect_failure
expect_no_call "gh repo create"

scenario "stops, with nothing pushed, when the repository cannot be created"
a_project
echo "repo create" > "$T/fail"
run "$github" myapp
expect_failure
expect_output "could not connect"
expect_no_call "git push"

scenario "stops, with no setting changed, when the push fails"
a_project
echo "git push" > "$T/fail"
run "$github" myapp
expect_failure
expect_no_call "api -X PATCH"

scenario "stops, with no label created, when the merge settings cannot be set"
a_project
echo "api -X PATCH" > "$T/fail"
run "$github" myapp
expect_failure
expect_no_call "gh label create"

scenario "says the factory's own guards apply where GitHub refuses the ruleset, and carries on"
a_project
run "$github" myapp
expect_status 0
expect_output "GitHub will not lock main on this plan"
expect_call "gh label create ready -R owner/myapp"

scenario "locks main where GitHub allows the ruleset, as it does for a public repository"
a_project
touch "$T/rulesets"
echo "- **Keep its repository private.**" > PURPOSE.md
run "$github" myapp
expect_status 0
expect_call "gh api -X POST repos/owner/myapp/rulesets --input -"
expect_output "main is locked by a GitHub ruleset: pull requests only, admin may bypass"

scenario "stops when a label cannot be created"
a_project
echo "label create" > "$T/fail"
run "$github" myapp
expect_failure
expect_no_output "github ok"
