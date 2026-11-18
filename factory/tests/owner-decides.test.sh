#!/usr/bin/env bash
# Tests for factory/scripts/owner-decides.sh, which prints what a diff changes that only the owner may decide.
. "$(dirname "$0")/helpers.sh"

workflow='name: build
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions:
      contents: write
      issues: write
      pull-requests: write
      statuses: read
      actions: write
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main
      - name: Build it
        uses: anthropics/claude-code-action@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          allowed_bots: claude
          claude_args: |
            --model claude-fable-5-2
            --effort medium
            --max-turns 40
            --allowedTools "Read,Glob,Grep"
      - name: Say so
        env:
          GH_TOKEN: ${{ github.token }}
        run: factory/scripts/say.sh "$PR"'

# change <path> <before> <after>: the diff git prints for it, in $T/diff; an empty side is a file that is not there.
change() {
  rm -rf "$T/repo"
  git init --quiet "$T/repo"
  (
    cd "$T/repo" || exit 1
    mkdir -p "$(dirname "$1")"
    git commit --quiet --allow-empty -m "base"
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$1"; git add -A; git commit --quiet -m "before"; fi
    if [ -n "$3" ]; then printf '%s\n' "$3" > "$1"; else rm -f "$1"; fi
    git add -A
    git diff --cached
  ) > "$T/diff"
}
# in_workflow <old> <new>: a workflow source with that one change.
in_workflow() {
  replace_first "$workflow" "$1" "$2"
  change factory/workflows/build.yml "$workflow" "$replaced"
}
decides() { run "$scripts/owner-decides.sh" < "$T/diff"; }
expect_held() {
  expect_status 1
  [ "$out" = "$1" ] || fail "expected it to print exactly: $1"
}
expect_unheld() {
  expect_status 0
  [ -z "$out" ] || fail "expected it to print nothing"
}

# Spend or limits.
while IFS='|' read -r what old new; do
  scenario "holds a workflow's changed $what, as spend or limits"
  in_workflow "$old" "$new"
  decides
  expect_held "spend or limits: factory/workflows/build.yml: $old
spend or limits: factory/workflows/build.yml: $new"
done <<'EOF'
model|--model claude-fable-5-2|--model claude-opus-5-5
effort|--effort medium|--effort high
turn limit|--max-turns 40|--max-turns 400
timeout|timeout-minutes: 20|timeout-minutes: 360
EOF

scenario "holds a timeout that was only taken away"
in_workflow "    timeout-minutes: 20
" ""
decides
expect_held "spend or limits: factory/workflows/build.yml: timeout-minutes: 20"

scenario "holds a new entry in the record of the free plans' limits"
change factory/free-tier/300.md "" "### #300. Previews are kept for a week"
decides
expect_held "spend or limits: factory/free-tier/300.md"

scenario "holds a change to the free plans' limits themselves"
change factory/free-tier.md "2,000 minutes a month" "3,000 minutes a month"
decides
expect_held "spend or limits: factory/free-tier.md"

scenario "holds a change to how many tickets may be built at once, or wait for the owner, as main's in-flight.sh writes them"
for limit in building_limit=3 owner_limit=5; do
  grep -qxF "$limit" "$scripts/in-flight.sh" || fail "in-flight.sh no longer holds $limit on a line that names the word limit, so a change to it would not be held"
  change factory/scripts/in-flight.sh "$limit" "${limit}0"
  decides
  expect_status 1
  expect_output "spend or limits: factory/scripts/in-flight.sh: ${limit}0"
done

scenario "lets through another change to in-flight.sh"
change factory/scripts/in-flight.sh 'die() { echo "$1" >&2; exit 1; }' 'die() { echo "in-flight.sh: $1" >&2; exit 1; }'
decides
expect_unheld

# Secrets or permissions.
scenario "holds a changed permission, though the hunk does not show the block it is in"
in_workflow "      actions: write" "      actions: read"
decides
! grep -q '^ *permissions:' "$T/diff" || fail "the test's hunk shows \`permissions:\`, so it does not prove a line alone is enough"
expect_held "secrets or permissions: factory/workflows/build.yml: actions: write
secrets or permissions: factory/workflows/build.yml: actions: read"

scenario "holds a new permission, and a block of them"
in_workflow "    steps:" "      id-token: write
    steps:"
decides
expect_held "secrets or permissions: factory/workflows/build.yml: id-token: write"

while IFS='|' read -r what old new; do
  scenario "holds $what, as secrets or permissions"
  in_workflow "$old" "$new"
  decides
  expect_status 1
  expect_output "secrets or permissions: factory/workflows/build.yml: $new"
done <<'EOF'
a step given a secret|GH_TOKEN: ${{ github.token }}|GH_TOKEN: ${{ secrets.BOARD_TOKEN }}
a step given a secret by its name in brackets|GH_TOKEN: ${{ github.token }}|GH_TOKEN: ${{ secrets['BOARD_TOKEN'] }}
a step given every secret|GH_TOKEN: ${{ github.token }}|ALL: ${{ toJSON(secrets) }}
a called workflow given every secret|allowed_bots: claude|secrets: inherit
the tools an agent may use|--allowedTools "Read,Glob,Grep"|--allowedTools "Read,Glob,Grep,Bash"
the bots that may start an agent|allowed_bots: claude|allowed_bots: "*"
an agent's settings|allowed_bots: claude|settings: '{"permissions":{"allow":["Bash"]}}'
a permission the action is given|allowed_bots: claude|additional_permissions: >
a server of tools|--allowedTools "Read,Glob,Grep"|--mcp-config tools.json
EOF

for script in agent-token board-token database-key workflow-app preview-access vercel board signing-key; do
  scenario "holds a change to the setup script $script.sh, which makes, stores or is run with a credential"
  change ".claude/skills/bootstrap/scripts/$script.sh" "echo one" "echo two"
  decides
  expect_held "secrets or permissions: .claude/skills/bootstrap/scripts/$script.sh"
done

scenario "holds a change to the tools a fix round's agent may use, as main's begin-fix-round.sh writes them"
[ "$(grep -c '^ *tools="' "$scripts/begin-fix-round.sh")" -ge 2 ] && grep -q -- '--allowedTools "\${{ steps.round.outputs.tools }}"' "$root/factory/workflows/fix.yml" \
  || fail "begin-fix-round.sh no longer sets the tools fix.yml allows on lines that name them, so a change to them would not be held"
change factory/scripts/begin-fix-round.sh 'tools="Read,Glob,Grep"' 'tools="Read,Glob,Grep,Bash"'
decides
expect_held 'secrets or permissions: factory/scripts/begin-fix-round.sh: tools="Read,Glob,Grep"
secrets or permissions: factory/scripts/begin-fix-round.sh: tools="Read,Glob,Grep,Bash"'

scenario "lets through another change to begin-fix-round.sh"
change factory/scripts/begin-fix-round.sh 'name=Fred' 'name=Freda'
decides
expect_unheld

scenario "holds a change to apply-setup.sh, which hands a merged script its credential"
change factory/scripts/apply-setup.sh "echo one" "echo two"
decides
expect_held "secrets or permissions: factory/scripts/apply-setup.sh"

scenario "holds a change to the tools every session is allowed"
change .claude/settings.json '{}' '{"permissions":{"allow":["Bash"]}}'
decides
expect_held "secrets or permissions: .claude/settings.json"

scenario "holds a workflow that only changes its name, and so keeps every permission and secret"
change factory/workflows/build.yml "$workflow" "$workflow"
( cd "$T/repo" && git mv factory/workflows/build.yml factory/workflows/other.yml && git diff --cached -M ) > "$T/diff"
grep -q '^rename to' "$T/diff" || fail "the test's diff is not a rename"
decides
expect_held "secrets or permissions: factory/workflows/build.yml
secrets or permissions: factory/workflows/other.yml"

scenario "holds a new workflow, for its permissions, its secret and what it may spend"
change factory/workflows/build.yml "" "$workflow"
decides
expect_status 1
expect_output "spend or limits: factory/workflows/build.yml: timeout-minutes: 20"
expect_output "secrets or permissions: factory/workflows/build.yml: permissions:"
expect_output 'secrets or permissions: factory/workflows/build.yml: claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}'

# This rule.
for path in factory/scripts/owner-decides.sh factory/scripts/protected-paths.sh factory/scripts/merge-gate.sh \
    factory/scripts/approve-merge.sh factory/workflows/install-workflows.yml factory/workflows/approve-merge.yml \
    .github/workflows/ci.yml; do
  scenario "holds any change to $path, as this rule"
  change "$path" "one" "two"
  decides
  expect_held "this rule: $path"
done

scenario "holds a deleted script of this rule"
change factory/scripts/merge-gate.sh "one" ""
decides
expect_held "this rule: factory/scripts/merge-gate.sh"

scenario "holds a script of this rule whose mode alone changed"
change factory/scripts/merge-gate.sh "one" "one"
( cd "$T/repo" && chmod +x factory/scripts/merge-gate.sh && git add -A && git diff --cached ) > "$T/diff"
grep -q '^new mode' "$T/diff" || fail "the test's diff is not a change of mode"
decides
expect_held "this rule: factory/scripts/merge-gate.sh"

scenario "holds a job made to run a branch's copy of the rules"
in_workflow "          ref: main" "          ref: \${{ github.head_ref }}"
decides
expect_held "this rule: factory/workflows/build.yml: ref: main
this rule: factory/workflows/build.yml: ref: \${{ github.head_ref }}"

scenario "holds a workflow line that names the owner or the gate"
in_workflow '        run: factory/scripts/say.sh "$PR"' '        run: factory/scripts/merge-gate.sh "$PR" "$HEAD_SHA" someone-else'
decides
expect_status 1
expect_output 'this rule: factory/workflows/build.yml: run: factory/scripts/merge-gate.sh "$PR" "$HEAD_SHA" someone-else'

scenario "holds the merge job no longer asking for a review, in its condition or in the jobs it waits for"
merge='jobs:
  merge:
    needs: [checks, adam, ryan]
    if: >-
      !cancelled() && needs.checks.result == '"'success'"' &&
      needs.adam.result == '"'success'"' && needs.ryan.result == '"'success'"' &&
      github.event.pull_request.user.login == '"'claude[bot]'"'
    runs-on: ubuntu-latest'
replace_first "$merge" "      needs.adam.result == 'success' && needs.ryan.result == 'success' &&" "      needs.ryan.result == 'success' &&"
change factory/workflows/ci.yml "$merge" "$replaced"
decides
expect_held "this rule: factory/workflows/ci.yml: needs.adam.result == 'success' && needs.ryan.result == 'success' &&
this rule: factory/workflows/ci.yml: needs.ryan.result == 'success' &&"
replace_first "$merge" "    needs: [checks, adam, ryan]" "    needs: [checks, ryan]"
change factory/workflows/ci.yml "$merge" "$replaced"
decides
expect_held "this rule: factory/workflows/ci.yml: needs: [checks, adam, ryan]
this rule: factory/workflows/ci.yml: needs: [checks, ryan]"

scenario "holds a change to whose pull requests a job acts on"
replace_first "$merge" "user.login == 'claude[bot]'" "user.login != ''"
change factory/workflows/ci.yml "$merge" "$replaced"
decides
expect_held "this rule: factory/workflows/ci.yml: github.event.pull_request.user.login == 'claude[bot]'
this rule: factory/workflows/ci.yml: github.event.pull_request.user.login != ''"

# What merges with no approval.
scenario "lets through a workflow step that is given only the workflow's own token"
in_workflow '        run: factory/scripts/say.sh "$PR"' '        run: factory/scripts/say.sh "$PR"
      - name: Say it twice
        if: failure()
        env:
          GH_TOKEN: ${{ github.token }}
        run: factory/scripts/say.sh "$PR" again'
decides
expect_unheld

while IFS='|' read -r path; do
  scenario "lets through a change to $path"
  change "$path" "one" "two"
  decides
  expect_unheld
done <<'EOF'
factory/scripts/ship.sh
factory/tests/merge-gate.test.sh
factory/decisions/300.md
factory/README.md
.claude/skills/implement/SKILL.md
.claude/skills/bootstrap/scripts/labels.sh
.claude/skills/bootstrap/templates/CLAUDE.md
.github/PULL_REQUEST_TEMPLATE.md
apps/web/src/app/page.tsx
apps/web/e2e/test.tsx
apps/web/e2e/acceptance/12-export-forecast-csv.spec.ts
docs/TASTE.md
CLAUDE.md.bak
PURPOSE.md
docs/factory/workflows/build.yml
EOF

# The product's bar and CLAUDE.md, as CLAUDE.md ("Off limits") lists them.
while IFS='|' read -r kind path; do
  scenario "holds any change to $path, as $kind"
  change "$path" "one" "two"
  decides
  expect_held "$kind: $path"
done <<'EOF'
the product's bar|TASTE.md
the product's bar|DESIGN.md
the product's bar|apps/web/src/app/globals.css
the product's bar|apps/web/components.json
the product's bar|eslint.config.mjs
the product's bar|apps/web/eslint.config.mjs
the product's bar|tsconfig.json
the product's bar|apps/web/tsconfig.build.json
the product's bar|apps/web/vitest.config.ts
the product's bar|apps/web/playwright.config.ts
the product's bar|apps/web/e2e/test.ts
the agents' instructions|CLAUDE.md
EOF

scenario "holds the theme moved to another name, and a new file of the bar"
rm -rf "$T/repo"; git init --quiet "$T/repo"
(
  cd "$T/repo" || exit 1
  mkdir -p apps/web/src/app
  printf 'one\ntwo\nthree\n' > apps/web/src/app/globals.css; git add -A; git commit --quiet -m "before"
  git mv apps/web/src/app/globals.css apps/web/src/app/theme.css; echo "{}" > tsconfig.json; git add -A
  git diff --cached -M
) > "$T/diff"
decides
expect_held "the product's bar: apps/web/src/app/globals.css
the product's bar: tsconfig.json"

scenario "lets through another script that names a model, a timeout, a token, tools and the jobs a job needs"
change factory/scripts/ticket-cost.sh "echo cost" 'echo "claude-fable-5-2, timeout 20, GH_TOKEN, secrets, permissions: write, tools=Bash, needs: [adam]"'
decides
expect_unheld

scenario "passes a diff that changes nothing"
: > "$T/diff"
decides
expect_unheld

scenario "holds one of each kind in one diff, each said once"
in_workflow "timeout-minutes: 20" "timeout-minutes: 30"
cp "$T/diff" "$T/first"
change factory/scripts/merge-gate.sh "one" "two"
cat "$T/diff" >> "$T/first"
change .claude/skills/bootstrap/scripts/board-token.sh "one" "two"
cat "$T/first" "$T/diff" > "$T/all"; mv "$T/all" "$T/diff"
decides
expect_held "spend or limits: factory/workflows/build.yml: timeout-minutes: 20
spend or limits: factory/workflows/build.yml: timeout-minutes: 30
this rule: factory/scripts/merge-gate.sh
secrets or permissions: .claude/skills/bootstrap/scripts/board-token.sh"

# A diff is read as git wrote it, whatever its lines hold.
scenario "holds a permission changed below a new line written to look like the header of another file"
in_workflow "      actions: write
    steps:" "      actions: write
      id-token: write
    steps:"
sed 's|^+      id-token: write$|+++ b/README.md\n+      id-token: write|' "$T/diff" | sed 's|^\(@@ -[0-9,]* +[0-9]*,\)7 @@|\18 @@|' > "$T/new"
mv "$T/new" "$T/diff"
grep -q '^+++ b/README.md$' "$T/diff" && grep -q ',8 @@' "$T/diff" || fail "the test's diff does not hold the disguised line"
decides
expect_held "secrets or permissions: factory/workflows/build.yml: id-token: write"

scenario "holds a workflow's change that follows another file's, and not that file's"
change README.md "timeout-minutes: 20" "timeout-minutes: 30"
cp "$T/diff" "$T/first"
in_workflow "timeout-minutes: 20" "timeout-minutes: 30"
cat "$T/first" "$T/diff" > "$T/all"; mv "$T/all" "$T/diff"
decides
expect_held "spend or limits: factory/workflows/build.yml: timeout-minutes: 20
spend or limits: factory/workflows/build.yml: timeout-minutes: 30"

scenario "refuses a diff cut short inside a hunk, with exit 2"
in_workflow "timeout-minutes: 20" "timeout-minutes: 30"
head -n 9 "$T/diff" > "$T/cut"; mv "$T/cut" "$T/diff"
decides
expect_status 2
expect_output "the diff ends inside a hunk"

scenario "refuses a hunk that holds a line no diff has, with exit 2"
in_workflow "timeout-minutes: 20" "timeout-minutes: 30"
sed 's/^ jobs:$/jobs:/' "$T/diff" > "$T/bent"; mv "$T/bent" "$T/diff"
decides
expect_status 2
expect_output "is no line of its hunk"

scenario "refuses a path git had to quote, which no rule would know, with exit 2"
change "factory/workflows/buíld.yml" "$workflow" "${workflow/20/30}"
grep -q '^+++ "b/factory' "$T/diff" || fail "the test's diff does not quote its path"
decides
expect_status 2
expect_output "names a path git had to quote"

scenario "refuses a hunk that belongs to no file, with exit 2"
in_workflow "timeout-minutes: 20" "timeout-minutes: 30"
sed -n '/^@@/,$p' "$T/diff" > "$T/bare"; mv "$T/bare" "$T/diff"
decides
expect_status 2
expect_output "opens a hunk of no file"

# What the rest of the factory relies on.
scenario "the installer runs exactly this script: its source names the git id of the file as it is"
pinned=$(sed -n 's/^  RULE: \([0-9a-f]\{40\}\) .*/\1/p' "$root/factory/workflows/install-workflows.yml")
[ "$pinned" = "$(git -C "$root" hash-object factory/scripts/owner-decides.sh)" ] \
  || fail "install-workflows.yml names ${pinned:-no id}, and owner-decides.sh is $(git -C "$root" hash-object factory/scripts/owner-decides.sh): set RULE to that"
