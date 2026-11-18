#!/usr/bin/env bash
# Scaffolds the monorepo in the current directory: a Next.js app with shadcn/ui on a closed
# grey-scale theme, the factory's own files (skills, workflows, ticket templates, check scripts,
# test tooling) and the seed docs.
# Then proves it lints, typechecks, passes the app's tests and builds.
# Safe to re-run: each part is skipped if it already exists.
# Usage: scaffold.sh [name]   (name defaults to the directory name)
set -euo pipefail

name="${1:-$(basename "$PWD")}"
here="$(cd "$(dirname "$0")" && pwd)"
templates="$here/../templates"
manifest="$here/../manifest.txt"
factory_root="$(cd "$here/../../../.." && pwd)"   # the repo this skill lives in is the factory's source

# Copies the files listed in manifest.txt from the factory's repo into this project.
# "overwrite" replaces files a generator just wrote; the default keeps whatever already exists.
install_factory_files() {
  local mode="${1:-keep}" path file
  [ "$factory_root" != "$PWD" ] || return 0
  while IFS= read -r path; do
    case "$path" in '' | '#'*) continue ;; esac
    if [ ! -e "$factory_root/$path" ]; then
      # A listed folder under factory/ may hold nothing yet, and git keeps no empty folder:
      # factory/free-tier before the first ticket adds an entry. A mistyped path there is still
      # caught, because the file it meant is then one check-inventory.sh finds no owner for.
      # That check reads nothing outside factory/, so any other path that names nothing stops
      # the scaffold here: skipped, the new project would be built without the file.
      case "$path" in factory/*) continue ;; esac
      echo "scaffold: manifest.txt lists '$path', which is not in $factory_root. Correct or remove the line." >&2
      exit 1
    fi
    (cd "$factory_root" && find "$path" -type f 2>/dev/null) | while IFS= read -r file; do
      if [ "$mode" = overwrite ] || [ ! -e "$file" ]; then
        mkdir -p "$(dirname "$file")"
        cp "$factory_root/$file" "$file"
      fi
    done
  done < "$manifest"
  # The workflows GitHub runs are copies of the sources just installed. They are made here and
  # not listed in the manifest, so each workflow lives once in the factory's repo and a new
  # project starts with the two folders matching, which its lint checks (check-inventory.sh).
  # Afterwards only install-workflows.yml changes them, once a change to a source merges.
  mkdir -p .github/workflows
  for file in factory/workflows/*; do
    if [ "$mode" = overwrite ] || [ ! -e ".github/workflows/$(basename "$file")" ]; then
      cp "$file" ".github/workflows/$(basename "$file")"
    fi
  done
}

fresh=no
if [ ! -d apps/web ]; then
  fresh=yes
  mkdir -p apps  # create-next-app refuses to run if the parent folder is missing
  pnpm create next-app@latest apps/web \
    --ts --eslint --app --src-dir --tailwind --import-alias "@/*" \
    --use-pnpm --skip-install --disable-git --yes

  # create-next-app assumes a standalone app; lift its workspace settings to the root.
  # The three folders after apps/* hold nothing to build or install: each is a package, by the
  # package.json the manifest gives it, so that Vercel builds nothing for a change inside one
  # (decisions M165a).
  {
    printf 'packages:\n  - apps/*\n  - factory\n  - .claude\n  - .github\n'
    if [ -f apps/web/pnpm-workspace.yaml ]; then echo; cat apps/web/pnpm-workspace.yaml; fi
  } > pnpm-workspace.yaml
  # The starter page is replaced by the factory's seed page, which uses the design tokens.
  rm -f apps/web/pnpm-workspace.yaml apps/web/README.md apps/web/src/app/page.tsx

  (
    cd apps/web
    npm pkg delete packageManager
    # Next.js generates global types (e.g. LayoutProps); tsc fails on a clean checkout without typegen.
    npm pkg set scripts.typecheck="next typegen && tsc --noEmit" \
      scripts.test="vitest run" scripts.test:e2e="playwright test"
    printf '\n# test output\n/test-results/\n/playwright-report/\n/blob-report/\n' >> .gitignore
  )
fi

if [ ! -f package.json ]; then
  # Read the version before the redirect below creates an empty package.json, which pnpm chokes on.
  pnpm_version=$(pnpm -v)
  cat > package.json <<JSON
{
  "name": "$name",
  "private": true,
  "packageManager": "pnpm@$pnpm_version",
  "scripts": {
    "dev": "pnpm --filter web dev",
    "build": "pnpm -r build",
    "lint": "factory/scripts/check-inventory.sh && factory/scripts/check-decisions.sh && factory/scripts/check-free-tier.sh && factory/scripts/check-rule-files.sh && factory/scripts/check-factory.sh && pnpm -r lint",
    "typecheck": "pnpm -r typecheck",
    "test": "factory/scripts/test-factory.sh && pnpm -r test",
    "test:e2e": "pnpm --filter web test:e2e"
  }
}
JSON
fi

if [ ! -f .gitignore ]; then
  printf 'node_modules\n.DS_Store\n.env*\n.vercel\n*.tsbuildinfo\n' > .gitignore
fi

# Seed files start from the factory's templates; a project edits its copies afterwards.
(cd "$templates" && find . -type f | sed 's|^\./||') | while IFS= read -r seed; do
  if [ ! -e "$seed" ]; then
    mkdir -p "$(dirname "$seed")"
    sed "s/{{name}}/$name/g" "$templates/$seed" > "$seed"
  fi
done

# The design foundation (DESIGN.md): shadcn/ui's components on its default grey-scale theme of
# named tokens, with Tailwind's own palette removed so no other colour exists. The factory makes
# no design choices of its own here; it takes shadcn's defaults and closes the door behind them.
design_foundation() {
  local css=apps/web/src/app/globals.css
  if [ ! -f apps/web/components.json ]; then
    (cd apps/web && pnpm dlx shadcn@latest init -d -y --no-monorepo --no-rtl \
      button input label card badge table </dev/null)
  fi
  grep -q -- '--color-\*: initial' "$css" && return 0
  python3 - "$css" apps/web/src/app/layout.tsx <<'PY'
import pathlib, sys
css = pathlib.Path(sys.argv[1]); text = css.read_text()
marker = "@theme inline {\n"
assert text.count(marker) == 1, "shadcn's theme block was not found in globals.css"
text = text.replace(marker, """/* The palette is closed: Tailwind's default colours are removed, so the only colours that exist
   are the named tokens below (see DESIGN.md). A class like bg-blue-500 produces nothing and
   fails lint. Adding a colour means adding a token here, which is a design decision. */
@theme {
  --color-*: initial;
  --color-black: #000;
  --color-white: #fff;
}

""" + marker)
# The one change to shadcn's theme: the page is the palette's lightest grey, so white cards read
# as raised. It is a token, not a one-off colour (decisions D7).
page = ":root {\n  --background: oklch(1 0 0);\n"
assert text.count(page) == 1, "shadcn's light background token was not found in globals.css"
text = text.replace(page, ":root {\n  /* The page is the palette's lightest grey (neutral-50) so that white cards read as raised. */\n  --background: oklch(0.985 0 0);\n")
# shadcn 4.23 points --font-sans at itself; the app's font is the variable the layout defines.
if "--font-geist-sans" in pathlib.Path(sys.argv[2]).read_text():
    text = text.replace("--font-sans: var(--font-sans);", "--font-sans: var(--font-geist-sans);")
    text = text.replace("--font-heading: var(--font-sans);", "--font-heading: var(--font-geist-sans);")
css.write_text(text)
PY
}

if [ "$fresh" = yes ]; then
  install_factory_files overwrite   # the factory's ESLint config replaces the generated one
  design_foundation
  # vitest needs Node 22+ types; create-next-app pins @types/node to 20.
  # The Tailwind lint plugin and the accessibility scanner are what enforce DESIGN.md.
  pnpm --filter web add -D vitest @playwright/test "@types/node@^24" \
    eslint-plugin-better-tailwindcss @axe-core/playwright
else
  install_factory_files
fi

pnpm install
# The checks below list the project's files with `git ls-files` (decisions S34). A project that
# already has a commit is left as it is; github.sh makes a new one's first commit later.
git rev-parse --git-dir >/dev/null 2>&1 || git init -q -b main
git rev-parse --quiet --verify HEAD >/dev/null 2>&1 || git add -A
pnpm lint
pnpm typecheck
# The app's tests alone. `pnpm test` also runs the factory's own script tests, which take minutes
# and prove the factory, not this project: they run where the factory is built.
pnpm -r test
pnpm build
echo "scaffold ok: $name"
