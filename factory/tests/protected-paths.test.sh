#!/usr/bin/env bash
# Tests for factory/scripts/protected-paths.sh, which prints the factory's files among the paths on stdin.
. "$(dirname "$0")/helpers.sh"

# The factory's files, as CLAUDE.md ("Off limits") lists them.
protected=(
  ".claude/skills/implement/SKILL.md"
  ".claude/settings.json"
  ".github/workflows/ci.yml"
  ".github/PULL_REQUEST_TEMPLATE.md"
  "factory/scripts/ship.sh"
  "factory/tests/ship.test.sh"
  "factory/decisions.md"
)
for path in "${protected[@]}"; do
  scenario "keeps $path for a factory ticket"
  run "$scripts/protected-paths.sh" <<<"$path"
  expect_status 1
  [ "$out" = "$path" ] || fail "expected it to print exactly: $path"
done

# What the product engineer changes, the product's bar and CLAUDE.md, which owner-decides.sh holds, and names
# that only look like a factory file.
open=(
  "CLAUDE.md"
  "TASTE.md"
  "DESIGN.md"
  "apps/web/eslint.config.mjs"
  "apps/web/tsconfig.json"
  "apps/web/src/app/globals.css"
  "apps/web/components.json"
  "apps/web/e2e/test.ts"
  "factory.md"
  "apps/web/src/app/page.tsx"
  "apps/web/src/server/health/index.ts"
  "apps/web/e2e/acceptance/12-export-forecast-csv.spec.ts"
  "apps/web/e2e/test.tsx"
  "apps/web/src/factory/widget.ts"
  "apps/web/package.json"
  "PURPOSE.md"
  "ARCHITECTURE.md"
  "README.md"
  "product/decisions.md"
  "docs/TASTE.md"
  "CLAUDE.md.bak"
  "pnpm-lock.yaml"
)
for path in "${open[@]}"; do
  scenario "lets $path through"
  run "$scripts/protected-paths.sh" <<<"$path"
  expect_status 0
  [ -z "$out" ] || fail "expected it to print nothing"
done

scenario "prints only the factory's files of a mixed change, and fails"
run "$scripts/protected-paths.sh" <<<"apps/web/src/app/page.tsx
TASTE.md
apps/web/src/lib/forecast.ts
factory/scripts/ship.sh"
expect_status 1
[ "$out" = "factory/scripts/ship.sh" ] || fail "expected exactly factory/scripts/ship.sh"

scenario "passes a change with no files"
run "$scripts/protected-paths.sh" </dev/null
expect_status 0
[ -z "$out" ] || fail "expected it to print nothing"
