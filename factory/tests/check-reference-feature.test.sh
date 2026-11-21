#!/usr/bin/env bash
# Tests for check-reference-feature.sh: each file the "Reference feature" section names is in the repo (H572a).
. "$(dirname "$0")/helpers.sh"

# project: a project whose section names a page, a domain's folder and a test, all of which it holds.
project() {
  mkdir -p apps/web/src/app apps/web/src/server/twin
  touch apps/web/src/app/page.tsx apps/web/src/server/twin/index.ts apps/web/src/server/twin/index.test.ts
  printf '%s\n' '# Architecture' '' '## Modules' '' 'A domain is a folder `src/server/<domain>`.' '' \
    '## Reference feature' '' \
    '1. **A page only shows.** `apps/web/src/app/page.tsx` shows what `getTwin` answered.' \
    '1. **A small index.** `apps/web/src/server/twin` and its test, `apps/web/src/server/twin/index.test.ts`.' '' \
    '## Environments' '' 'Every environment answers `GET /api/health`.' > ARCHITECTURE.md
}
check() { run "$scripts/check-reference-feature.sh"; }
refuses() {
  expect_status 1
  expect_output "$1"
  expect_no_output "reference feature ok"
}

scenario "passes a section whose files and folders are all there, and reads no path of another section"
project
check
expect_status 0
expect_output "reference feature ok: 3 files"

scenario "fails when a file the section names is deleted, with the line and the path"
project
rm apps/web/src/server/twin/index.test.ts
check
refuses 'ARCHITECTURE.md:10: the section "## Reference feature" names apps/web/src/server/twin/index.test.ts, and the repo holds no such file'

scenario "fails when a file the section names is moved"
project
mkdir apps/web/src/app/home
mv apps/web/src/app/page.tsx apps/web/src/app/home/page.tsx
check
refuses "ARCHITECTURE.md:9: the section \"## Reference feature\" names apps/web/src/app/page.tsx"

scenario "reports every missing file, not only the first"
project
rm apps/web/src/app/page.tsx apps/web/src/server/twin/index.test.ts
check
refuses "names apps/web/src/app/page.tsx"
expect_output "names apps/web/src/server/twin/index.test.ts"

scenario "fails a path written from the app's folder, which is no path from the repo root"
project
sed -i.bak '/^## Environments/,$d' ARCHITECTURE.md
echo '1. **A table has one owner.** `src/server/twin/index.ts` reads it.' >> ARCHITECTURE.md
check
refuses "names src/server/twin/index.ts, and the repo holds no such file"

scenario "fails a document with no such section"
project
sed -i.bak 's/^## Reference feature$/## Example/' ARCHITECTURE.md
check
refuses 'ARCHITECTURE.md: it has no section "## Reference feature"'

scenario "fails a section that names no file"
project
sed -i.bak '/^1\. /d' ARCHITECTURE.md
check
refuses 'ARCHITECTURE.md: its section "## Reference feature" names no file'

scenario "fails where there is no ARCHITECTURE.md"
check
refuses "ARCHITECTURE.md: there is no such file"

scenario "this repo's lint and a scaffolded project's both run the check"
grep -F '"lint": "' "$root/package.json" | grep -qF 'factory/scripts/check-reference-feature.sh &&' \
  || fail "expected the lint script in $root/package.json to run check-reference-feature.sh"
grep -F '"lint": "' "$root/.claude/skills/bootstrap/scripts/scaffold.sh" | grep -qF 'factory/scripts/check-reference-feature.sh &&' \
  || fail "expected the lint script scaffold.sh writes to run check-reference-feature.sh"

scenario "the seed's section names only files that a scaffolded project holds: its seeds and the manifest's files"
cp "$root/.claude/skills/bootstrap/templates/ARCHITECTURE.md" ARCHITECTURE.md
(cd "$root/.claude/skills/bootstrap/templates" && find apps -type f) | while IFS= read -r file; do mkdir -p "$(dirname "$file")"; touch "$file"; done
grep -vE '^\s*(#|$)' "$root/.claude/skills/bootstrap/manifest.txt" | grep '^apps/' | while IFS= read -r file; do mkdir -p "$(dirname "$file")"; touch "$file"; done
check
expect_status 0
