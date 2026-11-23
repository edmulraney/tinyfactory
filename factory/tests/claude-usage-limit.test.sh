#!/usr/bin/env bash
# Tests that claude.yml's reply starts no session while the Claude usage limit holds every agent (decisions A673a).
. "$(dirname "$0")/helpers.sh"

ahead=99999999999
ahead_in_words="5138-11-16 09:46 UTC"

# The step's commands, read from the workflow, so a change there fails here.
commands=$(awk '$0 == "      - name: Stop while the Claude usage limit holds every agent" { on = 1; next } on && /^      (- |#)/ { exit } on' \
  "$root/factory/workflows/claude.yml" | sed -n '/^        run: |$/,$p' | sed '1d; s/^          //; s|factory/scripts/|'"$root"'/factory/scripts/|g')
[ -n "$commands" ] || fail "expected claude.yml to hold the step that waits for the usage limit"

# github [hold]: the hold, when given, on the sessions branch; $T/fail lists the gh calls that fail, by their first words.
github() {
  if [ -n "${1:-}" ]; then echo "$1" > "$T/usage-limit"; else rm -f "$T/usage-limit"; fi
  : > "$T/fail"; : > "$T/outputs"; : > "$T/env"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: could not connect" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;;
      "issue comment 12 --body "*) ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
# replied [fallback]: runs the step as claude.yml's job would for a comment on #12, with a second model when given.
replied() {
  run env -u MODEL NUMBER=12 GITHUB_OUTPUT="$T/outputs" GITHUB_ENV="$T/env" AGENT_MODEL=first AGENT_MODEL_FALLBACK="${1:-}" \
    bash -e -c "$commands"
}
expect_session() {
  [ "$(cat "$T/outputs")" = "" ] || fail "expected the session to start, and the step wrote: $(cat "$T/outputs")"
  [ "$(cat "$T/env")" = "${1:+MODEL=$1}" ] || fail "expected the environment to get: ${1:+MODEL=$1}"$'\n'"it got: $(cat "$T/env")"
}

scenario "with no hold the session starts on the first model, and nobody is told"
github
replied second
expect_status 0
expect_session first
expect_no_call "gh issue comment"

scenario "a hold of every agent starts no session and tells the owner when to ask again"
github "$ahead"
replied second
expect_status 0
[ "$(cat "$T/outputs")" = "held=true" ] || fail "expected the step to write held=true, and it wrote: $(cat "$T/outputs")"
[ ! -s "$T/env" ] || fail "expected no model to be written, got: $(cat "$T/env")"
expect_call "gh issue comment 12 --body Ask again after $ahead_in_words: the Claude usage limit holds every agent until then"

scenario "a hold of the first model starts the session on the second, and of the second on the first"
github "$ahead first"
replied second
expect_status 0
expect_session second
expect_no_call "gh issue comment"
github "$ahead second"
replied second
expect_status 0
expect_session first

scenario "a hold of the first model with no second one named starts no session"
github "$ahead first"
replied
expect_status 0
[ "$(cat "$T/outputs")" = "held=true" ] || fail "expected the step to write held=true, and it wrote: $(cat "$T/outputs")"

scenario "a hold that cannot be read starts the session on the first model"
github "$ahead"
echo "api repos/{owner}/{repo}/contents/usage-limit" > "$T/fail"
replied second
expect_status 0
expect_session
expect_output "the reply runs on the first model"

scenario "an owner who cannot be told that the hold stopped the reply fails the step, so the failed run says so"
github "$ahead"
echo "issue comment" > "$T/fail"
replied second
expect_failure
[ ! -s "$T/env" ] || fail "expected no model to be written, got: $(cat "$T/env")"
