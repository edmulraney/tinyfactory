#!/usr/bin/env bash
# Tests for install-workflows.yml: what its check installs, approved or not, and how one run starts the next.
. "$(dirname "$0")/helpers.sh"

source_file="$root/factory/workflows/install-workflows.yml"
# The commands of a step and the id it names, read from the source, so a change there fails here.
commands_of() {
  awk -v name="      - name: $1" 'index($0, name) == 1 { found = 1 }
    found && /^        run: \|$/ { on = 1; next }
    on && /^      [^ ]/ { exit }
    on { sub(/^          /, ""); print }' "$source_file"
}
step=$(commands_of "Check that what would be installed")
start_next=$(commands_of "Start the installer for the pull request merged after this one")
rule=$(sed -n 's/^  RULE: \([0-9a-f]\{40\}\) .*/\1/p' "$source_file")
carry=$(sed -n 's/^  CARRY: \([0-9a-f]\{40\}\) .*/\1/p' "$source_file")
owner_approved='[{"author":{"login":"repo-owner"},"state":"APPROVED","commit":{"oid":"HEAD"}}]'

# merged <who merged it> <reviews> <commands that make the change>: main holds pull request #7, squashed, and
# GitHub keeps its last commit. HEAD in the reviews is that commit, and EARLIER the one tagged so. $before changes the commit the branch leaves,
# and $meanwhile changes main after the branch left it.
merged() {
  git init --quiet --bare "$T/github.git"
  git init --quiet --initial-branch main .
  mkdir -p factory/workflows factory/scripts .github/workflows
  cp "$scripts/owner-decides.sh" "$scripts/merge-gate.sh" "$scripts/only-merged-main.sh" factory/scripts/
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
  [ -z "${meanwhile:-}" ] || { eval "$meanwhile"; git add -A; git commit --quiet -m "meanwhile"; }
  git merge --quiet --squash change >/dev/null 2>&1; git commit --quiet -m "feat: build it (#7)"
  git config "url.$T/github.git.insteadOf" "https://x-access-token:workflow-token@github.com/owner/myapp.git"
  local reviews="${2//HEAD/$head}"
  jq -n --arg login "$1" --arg head "$head" --argjson reviews "${reviews//EARLIER/$(git rev-parse --quiet --verify refs/tags/earlier || true)}" \
    --arg merge "$(git rev-parse HEAD)" \
    '{state: "MERGED", baseRefName: "main", headRefOid: $head, mergeCommit: {oid: $merge}, mergedBy: {login: $login}, reviews: $reviews}' > "$T/view.json"
  stub gh 'case "$*" in
    "pr view 7 --json state,baseRefName,headRefOid,mergeCommit,mergedBy,reviews") cat "$T/view.json" ;;
    "pr view 8 --json state,baseRefName,headRefOid,mergeCommit,mergedBy,reviews") cat "$T/view-8.json" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
# merged_next <commands that make the change>: pull request #8 left main where #7 did, and the owner merged it after #7.
merged_next() {
  git checkout --quiet -b next "$(git merge-base main change)"
  eval "$1"
  git add -A; git commit --quiet -m "the next change"
  git push --quiet "$T/github.git" "HEAD:refs/pull/8/head"
  git checkout --quiet main
  git merge --quiet --squash next >/dev/null 2>&1; git commit --quiet -m "feat: build it another way (#8)"
  jq --arg head "$(git rev-parse next)" --arg merge "$(git rev-parse HEAD)" '.headRefOid = $head | .mergeCommit.oid = $merge' "$T/view.json" > "$T/view-8.json"
}
# check [<pr>]: the step, for pull request #7 unless another is named.
check() {
  : > "$T/output"
  run env GH_TOKEN=workflow-token PR="${1:-7}" DEFAULT_BRANCH=main OWNER=repo-owner RULE="$rule" CARRY="$carry" GITHUB_REPOSITORY=owner/myapp \
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
expect_nothing_staged() {
  git diff --cached --quiet || fail "expected nothing to be staged for the installed copies"
  ! grep -q 'install=true' "$T/output" || fail "expected the step not to say there is something to commit"
}
a_step='echo "      - run: make test" >> factory/workflows/build.yml'
unapproved="\`repo-owner\` neither approved commit"

scenario "the step is found in the source, and so is the id it names"
[ -n "$step" ] || fail "no step named \"Check that what would be installed\" with a run block was found in install-workflows.yml"
[ -n "$start_next" ] || fail "no step named \"Start the installer for the pull request merged after this one\" with a run block was found in install-workflows.yml"
[ -n "$rule" ] || fail "no RULE with a git id was found in install-workflows.yml"
[ -n "$carry" ] || fail "no CARRY with a git id was found in install-workflows.yml"

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

# The owner approved the commit tagged earlier; main moved, and the pull request's last commit merges it.
owner_approved_earlier='[{"author":{"login":"repo-owner"},"state":"APPROVED","commit":{"oid":"EARLIER"}}]'
a_limit="sed -i.bak 's/minutes: 20/minutes: 360/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
approved_here='git add -A; git commit --quiet -m "approved"; git tag earlier'
main_moves='git checkout --quiet main; echo moved > moved.txt; git add -A; git commit --quiet -m "main moves"; git checkout --quiet change'
merge_main='git merge --quiet --no-ff --no-commit main >/dev/null 2>&1'

scenario "installs a change to what only the owner decides that they approved before a commit that only merges main"
merged app/github-actions "$owner_approved_earlier" "$a_limit; $approved_here; $main_moves; $merge_main"
check
[ "$(git rev-list --parents -n 1 FETCH_HEAD | wc -w)" -eq 3 ] || fail "the scenario did not make a merge commit"
expect_installed

scenario "refuses one they approved before a commit that changes something else"
merged app/github-actions "$owner_approved_earlier" "$a_limit; $approved_here; echo more > more.txt"
check
expect_refused "it changes what only they may decide:"
expect_output "pushed since $(git rev-parse --short=7 earlier), is not a merge of main"

scenario "refuses one they approved before a merge of main that also changed a workflow by hand"
merged app/github-actions "$owner_approved_earlier" "$a_limit; $approved_here; $main_moves; $merge_main; sed -i.bak 's/contents: read/contents: write/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
check
expect_refused "secrets or permissions: factory/workflows/build.yml: contents: write"
expect_output "its change does not read the same"

scenario "refuses one they approved before a merge of main, then sent back"
merged app/github-actions '[{"author":{"login":"repo-owner"},"state":"APPROVED","commit":{"oid":"EARLIER"}},{"author":{"login":"repo-owner"},"state":"CHANGES_REQUESTED","commit":{"oid":"EARLIER"}}]' \
  "$a_limit; $approved_here; $main_moves; $merge_main"
check
expect_refused "it changes what only they may decide:"

scenario "carries no approval when main's only-merged-main.sh is not the one the installer names"
before='echo "exit 0" >> factory/scripts/only-merged-main.sh' merged app/github-actions "$owner_approved_earlier" "$a_limit; $approved_here; echo more > more.txt"
check
expect_refused "it changes what only they may decide:"
expect_output "factory/scripts/only-merged-main.sh on main is not the script this installer names"

scenario "gives the script that compares the commits no token and nothing else of the environment"
merged app/github-actions "$owner_approved_earlier" "$a_limit; $approved_here; $main_moves; $merge_main"
spy=$(printf '#!/usr/bin/env bash\nenv\nexit 1\n' | git hash-object -w --stdin)
git update-index --add --cacheinfo "100755,$spy,factory/scripts/only-merged-main.sh"; git commit --quiet -m "a script that prints what it was given"
carry="$spy" check
carry=$(sed -n 's/^  CARRY: \([0-9a-f]\{40\}\) .*/\1/p' "$source_file")
expect_refused "it changes what only they may decide:"
expect_output "PATH="
[[ "$out" != *GH_TOKEN* && "$out" != *workflow-token* && "$out" != *RUNNER_TEMP* ]] || fail "expected the script to be given no token and no variable of the step"

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

# Another pull request's change to the first line of the same source, which git joins with $a_step's last line.
renamed() { sed -i.bak 's/^name: build$/name: build it/' "$1"; rm "$1.bak"; }

scenario "installs main's source when another change to it merged and was installed after the branch left main"
meanwhile='renamed factory/workflows/build.yml; renamed .github/workflows/build.yml' merged repo-owner '[]' "$a_step"
check
expect_installed
[ "$(git show :.github/workflows/build.yml | sed -n '1p;$p' | xargs)" = "name: build it - run: make test" ] \
  || fail "expected the installed copy to hold the earlier change and the reviewed one"

scenario "refuses a source main changed after the branch left it, when that change is not installed"
meanwhile='renamed factory/workflows/build.yml' merged repo-owner '[]' "$a_step"
check
expect_refused "is neither what commit"

scenario "refuses a source main changed after the branch left it, when the reviewed change does not apply to the installed copy"
meanwhile='renamed factory/workflows/build.yml; echo "      - run: make lint" >> .github/workflows/build.yml' merged repo-owner '[]' "$a_step"
check
expect_refused "is neither what commit"

# What the "Commit the copies" step does with what the check staged.
commit_copies() { git commit --quiet -m "ci: install the workflow changes merged in #$1"; }
installed_copy() { git rev-parse :.github/workflows/build.yml; }

scenario "installs two changes to different lines of one source, each as its merge left main, in the order they merged"
merged repo-owner '[]' "$a_step"
merged_next 'renamed factory/workflows/build.yml'
check
expect_status 0
[ "$(installed_copy)" = "$(git rev-parse HEAD^:factory/workflows/build.yml)" ] \
  || fail "expected the installed copy, as staged, to be the source the merge of #7 left, without the change of #8"
commit_copies 7
check 8
expect_installed
commit_copies 8
# As git holds them: the step stages the copies and writes no file.
[ "$(git rev-parse HEAD:.github/workflows)" = "$(git rev-parse HEAD:factory/workflows)" ] || fail "expected the installed copies to equal the sources on main"
[ "$(git show HEAD:.github/workflows/build.yml | sed -n '1p;$p' | xargs)" = "name: build it - run: make test" ] \
  || fail "expected the installed copy to hold both changes"

scenario "refuses the later of two changes to one source while the earlier is not installed"
merged repo-owner '[]' "$a_step"
merged_next 'renamed factory/workflows/build.yml'
check 8
expect_refused "\`factory/workflows/build.yml\` on \`main\`, as this pull request's merge \`$(git rev-parse --short=7 HEAD)\` left it, is neither what commit"

scenario "installs the source its merge left, and not a change pushed straight to main since"
merged repo-owner '[]' "$a_step"
echo "      - run: curl evil.example" >> factory/workflows/build.yml; git commit --quiet -am "pushed straight to main"
check
expect_status 0
[ "$(installed_copy)" = "$(git rev-parse HEAD^:factory/workflows/build.yml)" ] \
  || fail "expected the installed copy, as staged, to be the source the merge of #7 left"
! git show :.github/workflows/build.yml | grep -q evil || fail "expected the change no pull request made not to be installed"

scenario "refuses a source that holds a change no reviewed pull request made, pushed to main between two merges"
merged repo-owner '[]' "$a_step"
echo "      - run: curl evil.example" >> factory/workflows/build.yml; git commit --quiet -am "pushed straight to main"
merged_next 'renamed factory/workflows/build.yml'
check
expect_status 0
commit_copies 7
check 8
expect_refused "so it holds a change that was not reviewed in this pull request, or one not installed yet."

scenario "installs nothing for a pull request never installed, once a later merge put its source back to the installed copy"
merged repo-owner '[]' "$a_step"
git show change^:factory/workflows/build.yml > factory/workflows/build.yml
git commit --quiet -am "fix: undo it (#9)"
check
expect_status 0
expect_output ".github/workflows/build.yml is already what factory/workflows/build.yml on main holds, so nothing waits to be installed"
expect_nothing_staged

# What the "Commit the copies" step does for #7, then #9 undoes the change of #7 and is installed.
installed_then_undone() {
  merged repo-owner '[]' "$a_step"
  check
  expect_installed
  commit_copies 7
  # The step stages the copies and writes no file, so the undoing writes both.
  git show change^:factory/workflows/build.yml | tee factory/workflows/build.yml > .github/workflows/build.yml
  git add -A; git commit --quiet -m "fix: undo it (#9)"
}

scenario "installs nothing when the installer of an installed pull request starts again after a later merge undid its change"
installed_then_undone
install=$(git rev-parse --short HEAD^)
check
expect_status 0
expect_output "commit $install on main already installed the workflow changes of pull request #7, so nothing is installed for it again"
expect_nothing_staged

scenario "installs nothing for it again while a third change to the same source is merged and not installed, and that change is installed by its own run"
installed_then_undone
install=$(git rev-parse --short HEAD^)
merged_next 'renamed factory/workflows/build.yml'
check
expect_status 0
expect_output "commit $install on main already installed the workflow changes of pull request #7, so nothing is installed for it again"
expect_nothing_staged
check 8
expect_installed
[ "$(git show :.github/workflows/build.yml | sed -n '1p;$p' | xargs)" = "name: build it - run: make" ] \
  || fail "expected the installed copy to hold the third change and not the one undone"

scenario "installs nothing again for a pull request installed under the installer's older subject, \"approved in\""
merged repo-owner '[]' "$a_step"
git commit --quiet --allow-empty -m "ci: install the workflow changes approved in #7"
install=$(git rev-parse --short HEAD)
check
expect_status 0
expect_output "commit $install on main already installed the workflow changes of pull request #7, so nothing is installed for it again"
expect_nothing_staged

scenario "installs a pull request whose number begins another's that is installed"
merged repo-owner '[]' "$a_step"
git commit --quiet --allow-empty -m "ci: install the workflow changes merged in #70"
check
expect_installed

scenario "installs a pull request though a commit made before its merge has the subject of its install"
before='git commit --quiet --allow-empty -m "ci: install the workflow changes merged in #7"' merged repo-owner '[]' "$a_step"
check
expect_installed

scenario "stops when the merge commit GitHub names is not on main"
merged repo-owner '[]' "$a_step"
jq --arg other "$(git rev-parse change)" '.mergeCommit.oid = $other' "$T/view.json" > "$T/view.new" && mv "$T/view.new" "$T/view.json"
check
expect_status 1
expect_output "is not on main, so what its merge left there is not known"
git diff --cached --quiet || fail "expected nothing to be staged for the installed copies"

scenario "refuses a source that is a link"
merged repo-owner '[]' 'ln -s ../scripts/merge-gate.sh factory/workflows/link.yml'
check
expect_refused "\`factory/workflows/link.yml\` is not an ordinary file"

scenario "removes the installed copy of a source the change deleted"
merged repo-owner '[]' 'git rm --quiet factory/workflows/build.yml'
check
expect_status 0
expect_output "removed .github/workflows/build.yml"
[ "$(git diff --cached --name-status | xargs)" = "D .github/workflows/build.yml" ] || fail "expected only the removal to be staged"

# The owner merged pull request #5 with GitHub's merge button, which raised a time limit, and main then failed. A
# workflow filed ticket #12 to take it back, and the merge gate merged #7, which puts the limit back (decisions M439f).
# taken_back [<who merged #5>]: $installed says that #5's change was installed, $later changes main after it, and
# $take_back is what #7 does instead.
raise="sed -i.bak 's/minutes: 20/minutes: 360/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
lower="sed -i.bak 's/minutes: 360/minutes: 20/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak"
taken_back() {
  # The install is a commit of its own, as the installer makes it; with none, another commit follows the merge.
  before="git add -A; git commit --quiet -m 'before the button'; $raise; git commit --quiet -am 'feat: wait longer (#5)'; git tag button
    ${installed:+cp factory/workflows/build.yml .github/workflows/build.yml;} echo later > later.txt; ${later:-}" \
    merged app/github-actions '[]' "${take_back:-$lower}"
  jq -n --arg by "${1:-repo-owner}" --arg commit "$(git rev-parse button)" '{mergedBy: {login: $by}, mergeCommit: {oid: $commit}}' > "$T/taken.json"
  echo '{"title":"Take back the button merge of pull request #5","author":{"login":"app/github-actions"}}' > "$T/ticket.json"
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr view 7 --json state,baseRefName,headRefOid,mergeCommit,mergedBy,reviews") cat "$T/view.json" ;;
      "pr view 7 --json body "*) json "{\"body\":\"Closes #12\"}" "$@" ;;
      "issue view 12 --json title,author") cat "$T/ticket.json" ;;
      "pr view 5 --json mergedBy,mergeCommit") cat "$T/taken.json" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "installs, unapproved, a take-back of a merge the owner made with the button, though it changes what only they decide"
installed=yes taken_back
check
expect_installed
git show :.github/workflows/build.yml | grep -qx '    timeout-minutes: 20' || fail "expected the installed copy to hold the limit from before the button"

scenario "refuses nothing of such a take-back when the change it takes back was never installed: the copies already match"
taken_back
check
expect_status 0
expect_output ".github/workflows/build.yml is already what was approved"
expect_output "pull request #7 has no workflow change left to install"
[ ! -s "$T/tmp/refused.md" ] || fail "expected no refusal, got: $(cat "$T/tmp/refused.md")"

for title in "Wait less for the build" "Take back pull request #5"; do
  scenario "refuses the same change when its ticket is \"$title\": it takes back nothing, or the owner started it"
  installed=yes taken_back
  jq --arg title "$title" '.title = $title' "$T/ticket.json" > "$T/ticket.new" && mv "$T/ticket.new" "$T/ticket.json"
  check
  expect_refused "it changes what only they may decide:"
done

scenario "refuses it when no workflow filed the ticket"
installed=yes taken_back
echo '{"title":"Take back the button merge of pull request #5","author":{"login":"app/claude"}}' > "$T/ticket.json"
check
expect_refused "it changes what only they may decide:"

scenario "refuses it when the owner did not merge the pull request it takes back"
installed=yes taken_back app/github-actions
check
expect_refused "it changes what only they may decide:"

scenario "refuses it when it changes a file the merge with the button did not"
installed=yes take_back="$lower; echo 'exit 0' >> factory/scripts/merge-gate.sh" taken_back
check
expect_refused "this rule: factory/scripts/merge-gate.sh"

scenario "refuses it when it leaves a file other than as main held it before the button"
installed=yes take_back="sed -i.bak 's/minutes: 360/minutes: 30/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak" taken_back
check
expect_refused "spend or limits: factory/workflows/build.yml: timeout-minutes: 30"

scenario "refuses it when the merge with the button changed a file it leaves as it is"
installed=yes taken_back
git checkout --quiet --detach button
echo "exit 0" >> factory/scripts/merge-gate.sh
git commit --quiet --amend -am "the button's merge, with one more file"
jq --arg commit "$(git rev-parse HEAD)" '.mergeCommit.oid = $commit' "$T/taken.json" > "$T/taken.new" && mv "$T/taken.new" "$T/taken.json"
git checkout --quiet main
check
expect_refused "it changes what only they may decide:"

scenario "refuses it when a later merge changed the file, which going back would undo too"
later="sed -i.bak 's/minutes: 360/minutes: 90/' factory/workflows/build.yml .github/workflows/build.yml; rm factory/workflows/*.bak .github/workflows/*.bak" \
  installed=yes take_back="sed -i.bak 's/minutes: 90/minutes: 20/' factory/workflows/build.yml; rm factory/workflows/build.yml.bak" taken_back
check
expect_refused "spend or limits: factory/workflows/build.yml: timeout-minutes: 90"

for words in "pr view 7 --json body" "issue view 12 --json title,author" "pr view 5 --json mergedBy,mergeCommit"; do
  scenario "refuses it when GitHub does not answer: $words"
  installed=yes taken_back
  echo "$words" > "$T/fail"
  check
  expect_refused "it changes what only they may decide:"
done

# start_next_with <then>: the step that starts the next run, in the run that installed pull request #7.
start_next_with() {
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"'
  stub sleep ':'
}
next() {
  run env GH_TOKEN=workflow-token GH_REPO=owner/myapp PR=7 THEN="$1" RUNNER_TEMP="$T" GITHUB_SERVER_URL=https://github.example \
    GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID=55 bash -c "$start_next"
}

scenario "a run starts the installer for the pull request merged next, and names those after it"
start_next_with
next "8 9 10"
expect_status 0
expect_calls 1 "gh workflow run install-workflows.yml"
expect_call "gh workflow run install-workflows.yml -f pr=8 -f then=9 10"

scenario "the run before the last of a group names none after it"
start_next_with
next "8"
expect_status 0
[ "$(grep '^gh ' "$T/calls")" = "gh workflow run install-workflows.yml -f pr=8" ] || fail "expected the one call, with no pull request after #8"

scenario "a start GitHub refuses is asked three times, then the next pull request is told how to start it, and the run fails"
start_next_with
echo "workflow run install-workflows.yml" > "$T/fail"
next "8 9"
expect_status 1
expect_calls 3 "gh workflow run install-workflows.yml -f pr=8 -f then=9"
expect_call "gh pr comment 8 --body-file $T/not-started.md"
expect_call "gh pr edit 8 --add-label needs-human"
[ "$(head -1 "$T/not-started.md")" = 'Start the `install-workflows` workflow from the Actions tab, with `pr` set to `8` and `then` to `9`: that run installs the workflow changes this pull request merged.' ] \
  || fail "expected the first line to say what a person must do, got: $(head -1 "$T/not-started.md")"

scenario "the step runs whatever became of the run, and only when a pull request merged after this one"
grep -A1 -F -- "- name: Start the installer for the pull request merged after this one" "$source_file" | grep -qxF "        if: always() && inputs.then != ''" \
  || fail "expected the step to run when the run failed or was cancelled too, and only with a pull request to start"
