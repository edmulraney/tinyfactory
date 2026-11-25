#!/usr/bin/env bash
# Tests for helpers.sh: replace_first (H22), the parse check in stub (H674), a scenario's PATH and HOME (H698a, H698b).
. "$(dirname "$0")/helpers.sh"

text='## Why
Runners asked for it.

## How it was verified
`pnpm test` passed, and the owner'"'"'s "export" worked.

## Not proven
Nothing'

scenario "swaps a section that spans lines for another, keeping the rest as it was"
replace_first "$text" '## Not proven
Nothing' '## Not proven
The first run.'
[ "$replaced" = '## Why
Runners asked for it.

## How it was verified
`pnpm test` passed, and the owner'"'"'s "export" worked.

## Not proven
The first run.' ] || fail "got: $replaced"

scenario "takes backticks, quotes, a star and a bracket as written, in the old text and the new"
replace_first "$text" '`pnpm test` passed, and the owner'"'"'s "export" worked.' '````
* [x] a list item, `quoted`, with a \ and a $HOME
````'
[ "$replaced" = '## Why
Runners asked for it.

## How it was verified
````
* [x] a list item, `quoted`, with a \ and a $HOME
````

## Not proven
Nothing' ] || fail "got: $replaced"
replace_first 'a * b [c] d' '* b [c]' '?'
[ "$replaced" = 'a ? d' ] || fail "a star in the old text was read as a pattern: $replaced"

scenario "swaps only the first of two, and removes the text when the new one is empty"
replace_first 'one two one' 'one' 'three'
[ "$replaced" = 'three two one' ] || fail "got: $replaced"
replace_first 'one two one' 'one ' ''
[ "$replaced" = 'two one' ] || fail "got: $replaced"

scenario "fails the scenario when the old text is not there, and leaves the text unchanged"
replace_first "$text" '## Not here' 'anything'
[ "$replaced" = "$text" ] || fail "the text was changed: $replaced"
[[ "$_problems" == "replace_first found nothing to replace: ## Not here"* ]] || fail "the scenario was not failed"
# That failure was the point of this scenario, so it is taken back; any other stays.
_problems=${_problems#"replace_first found nothing to replace: ## Not here"$'\n'}

scenario "fails the scenario when a stand-in does not parse, and passes one that does"
stub gh 'case "$*" in "pr view"*) exit 0 ;; esac'
[ -z "$_problems" ] || fail "a stand-in that parses failed the scenario"
# That failure is the point of this scenario, so it is taken back before the check.
stub gh 'case "$*" in "pr view"*) exit 0 ;;'
refused=$_problems
_problems=""
[[ "$refused" == "the stand-in for gh does not parse: "* ]] || fail "the scenario was not failed: $refused"

# on_a_machine_with_claude <bash>: runs the bash as a test file's scenario, on a machine that has `claude` and `open`:
# each says that it really ran, and leaves $T/really-ran.
on_a_machine_with_claude() {
  mkdir -p "$T/machine"
  local command
  for command in claude open; do
    printf '#!/bin/sh\necho "the real %s ran: $*"\n: > "%s/really-ran"\n' "$command" "$T" > "$T/machine/$command"
    chmod +x "$T/machine/$command"
  done
  printf '%s\n' ". '$root/factory/tests/helpers.sh'" 'scenario "inside"' "$1" > "$T/inside.test.sh"
  PATH="$T/machine:$PATH" run bash "$T/inside.test.sh"
}

scenario "a script that calls a command the machine has, and that has no stand-in, fails saying so and runs nothing"
# shellcheck disable=SC2016
on_a_machine_with_claude 'printf "#!/usr/bin/env bash\nset -e\nclaude setup-token\nopen https://example.com\n" > script.sh
run bash script.sh
echo "the script exited $status and printed: $out"
run open https://example.com
echo "open exited $status and printed: $out"'
expect_status 0
expect_output "the script exited 97 and printed: no stand-in was given for: claude setup-token"
expect_output "open exited 97 and printed: no stand-in was given for: open https://example.com"
[ ! -e "$T/really-ran" ] || fail "expected neither command of the machine to run"

scenario "a stand-in is called before the machine's command, and \`real\` lets a scenario run the machine's own"
# shellcheck disable=SC2016
on_a_machine_with_claude 'stub claude "echo the stand-in ran"
run claude setup-token
echo "with a stand-in: $out"
real open
run open a-file
echo "with real, exit $status: $out"
real no-such-command
echo "$_problems"; _problems=""'
expect_status 0
expect_output "with a stand-in: the stand-in ran"
expect_output "with real, exit 0: the real open ran: a-file"
expect_output "real found no no-such-command on this machine"
expect_output "ok - inside"

scenario "a scenario's HOME is an empty folder of its own"
[ "$HOME" = "$T/home" ] && [ -z "$(ls -A "$HOME")" ] || fail "expected an empty HOME inside the scenario's folder, got: $HOME"
