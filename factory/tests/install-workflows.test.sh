#!/usr/bin/env bash
# Tests for the check in factory/workflows/install-workflows.yml: what it installs approved, unapproved, or not at all.
. "$(dirname "$0")/helpers.sh"

source_file="$root/factory/workflows/install-workflows.yml"
# The step's commands and the id it names, read from the source, so a change there fails here.
step=$(awk '/^      - name: Check that what would be installed/ { found = 1 }
  found && /^        run: \|$/ { on = 1; next }
  on && /^      [^ ]/ { exit }
  on { sub(/^          /, ""); print }' "$source_file")
rule=$(sed -n 's/^  RULE: \([0-9a-f]\{40\}\) .*/\1/p' "$source_file")
owner_approved='[{"author":{"login":"repo-owner"},"state":"APPROVED","commit":{"oid":"HEAD"}}]'

# merged <who merged it> <reviews> <commands that make the change>: main holds pull request #7, squashed, and
# GitHub keeps its last commit. HEAD in the reviews is that commit.
merged() {
  git init --quiet --bare "$T/github.git"
  git init --quiet --initial-branch main .
  mkdir -p factory/workflows factory/scripts .github/workflows
  cp "$scripts/owner-decides.sh" "$scripts/merge-gate.sh" factory/scripts/
  printf 'name: build\njobs:\n  build:\n    timeout-minutes: 20\n    permissions:\n      contents: read\n    steps:\n      - run: make\n' > factory/workflows/build.yml
  cp factory/workflows/build.yml .github/workflows/build.yml
  [ -z "${before:-}" ] || eval "$before"
  git add -A; git commit --quiet -m "base"
  git checkout --quiet -b change
  eval "$3"
  git add -A; git commit --quiet -m "change"
  local head; head=$(git rev-parse HEAD)
  git push --quiet "$T/github.git" "HEAD:refs/pull/7/head"
  git checkout --quiet main
  git merge --quiet --squash change >/dev/null; git commit --quiet -m "feat: build it (#7)"
  git config "url.$T/github.git.insteadOf" "https://x-access-token:workflow-token@github.com/owner/myapp.git"
  jq -n --arg login "$1" --arg head "$head" --argjson reviews "${2//HEAD/$head}" \
    '{state: "MERGED", baseRefName: "main", headRefOid: $head, mergedBy: {login: $login}, reviews: $reviews}' > "$T/view.json"
  stub gh 'case "$*" in
    "pr view 7 --json state,baseRefName,headRefOid,mergedBy,reviews") cat "$T/view.json" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
check() {
  : > "$T/output"
  run env GH_TOKEN=workflow-token PR=7 DEFAULT_BRANCH=main OWNER=repo-owner RULE="$rule" GITHUB_REPOSITORY=owner/myapp \
    RUNNER_TEMP="$T/tmp" GITHUB_OUTPUT="$T/output" bash -c "$step"
}
expect_installed() {
  expect_status 0
  expect_output "installed factory/workflows/build.yml as .github/workflows/build.yml"
  grep -qx 'install=true' "$T/output" || fail "expected the step to say there is something to commit"
  [ "$(git rev-parse :.github/workflows/build.yml)" = "$(git rev-parse HEAD:factory/workflows/build.yml)" ] \
    || fail "expected the installed copy, as staged, to be the source main holds"
}
expect_refused() {
  expect_status 1
  [[ "$(cat "$T/tmp/refused.md")" == *"$1"* ]] || fail "expected the refusal to say: $1
    it said: $(cat "$T/tmp/refused.md")"
  git diff --cached --quiet || fail "expected nothing to be staged for the installed copies"
  ! grep -q 'install=true' "$T/output" || fail "expected the step not to say there is something to commit"
}
a_step='echo "      - run: make test" >> factory/workflows/build.yml'
unapproved="\`repo-owner\` neither approved commit"

scenario "the step is found in the source, and so is the id it names"
[ -n "$step" ] || fail "no step named \"Check that what would be installed\" with a run block was found in install-workflows.yml"
[ -n "$rule" ] || fail "no RULE with a git id was found in install-workflows.yml"

scenario "installs a workflow change nobody approved, when the merge gate merged it and it holds nothing of the owner's"
merged app/github-actions '[]' "$a_step; echo two > factory/scripts/merge-gate.test.sh"
check
expect_installed

while IFS='|' read -r kind change expected; do
  scenario "refuses an unapproved change to $kind, and installs nothing"
  merged app/github-actions '[]' "$change"
  check
  expect_refused "$unapproved"
  expect_refused "it changes what only they may decide:"
  expect_refused "$expected"
done <<'EOF'
spend or limits|sed -i.bak 's/minutes: 20/minutes: 360/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak|spend or limits: factory/workflows/build.yml: timeout-minutes: 360
secrets or permissions|sed -i.bak 's/contents: read/contents: write/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak|secrets or permissions: factory/workflows/build.yml: contents: write
this rule, in a file that is no workflow|echo "      - run: make test" >> factory/workflows/build.yml; echo "exit 0" >> factory/scripts/merge-gate.sh|this rule: factory/scripts/merge-gate.sh
EOF

scenario "installs a change to what only the owner decides, once the owner approved its last commit"
merged app/github-actions "$owner_approved" "sed -i.bak 's/contents: read/contents: write/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
check
expect_installed

scenario "installs one the owner merged themselves"
merged repo-owner '[]' "sed -i.bak 's/minutes: 20/minutes: 360/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
check
expect_installed

scenario "refuses a change to what only the owner decides that they approved at an older commit"
merged app/github-actions '[{"author":{"login":"repo-owner"},"state":"APPROVED","commit":{"oid":"0000000000000000000000000000000000000001"}}]' \
  "sed -i.bak 's/minutes: 20/minutes: 360/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
check
expect_refused "it changes what only they may decide:"

scenario "refuses an unapproved change that something other than the merge gate merged, whatever it holds"
merged app/claude '[]' "$a_step"
check
expect_refused "$unapproved"
expect_refused "it was not the merge gate that merged it."

scenario "refuses an unapproved change when main's owner-decides.sh is not the one the installer names"
before='echo "exit 0" >> factory/scripts/owner-decides.sh' merged app/github-actions '[]' "$a_step"
check
expect_refused "\`factory/scripts/owner-decides.sh\` on \`main\` is not the script this installer names"

scenario "installs an approved change though main's owner-decides.sh is not the one the installer names"
before='echo "exit 0" >> factory/scripts/owner-decides.sh' merged app/github-actions "$owner_approved" "$a_step"
check
expect_installed

scenario "gives the script no token and nothing else of the environment"
merged app/github-actions '[]' "$a_step"
# Stands in for the script under the id the installer names: git stores whatever is written under that name.
spy=$(printf '#!/usr/bin/env bash\ncat > /dev/null\nenv\nexit 1\n' | git hash-object -w --stdin)
git update-index --add --cacheinfo "100755,$spy,factory/scripts/owner-decides.sh"; git commit --quiet -m "a script that prints what it was given"
rule="$spy" check
rule=$(sed -n 's/^  RULE: \([0-9a-f]\{40\}\) .*/\1/p' "$source_file")
expect_status 1
grep -q 'PATH=' "$T/tmp/refused.md" || fail "expected the stand-in script to have run and printed its environment"
! grep -qE 'GH_TOKEN|workflow-token|RUNNER_TEMP' "$T/tmp/refused.md" || fail "expected the script to be given no token and no variable of the step"
