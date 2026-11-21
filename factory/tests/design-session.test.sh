#!/usr/bin/env bash
# Tests that refine.yml runs Dara only for a proposal with a screen, and what her session may write and run.
. "$(dirname "$0")/helpers.sh"

workflow="$root/factory/workflows/refine.yml"
# shellcheck disable=SC2016
screens="hashFiles('.refine/screens.md') != ''"
# shellcheck disable=SC2016
idea='${{ env.ISSUE }}'

# step <name>: the lines of that step of the workflow, without its comments.
step() {
  awk -v name="      - name: $1" '
    /^      - / { inside = ($0 == name) }
    inside && !/^[[:space:]]*#/ { print }' "$workflow"
}
# tools <step>: each tool the step's session is allowed, one a line.
tools() { step "$1" | sed -n 's/.*--allowedTools "\(.*\)"$/\1/p' | tr ',' '\n'; }

scenario "Dara's session starts only when Peta left the screens to design, and so does the install of what renders them"
for name in "Dara designs the screens" "Install the packages that render Dara's designs"; do
  [ -n "$(step "$name")" ] || fail "expected refine.yml to hold the step: $name"
  step "$name" | grep -qF -- "if: steps.start.outputs.start == 'true' && $screens" \
    || fail "expected the step \"$name\" to run only when .refine/screens.md is there"
done

scenario "nothing but Dara's session shows a design: no step of any workflow runs post-designs.sh"
found=$(grep -n 'post-designs' "$root"/factory/workflows/*.yml | grep -v -- '--allowedTools' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)
[ -z "$found" ] || fail "expected post-designs.sh only among Dara's tools, got:
$found"

scenario "Dara writes only in .design/"
writes=$(tools "Dara designs the screens" | grep -E '^(Edit|Write|MultiEdit|NotebookEdit)' || true)
[ "$writes" = "Edit(.design/**)" ] || fail "expected the one tool that writes to be Edit(.design/**), got: $writes"

scenario "Dara's one command shows her designs on the idea of this run, and takes nothing more"
commands=$(tools "Dara designs the screens" | grep '^Bash' || true)
[ "$commands" = "Bash(factory/scripts/post-designs.sh $idea)" ] \
  || fail "expected the one command to be Bash(factory/scripts/post-designs.sh $idea), got: $commands"

scenario "Dara's other tools only read, and the session's mode denies what the list leaves out"
rest=$(tools "Dara designs the screens" | grep -v -E '^(Edit|Bash)\(' | sort | tr '\n' ' ')
[ "$rest" = "Glob Grep Read " ] || fail "expected Read, Glob and Grep beside them, got: $rest"
step "Dara designs the screens" | grep -q -- '--permission-mode default' \
  || fail "expected Dara's session to run with --permission-mode default (decisions A353e)"

scenario "a session of Dara's that ends well and showed no design fails the run, so the idea is told"
check=$(step "Fail the run if Dara showed no design")
grep -qF -- "if: steps.dara.outcome == 'success'" <<<"$check" || fail "expected the step to run after a session of Dara's that ended well"
mkdir .design
run bash -c "ISSUE=12; $(sed -n '/run: |/,$p' <<<"$check" | sed 1d)"
expect_status 1
expect_output "showed no design on idea #12"
: > .design/posted
run bash -c "ISSUE=12; $(sed -n '/run: |/,$p' <<<"$check" | sed 1d)"
expect_status 0
