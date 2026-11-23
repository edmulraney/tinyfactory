#!/usr/bin/env bash
# Tests for the retro of a request for help: how claude.yml starts it and retro.yml takes it up (decisions A446a).
. "$(dirname "$0")/helpers.sh"

workflows="$root/factory/workflows"
name="Start a retro of the request for help"
link="https://github.example/owner/myapp/issues/12#issuecomment-5"

job() { awk -v job="  $2:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$workflows/$1.yml"; }
# step <workflow> <job> <name>: the step's lines, read from the source, so a change there fails here.
step() { job "$1" "$2" | awk -v first="      - name: $3" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$1" | sed '1d; s/^          //'; }

# answered: runs the step's commands as run 900 of claude.yml would, its session's transcript in $T/transcript.json.
answered() {
  run env GH_TOKEN=workflow-token GH_REPO=owner/myapp GITHUB_RUN_ID=900 TRANSCRIPT="$T/transcript.json" COMMENT="$link" \
    bash -e -c "$(commands "$(step claude claude "$name")")"
}
asked() { grep -cxF "gh workflow run retro.yml -f run=900 -f comment=$link" "$T/calls"; }
github_starts_it() {
  stub gh 'case "$*" in "workflow run retro.yml "*) ;; *) exit 1 ;; esac'
  stub sleep ':'
}
# The shape of a real session the usage limit stopped as it began: issue-218, run 44046156310.
never_began='[{"type":"system","subtype":"init"},{"type":"rate_limit_event"},
  {"type":"assistant","error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your limit"}]}},
  {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","num_turns":1}]'
began='{"type":"system","subtype":"init"},{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the ticket."}]}}'

scenario "a claude run that answered a comment starts one retro, of its run and of the comment"
github_starts_it
echo "[$began,{\"type\":\"result\",\"is_error\":false,\"terminal_reason\":\"completed\"}]" > "$T/transcript.json"
answered
expect_status 0
[ "$(asked)" = 1 ] || fail "expected the retro to be asked for once, got $(asked)"
expect_no_call "sleep"

scenario "a claude run whose session failed after it began starts its retro too"
github_starts_it
echo "[$began,{\"type\":\"assistant\",\"error\":\"server_error\"},{\"type\":\"result\",\"is_error\":true,\"terminal_reason\":\"api_error\"}]" > "$T/transcript.json"
answered
expect_status 0
[ "$(asked)" = 1 ] || fail "expected the retro to be asked for once, got $(asked)"

scenario "a claude run that failed before its session began starts no retro"
github_starts_it
echo "$never_began" > "$T/transcript.json"
answered
expect_status 0
expect_output "no retro: the session never began"
expect_no_call "gh"

scenario "a claude run whose transcript cannot be read, or was never written, starts no retro"
github_starts_it
echo "cut off {" > "$T/transcript.json"
answered
expect_status 0
expect_output "no retro: the session never began"
expect_no_call "gh"
rm "$T/transcript.json"
answered
expect_status 0
expect_no_call "gh"
found=$(step claude claude "$name")
grep -qxF "        if: always() && steps.session.outputs.execution_file != ''" <<<"$found" \
  || fail "expected the step to run however the job ended, and only when the session left a transcript"
job claude claude | grep -qx '        id: session' || fail "expected the session's step to be the one the retro's step reads"

scenario "the step asks again when GitHub does not start the retro, and stops at three"
stub gh '[ -e "$T/up" ] || { touch "$T/up"; exit 1; }'
stub sleep ':'
echo "[$began]" > "$T/transcript.json"
answered
expect_status 0
[ "$(asked)" = 2 ] || fail "expected the retro to be asked for twice, got $(asked)"
: > "$T/calls"
stub gh 'echo "could not create workflow dispatch event" >&2; exit 1'
answered
expect_failure
expect_output "could not create workflow dispatch event"
[ "$(asked)" = 3 ] || fail "expected the retro to be asked for three times, got $(asked)"

scenario "a comment without @claude starts no retro: only the job such a comment starts asks for one"
[ "$(sed -n '/^jobs:$/,$p' "$workflows/claude.yml" | grep -cE '^  [a-z0-9-]+:$')" = 1 ] || fail "expected claude.yml to hold one job"
job claude claude | grep -E '^    if: ' | grep -qF "contains(github.event.comment.body, '@claude')" \
  || fail "expected the job to run only for a comment that holds @claude"
[ "$(grep -l -- '-f comment=' "$workflows"/*.yml "$scripts"/*.sh)" = "$workflows/claude.yml" ] \
  || fail "expected nothing but claude.yml to start a retro of a comment"
found=$(step claude claude "$name")
# shellcheck disable=SC2016
for field in '          GH_TOKEN: ${{ github.token }}' '          COMMENT: ${{ github.event.comment.html_url }}' \
  '          TRANSCRIPT: ${{ steps.session.outputs.execution_file }}'; do
  grep -qxF -- "$field" <<<"$found" || fail "expected the step to hold: $field"
done
job claude claude | sed -n '/^    permissions:$/,/^    steps:$/p' | grep -qE '^      actions: write( |$)' \
  || fail "expected the job to hold actions: write, which starts a workflow"

scenario "the transcript is kept on the run, under the name run-facts.sh asks for, before the retro is started"
found=$(step claude claude "Keep the transcript on this run")
# shellcheck disable=SC2016
for field in "        if: always() && steps.session.outputs.execution_file != '' && steps.scrub.outcome == 'success'" '        uses: actions/upload-artifact@v4' \
  '          name: session-claude-${{ github.run_id }}-${{ github.run_attempt }}' '          path: ${{ steps.session.outputs.execution_file }}'; do
  grep -qxF -- "$field" <<<"$found" || fail "expected the step to hold: $field"
done
# shellcheck disable=SC2016
grep -qF -- '--name "session-claude-$run-$attempt"' "$scripts/run-facts.sh" || fail "expected run-facts.sh to download the artifact by that name"
job claude claude | grep -E '^      - name: (Keep the transcript|Start a retro)' | head -n 1 | grep -q 'Keep the transcript' \
  || fail "expected the transcript kept before the retro is started"

# gathers <pr> <run> <comment>: runs the step of retro.yml that gathers the facts, with stand-ins for the scripts it calls.
gathers() {
  mkdir -p factory/scripts .sessions
  printf '#!/usr/bin/env bash\necho "usage-limit.sh $*" >> "$T/calls"\n[ ! -e "$T/limit" ] || cat "$T/limit"\n' > factory/scripts/usage-limit.sh
  printf '#!/usr/bin/env bash\necho "run-facts.sh $*" >> "$T/calls"\n[ ! -e "$T/fail" ] || { echo "Could not read the comment" >&2; exit 1; }\ncat "$T/facts"\n' > factory/scripts/run-facts.sh
  chmod +x factory/scripts/*.sh
  : > "$T/output"
  run env GH_TOKEN=workflow-token PR="$1" RUN="$2" COMMENT="$3" GITHUB_OUTPUT="$T/output" \
    bash -e -o pipefail -c "$(commands "$(step retro retro "Gather the run's facts")")"
}

scenario "retro.yml starts the retro of a request for help however the run ended, with the facts of the comment"
echo '{"run":900,"workflow":"claude","conclusion":"success","factory_failure":false,"pr":null,"issue":12,"ask":{"comment":"@claude start #12","url":"'"$link"'"}}' > "$T/facts"
gathers "" 900 "$link"
expect_status 0
expect_call "run-facts.sh --ask 900 $link .sessions"
grep -qx 'go=true' "$T/output" || fail "expected the retro to go on"
grep -qx 'key=issue-12' "$T/output" || fail "expected the retro's transcript to be saved with the ticket's"
grep -qx 'subject=the request for help that workflow run 900 answered' "$T/output" || fail "expected the agent to be told what the retro is of"
[ "$(jq -r .ask.url .sessions/facts.json)" = "$link" ] || fail "expected the facts given to the retro to hold the comment's link"
[ "$(jq -r .ask.comment .sessions/facts.json)" = "@claude start #12" ] || fail "expected the facts given to the retro to hold the comment's text"

scenario "retro.yml saves the retro of a request made on a pull request with no ticket beside that pull request"
echo '{"run":900,"workflow":"claude","pr":72,"issue":null,"ask":{"comment":"@claude","url":"u"}}' > "$T/facts"
gathers "" 900 "https://github.example/owner/myapp/pull/72#discussion_r8"
expect_status 0
grep -qx 'key=pr-72' "$T/output" || fail "expected the retro's transcript to be saved with the pull request's"

scenario "retro.yml stops, and no agent runs, when the facts of the request cannot be read"
gathers "" 900 "$link"
touch "$T/fail"
gathers "" 900 "$link"
expect_failure
expect_output "Could not read the comment"
! grep -q 'go=true' "$T/output" || fail "expected the retro not to go on"

scenario "retro.yml starts no retro of a request while the usage limit holds every agent"
echo "the usage limit holds every agent" > "$T/limit"
gathers "" 900 "$link"
expect_status 0
grep -qx 'go=false' "$T/output" || fail "expected the retro not to go on"
expect_no_call "run-facts.sh"

scenario "a failed run with no comment is still judged as a failure, and a comment with no run is refused"
echo '{"run":900,"workflow":"implement","factory_failure":false,"pr":null,"issue":12}' > "$T/facts"
gathers "" 900 ""
expect_status 0
expect_call "run-facts.sh --run 900 .sessions"
grep -qx 'go=false' "$T/output" || fail "expected a run that is no failure of the factory to start no retro"
gathers "" "" "$link"
expect_failure
expect_output "Give a pull request number or a workflow run id."

scenario "the retro of a request for help comments on no ticket (A446c)"
step retro retro "Say on the run's ticket what the retro found" | grep -E '^        if: ' | grep -qF "&& env.COMMENT == ''" \
  || fail "expected the step that comments to be skipped for a request for help"
# shellcheck disable=SC2016
grep -qxF '  COMMENT: ${{ inputs.comment }}' "$workflows/retro.yml" || fail "expected retro.yml to read the comment it is started with"

scenario "the retro skill says how to judge a request for help"
skill="$root/.claude/skills/retro/SKILL.md"
help="$root/.claude/skills/retro/first-run-and-help.md"
grep -qF 'follow `.claude/skills/retro/first-run-and-help.md`' "$skill" || fail "expected the skill to send a request for help to first-run-and-help.md"
section=$(sed -n '/^## A request for help$/,$p' "$help")
grep -qF 'what would have made the ask unneeded' <<<"$section" || fail "expected the skill to ask what would have made the ask unneeded"
grep -qF 'A one-off, such as a setup step, has `cause` `one-off` and proposes nothing.' <<<"$section" || fail "expected the skill to say a one-off proposes nothing"
grep -qF '`ask` holds the comment' <<<"$section" || fail "expected the skill to name the fact that holds the comment"
