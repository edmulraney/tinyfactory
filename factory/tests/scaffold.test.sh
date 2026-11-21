#!/usr/bin/env bash
# Tests for bootstrap's scaffold.sh: it proves that lint fails an import past a domain's index.ts (decisions S570).
. "$(dirname "$0")/helpers.sh"

scaffold="$root/.claude/skills/bootstrap/scripts/scaffold.sh"
probe=apps/web/src/app/import-past-index.tsx

# a_project: a project scaffolded before, whose pnpm does nothing but lint; $T/lint holds what lint does with the
# component that imports past the index: `fails` with the rule's message, `passes`, or `other` for another failure.
a_project() {
  mkdir -p apps/web/src/app
  echo '{}' > package.json
  echo "$1" > "$T/lint"
  stub pnpm '
    [ "$*" = lint ] && [ -e '"$probe"' ] || exit 0
    grep -qF "@/domain/health/index.test" '"$probe"' || { echo "the component imports no file inside the health module"; exit 1; }
    case "$(cat "$T/lint")" in
      fails) echo "  1:1  error  \"@/domain/health/index.test\" import is restricted from being used by a pattern. Import a module through its index.ts (@/domain/<module>)."; exit 1 ;;
      other) echo "  1:1  error  Parsing error"; exit 1 ;;
    esac'
}

scenario "ends with scaffold ok when lint fails the import past the index, and leaves no component behind"
a_project fails
run "$scaffold" demo
expect_status 0
expect_output "scaffold ok: demo"
expect_calls 2 "pnpm lint"
[ ! -e "$probe" ] || fail "expected the component to be removed"

scenario "stops with a message when lint passes the import past the index, and leaves no component behind"
a_project passes
run "$scaffold" demo
expect_failure
expect_output "scaffold: pnpm lint passed a component that imports @/domain/health/index.test"
expect_no_output "scaffold ok"
expect_no_call "pnpm typecheck"
[ ! -e "$probe" ] || fail "expected the component to be removed"

scenario "stops with lint's output when lint fails the component for another reason, and leaves no component behind"
a_project other
run "$scaffold" demo
expect_failure
expect_output "Parsing error"
expect_output "but not with the message of the rule"
expect_no_output "scaffold ok"
expect_no_call "pnpm typecheck"
[ ! -e "$probe" ] || fail "expected the component to be removed"
