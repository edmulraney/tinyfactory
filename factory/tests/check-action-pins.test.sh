#!/usr/bin/env bash
# Tests for factory/scripts/check-action-pins.sh, with zizmor's report and exit code stood in.
. "$(dirname "$0")/helpers.sh"

# finding <ident> <file> <row from 0> <text>: one finding as zizmor's JSON report gives it.
finding() {
  printf '{"ident":"%s","desc":"what %s found","locations":[{"symbolic":{"key":{"Local":{"verbatim_path":"%s"}},"kind":"Related"},"concrete":{"location":{"start_point":{"row":0}},"feature":"other"}},{"symbolic":{"key":{"Local":{"verbatim_path":"%s"}},"kind":"Primary"},"concrete":{"location":{"start_point":{"row":%s}},"feature":"%s\\n"}}]}' \
    "$1" "$1" "$2" "$2" "$3" "$4"
}

# A repo with two workflows and an action; zizmor answers $T/report with the exit code in $T/code, and records its token.
repo() {
  git init -q -b main .
  mkdir -p factory/workflows .github/actions/setup
  echo 'name: ci' > factory/workflows/ci.yml
  echo 'name: fix' > factory/workflows/fix.yml
  echo 'name: setup' > .github/actions/setup/action.yml
  git add .
  echo '[]' > "$T/report"
  echo 0 > "$T/code"
  stub zizmor 'echo "zizmor token: $GH_TOKEN" >> "$T/calls"; echo "zizmor said this" >&2; cat "$T/report"; exit "$(cat "$T/code")"'
}

scenario "passes when zizmor finds no foreign or mislabelled pin, whatever else it finds, and audits every workflow and action"
repo
export GH_TOKEN=from-the-job
printf '[%s]' "$(finding unpinned-uses factory/workflows/ci.yml 3 'uses: actions/checkout@v4')" > "$T/report"
echo 13 > "$T/code"
run "$scripts/check-action-pins.sh"
expect_status 0
expect_output "action pins ok: 3 files checked"
expect_call "zizmor --format=json --no-config --no-ignores .github/actions/setup/action.yml factory/workflows/ci.yml factory/workflows/fix.yml"
expect_call "zizmor token: from-the-job"
expect_no_call "gh "
[ -z "$(ls -A "$TMPDIR")" ] || fail "expected no temporary file left behind, found: $(ls -A "$TMPDIR")"
unset GH_TOKEN

scenario "fails on a commit that is not in the action's repository, naming the file, the line and the pin"
repo
export GITHUB_TOKEN=from-the-runner
printf '[%s]' "$(finding impostor-commit factory/workflows/fix.yml 8 'uses: some/action@0000000000000000000000000000000000000001 # v1')" > "$T/report"
echo 14 > "$T/code"
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "is not in the action's repository"
expect_output "  factory/workflows/fix.yml:9: impostor-commit: what impostor-commit found: uses: some/action@0000000000000000000000000000000000000001 # v1"
expect_call "zizmor token: from-the-runner"
expect_no_output "action pins ok"
unset GITHUB_TOKEN

scenario "fails on a commit that is not the one behind the tag its comment names"
repo
export GH_TOKEN=from-the-job
printf '[%s,%s]' "$(finding template-injection factory/workflows/ci.yml 1 'run: x')" "$(finding ref-version-mismatch .github/actions/setup/action.yml 9 'v4.2.0')" > "$T/report"
echo 12 > "$T/code"
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "  .github/actions/setup/action.yml:10: ref-version-mismatch: what ref-version-mismatch found: v4.2.0"
expect_no_output "template-injection"
unset GH_TOKEN

scenario "stops with zizmor's message when it fails, such as when GitHub cannot be reached"
repo
export GH_TOKEN=from-the-job
echo 1 > "$T/code"
echo '' > "$T/report"
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "zizmor said this"
expect_output "zizmor failed (exit 1) before it could check every pinned action against GitHub, so no pin was checked"
expect_no_output "action pins ok"
[ -z "$(ls -A "$TMPDIR")" ] || fail "expected no temporary file left behind, found: $(ls -A "$TMPDIR")"
unset GH_TOKEN

scenario "stops when zizmor's report cannot be read, rather than reading it as no finding"
repo
export GH_TOKEN=from-the-job
echo 'not json' > "$T/report"
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "could not read zizmor's report, so no pin was checked"
expect_no_output "action pins ok"
unset GH_TOKEN

scenario "takes the token of the gh login when no token is set"
repo
stub gh 'case "$*" in "auth token") echo from-the-login ;; *) exit 1 ;; esac'
run "$scripts/check-action-pins.sh"
expect_status 0
expect_call "zizmor token: from-the-login"

scenario "fails without a token rather than let zizmor skip the audits that ask GitHub"
repo
stub gh 'echo "You are not logged into any GitHub hosts." >&2; exit 1'
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "needs a GitHub token"
expect_output "No pin was checked."
expect_no_call "zizmor "

scenario "passes, saying so, where zizmor is not installed"
repo
rm "$T/bin/zizmor"
for command in bash env git jq mktemp wc tr cat rm; do
  ln -s "$(command -v "$command")" "$T/bin/$command"
done
export GH_TOKEN=from-the-job
PATH="$T/bin" run "$scripts/check-action-pins.sh"
expect_status 0
expect_output "zizmor is not installed; no pinned action was checked against its repository"
unset GH_TOKEN

scenario "passes, calling nothing, in a repo with no workflow or action"
git init -q -b main .
stub zizmor 'exit 1'
run "$scripts/check-action-pins.sh"
expect_status 0
expect_output "no workflow or action to check"
expect_no_call "zizmor "

scenario "stops with a message when the workflows cannot be listed: that is not a repo with none"
repo
real_git=$(command -v git)
stub git "case \"\$*\" in ls-files*) exit 1 ;; *) exec $real_git \"\$@\" ;; esac"
export GH_TOKEN=from-the-job
run "$scripts/check-action-pins.sh"
expect_status 1
expect_output "could not list the workflows and actions with git ls-files, so no pin was checked"
expect_no_call "zizmor "
unset GH_TOKEN

scenario "this repo's lint and a scaffolded project's both run the check"
grep -F '"lint": "' "$root/package.json" | grep -qF 'factory/scripts/check-action-pins.sh &&' \
  || fail "expected the lint script in $root/package.json to run check-action-pins.sh"
grep -F '"lint": "' "$root/.claude/skills/bootstrap/scripts/scaffold.sh" | grep -qF 'factory/scripts/check-action-pins.sh &&' \
  || fail "expected the lint script scaffold.sh writes to run check-action-pins.sh"
