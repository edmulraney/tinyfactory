#!/usr/bin/env bash
# Tests for bootstrap's scaffold.sh: a new project lints, a half-made app is finished, its layout, what it installs.
. "$(dirname "$0")/helpers.sh"

scaffold="$root/.claude/skills/bootstrap/scripts/scaffold.sh"
probe=apps/web/src/app/import-past-index.tsx

# a_project: a project scaffolded before, whose pnpm does nothing but lint; $T/lint holds what lint does with the
# component that imports past the index: `fails` with the rule's message, `passes`, or `other` for another failure.
a_project() {
  mkdir -p apps/web/src/app
  echo '{}' > package.json
  echo '{}' > apps/web/package.json
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

scenario "leaves the code of an app it did not make as it is, and still gives the seed documents"
a_project fails
run "$scaffold" demo
expect_status 0
[ -f ARCHITECTURE.md ] || fail "expected the seed ARCHITECTURE.md"
[ ! -e apps/web/src/domain/waitlist ] || fail "expected no waitlist module in an app this run did not make"
[ ! -e apps/web/src/domain/usage ] || fail "expected no usage module in an app this run did not make"
[ ! -e apps/web/src/app/actions.ts ] || fail "expected no server action in an app this run did not make"
[ ! -e apps/web/src/db ] || fail "expected no database folder in an app this run did not make"

scenario "installs TanStack Query into an app made before the manifest copied src/lib/query, which imports it"
a_project fails
run "$scaffold" demo
expect_status 0
expect_call "pnpm --filter web add @tanstack/react-query"

scenario "installs no TanStack Query into an app that has it"
a_project fails
echo '{"dependencies": {"@tanstack/react-query": "5"}}' > apps/web/package.json
run "$scaffold" demo
expect_status 0
expect_no_call "pnpm --filter web add"

scenario "stops when TanStack Query cannot be installed into an app made before"
a_project fails
stub pnpm '[ "$*" != "--filter web add @tanstack/react-query" ] || { echo "ERR_PNPM_FETCH_404"; exit 1; }'
run "$scaffold" demo
expect_failure
expect_output "ERR_PNPM_FETCH_404"
expect_no_output "scaffold ok"
expect_no_call "pnpm install"

# The package manager the factory's own package.json names: its version, and its checksum as the registry gives it.
package_manager=$(jq -r .packageManager "$root/package.json")
pnpm_version=${package_manager#pnpm@}
pnpm_version=${pnpm_version%%+*}
integrity="sha512-$(python3 -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "${package_manager##*+sha512.}")"

# create_next_app_titled: a pnpm of the factory's version whose create-next-app refuses a folder that holds files, as
# the real one does, gives the packages the real one gives, and writes a layout that puts the page in its body, titled
# with the text in $T/title; lint fails the import past the index. The npm registry answers with the checksum in $T/integrity, and fails when that file is missing.
create_next_app_titled() {
  echo "$1" > "$T/title"
  echo "$integrity" > "$T/integrity"
  stub npm '
    [ "$1" = view ] || exit 0
    [ "$*" = "view pnpm@'"$pnpm_version"' dist.integrity" ] && cat "$T/integrity" 2>/dev/null || { echo "npm error code E404" >&2; exit 1; }'
  stub pnpm '
    [ "$*" != -v ] || { echo '"$pnpm_version"'; exit 0; }
    if [ "$1 $2" = "create next-app@latest" ]; then
      [ ! -e apps/web ] || { echo "The directory web contains files that could conflict"; exit 1; }
      mkdir -p apps/web/src/app
      echo "{\"dependencies\": {\"next\": \"16\", \"react\": \"19\", \"react-dom\": \"19\"}, \"devDependencies\": {\"typescript\": \"5\", \"@types/node\": \"20\", \"@types/react\": \"19\", \"@types/react-dom\": \"19\", \"@tailwindcss/postcss\": \"4\", \"tailwindcss\": \"4\", \"eslint\": \"9\", \"eslint-config-next\": \"16\"}}" > apps/web/package.json
      echo "{}" > apps/web/components.json
      echo "@theme { --color-*: initial; }" > apps/web/src/app/globals.css
      printf "export const metadata = {\n  title: \"%s\",\n  description: \"Generated by create next app\",\n};\nexport default function RootLayout({ children }) {\n  return (\n    <html lang=\"en\">\n      <body className=\"min-h-full flex flex-col\">{children}</body>\n    </html>\n  );\n}\n" "$(cat "$T/title")" > apps/web/src/app/layout.tsx
      exit 0
    fi
    [ "$*" = lint ] && [ -e '"$probe"' ] || exit 0
    echo "  1:1  error  Import a module through its index.ts (@/domain/<module>)."; exit 1'
}

scenario "titles a new app's pages with the project's name, and leaves no text of create-next-app"
create_next_app_titled "Create Next App"
run "$scaffold" demo
expect_status 0
expect_output "scaffold ok: demo"
grep -qF 'title: "demo"' apps/web/src/app/layout.tsx || fail "expected the layout's title to be the project's name"
! grep -qi "create next app" apps/web/src/app/layout.tsx || fail "expected no text of create-next-app in the layout"

scenario "renders Vercel's analytics component on every page of a new app, from a package it installs"
create_next_app_titled "Create Next App"
run "$scaffold" demo
expect_status 0
grep -qxF 'import { Analytics } from "@vercel/analytics/next";' apps/web/src/app/layout.tsx || fail "expected the layout to import Vercel's Analytics component"
grep -A1 -F '{children}' apps/web/src/app/layout.tsx | grep -qF '<Analytics />' || fail "expected the layout to render <Analytics /> after the page in its body"
grep -F "pnpm --filter web add " "$T/calls" | grep -qw -- "@vercel/analytics" || fail "expected scaffold.sh to install @vercel/analytics"

scenario "finishes an app that an earlier run left half-made, with its seeds, packages and build script"
create_next_app_titled "A Title The Scaffold Does Not Know"
run "$scaffold" demo
expect_failure
expect_no_call "pnpm --filter web add"
echo "Create Next App" > "$T/title"
run "$scaffold" demo
expect_status 0
expect_output "scaffold ok: demo"
grep -qF 'title: "demo"' apps/web/src/app/layout.tsx || fail "expected the layout's title to be the project's name"
[ -f apps/web/src/domain/waitlist/index.ts ] || fail "expected the seed waitlist module"
[ -f apps/web/src/domain/usage/index.ts ] || fail "expected the seed usage module"
grep -qF 'recordUsage("waitlist joined")' apps/web/src/domain/waitlist/join.ts || fail "expected the seed waitlist to record its event with no user"
grep -qF '"account_id" text,' apps/web/src/db/migrations/0001_usage-events.sql || fail "expected the table of usage events to take an event with no user"
grep -qxF 'import "server-only";' apps/web/src/db/client.ts || fail "expected the database client to fail a build that brings it into the browser"
[ -f apps/web/src/db/migrations/0001_usage-events.sql ] || fail "expected the migration that makes the table of usage events"
[ -f apps/web/src/db/schema.ts ] || fail "expected the seed database folder"
expect_call "pnpm --filter web add -D vitest"
expect_call "pnpm --filter web add drizzle-orm @neondatabase/serverless @vercel/analytics server-only"
expect_call "npm pkg set scripts.build=node src/db/migrate.mts && next build"

scenario "leaves the code of an app it finished as it is on a later run"
create_next_app_titled "Create Next App"
run "$scaffold" demo
expect_status 0
rm -r apps/web/src/domain/waitlist
echo "mine" > apps/web/src/app/page.tsx
run "$scaffold" demo
expect_status 0
expect_calls 1 "pnpm create next-app@latest"
[ ! -e apps/web/src/domain/waitlist ] || fail "expected no waitlist module put back in a finished app"
[ "$(cat apps/web/src/app/page.tsx)" = mine ] || fail "expected the project's own page to be kept"

scenario "names the package manager in a new project with its checksum, as the factory's own package.json does, and installs"
create_next_app_titled "Create Next App"
run "$scaffold" demo
expect_status 0
[[ "$package_manager" =~ ^pnpm@[0-9.]+\+sha512\.[0-9a-f]{128}$ ]] || fail "expected the factory's package.json to name pnpm with a sha512 checksum, got $package_manager"
[ "$(jq -r .packageManager package.json)" = "$package_manager" ] \
  || fail "expected the project's packageManager to be $package_manager, got $(jq -r .packageManager package.json)"
expect_call "pnpm install"

scenario "stops with a message when the registry cannot be read, and writes no package.json"
create_next_app_titled "Create Next App"
rm "$T/integrity"
run "$scaffold" demo
expect_failure
expect_output "scaffold: could not read the sha512 checksum of pnpm@$pnpm_version from the npm registry"
expect_no_output "scaffold ok"
expect_no_call "pnpm install"
[ ! -e package.json ] || fail "expected no package.json"

scenario "stops with a message when the registry gives no sha512 checksum, and writes no package.json"
create_next_app_titled "Create Next App"
echo "sha1-2jmj7l5rSw0yVb/vlWAYkK/YBwk=" > "$T/integrity"
run "$scaffold" demo
expect_failure
expect_output "scaffold: could not read the sha512 checksum of pnpm@$pnpm_version from the npm registry"
expect_no_call "pnpm install"
[ ! -e package.json ] || fail "expected no package.json"

scenario "installs each package that a file the manifest copies into the app imports"
create_next_app_titled "Create Next App"
run "$scaffold" demo
expect_status 0
# What the app has: the packages create-next-app gives, and those each `pnpm --filter web add` names, without a version.
installed=$(
  jq -r '(.dependencies + .devDependencies) | keys[]' apps/web/package.json
  grep -F "pnpm --filter web add " "$T/calls" | cut -d' ' -f5- | tr ' ' '\n' | grep -v '^-' | sed -E 's/^(@?[^@]+)@.*/\1/'
)
# The package each import names: its first part, or its first two where it is scoped. A relative path, an alias of the
# app's own code (`@/`) and a module of Node (`node:`) name none.
imported=$(
  grep '^apps/' "$root/.claude/skills/bootstrap/manifest.txt" | while IFS= read -r path; do
    find "$path" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.mts' -o -name '*.js' \)
  done | xargs grep -ohE "(from|import)[[:space:]]*\(?[[:space:]]*[\"'][^\"']+[\"']" \
    | sed -E "s/.*[\"']([^\"']+)[\"']$/\\1/" | grep -vE '^(\.|/|@/|node:)' \
    | sed -E 's#^(@[^/]+/[^/]+|[^@/][^/]*).*#\1#' | sort -u
)
[ -n "$imported" ] || fail "expected the files the manifest copies into the app to import a package"
for package in $imported; do
  grep -qxF "$package" <<<"$installed" || fail "expected scaffold.sh to install $package, which a file the manifest copies imports"
done
