#!/usr/bin/env bash
# Tests for overtaken.sh: names each workflow source a pull request changes that main has changed since it left.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/overtaking.sh"

github() {
  two_branches
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    if [ -f "$T/answer" ]; then case "$*" in "$(head -n 1 "$T/answer")"*) json "$(tail -n +2 "$T/answer")" "$@"; exit 0 ;; esac; fi
    git_as_github "$@" || { echo "unexpected call: gh $*" >&2; exit 1; }'
}
overtaken() { run env GH_TOKEN=workflow-token "$scripts/overtaken.sh" 7 main "$second"; }
says_nothing() { expect_status 0; [ -z "$out" ] || fail "expected it to print nothing"; }

scenario "names the pull request that changed, on main, a workflow source this one changes"
github; merge_first
overtaken
expect_status 0
[ "$out" = "\`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6 after this pull request's diff of it was made." ] \
  || fail "expected one sentence naming the source and pull request #6"

scenario "says nothing when main has not moved since the pull request left it, and asks nothing more"
github
overtaken
says_nothing
expect_no_call "contents/factory/workflows"

scenario "says nothing when main has changed only other files, another workflow source among them"
github
on_main_commit "feat: something else (#5)" "echo changed > apps/page.tsx; echo 'name: fix it' > factory/workflows/fix.yml"
overtaken
says_nothing
expect_no_call "repos/{owner}/{repo}/commits"

scenario "says nothing once main is merged into the branch"
github; merge_first; merge_main_into_second
overtaken
says_nothing

scenario "says nothing, and asks nothing more, for a pull request that changes no workflow source"
github; merge_first
(cd "$T/repo" && git checkout --quiet -B second main && echo other > apps/page.tsx && git commit --quiet -am "the page" && git checkout --quiet main)
second=$(git -C "$T/repo" rev-parse second)
on_main_commit "ci: change it again (#8)" "echo 'name: ci 3' > factory/workflows/ci.yml"
overtaken
says_nothing
expect_no_call "compare"

scenario "names the commit when what changed the source on main was no pull request"
github
on_main_commit "ci: pushed by hand" "echo 'name: ci by hand' > factory/workflows/ci.yml"
overtaken
expect_output "\`factory/workflows/ci.yml\` on \`main\` was changed by commit $(git -C "$T/repo" rev-parse --short=7 main) after"

scenario "a source main deleted, and one both added, are overtaken"
github
(cd "$T/repo" && git checkout --quiet second && echo 'name: new' > factory/workflows/new.yml && git add . && git commit --quiet -m "a new workflow" && git checkout --quiet main)
second=$(git -C "$T/repo" rev-parse second)
on_main_commit "ci: remove ci and add another new (#9)" "git rm --quiet factory/workflows/ci.yml; echo 'name: other new' > factory/workflows/new.yml"
overtaken
expect_output "\`factory/workflows/ci.yml\` on \`main\` was changed by pull request #9"
expect_output "\`factory/workflows/new.yml\` on \`main\` was changed by pull request #9"

scenario "a renamed source is overtaken under its old name"
github; merge_first
printf 'api repos/{owner}/{repo}/pulls/7/files\n[{"filename":"factory/workflows/checks.yml","previous_filename":"factory/workflows/ci.yml"}]\n' > "$T/answer"
overtaken
expect_output "\`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6"
expect_no_output "checks.yml"

scenario "a source in a folder is overtaken when main changed that folder"
github
(cd "$T/repo" && git checkout --quiet second && mkdir factory/workflows/more && echo 'name: a' > factory/workflows/more/a.yml && git add . && git commit --quiet -m "in a folder" && git checkout --quiet main)
second=$(git -C "$T/repo" rev-parse second)
on_main_commit "ci: the folder (#4)" "mkdir factory/workflows/more; echo 'name: b' > factory/workflows/more/b.yml"
overtaken
expect_output "\`factory/workflows/more\` on \`main\` was changed by pull request #4"

while IFS='|' read -r call why; do
  scenario "stops, and does not read as not overtaken, when GitHub fails: $why"
  github; merge_first
  echo "$call" > "$T/fail"
  overtaken
  expect_status 1
  expect_output "$why"
  expect_output "so whether \`main\` has overtaken a workflow change in pull request #7 is not known."
  expect_no_output "was changed by"
done <<'CALLS'
api repos/{owner}/{repo}/pulls/7/files|GitHub did not list the files pull request #7 changes
api repos/{owner}/{repo}/compare/|GitHub did not say where
api --method GET repos/{owner}/{repo}/contents/factory/workflows|GitHub did not list `factory/workflows` as it was at
api --method GET repos/{owner}/{repo}/commits|GitHub did not say which commit last changed `factory/workflows/ci.yml` on `main`
CALLS

scenario "stops when only the listing of main's folder fails"
github; merge_first
echo "api --method GET repos/{owner}/{repo}/contents/factory/workflows -f ref=$(git -C "$T/repo" rev-parse main)" > "$T/fail"
overtaken
expect_status 1
expect_output "GitHub did not list \`factory/workflows\` as it is on \`main\`"

scenario "stops when GitHub names no commit at which the pull request left main"
github; merge_first
printf 'api repos/{owner}/{repo}/compare/\n{"merge_base_commit":null,"base_commit":null}\n' > "$T/answer"
overtaken
expect_status 1
expect_output "GitHub named no commit at which"
