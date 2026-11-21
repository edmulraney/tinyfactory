#!/usr/bin/env bash
# Tests for factory/scripts/retro-proposal.sh: the proposal a lesson files, or none below the bar.
. "$(dirname "$0")/helpers.sh"

# saved <jq filter>: the lesson of a run that cost $2.10 and stopped for a person, changed by the filter.
saved() {
  jq -n '{pr: 7, issue: 5, facts: {pr: 7, issue: 5, outcome: "needs-human", fix_rounds: 3},
    lesson: {summary: "three fix rounds", title: "Fail a build that pushes untyped code", cause: "check-missing",
      detail: "the story", evidence: ["https://github.com/o/r/pull/7"],
      change: {kind: "check", target: "factory/scripts/ship.sh", proposal: "Run the type check first.", removes: "nothing"},
      cost: {amount: "3 fix rounds, $2.10 and 14 minutes", minutes: 14, kind: ["stopped"]},
      saves: "2 fix rounds, about $1.40", repeats: [], handling: [], retry: "not-applicable", propose: true}}
    | '"$1" > "$T/lesson.json"
}

# body: only what the script prints as the proposal, with what it says about itself left out.
body() { "$scripts/retro-proposal.sh" "$T/lesson.json" 2>/dev/null; }

expect_nothing_filed() {
  expect_status 0
  expect_output "no proposal: $1"
  expect_output "The lesson is saved."
  [ -z "$(body)" ] || fail "expected no proposal to be printed"
  [ -s "$T/lesson.json" ] || fail "expected the saved lesson to be left as it was"
}

scenario "a lesson with a cost and a stop files, and its proposal shows the cost"
saved .
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "## Change"
expect_output "Run the type check first."
expect_output "## How we will know it works"
expect_output "2 fix rounds, about \$1.40"
expect_output "What the fault cost: 3 fix rounds, \$2.10 and 14 minutes (stopped)"
expect_output "Seen in pull request #7."
expect_no_output "no proposal"
expect_no_output "the story"

scenario "a lesson with neither a stop nor a repeat files nothing and is still saved"
saved '.lesson.cost.kind = []'
before=$(cat "$T/lesson.json")
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the run lost no work or money, did not stop for a person and repeats no earlier lesson"
[ "$(cat "$T/lesson.json")" = "$before" ] || fail "expected the saved lesson unchanged"

scenario "a lesson that repeats an earlier one files, with no loss and no stop"
saved '.lesson.cost.kind = [] | .lesson.repeats = ["20261116T101500Z-pr-3.json"]'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "What the fault cost: 3 fix rounds, \$2.10 and 14 minutes"$'\n'
expect_output "- \`lessons/20261116T101500Z-pr-3.json\`"

scenario "lost work and lost money each file"
for kind in lost-work lost-money; do
  saved ".lesson.cost.kind = [\"$kind\"]"
  run "$scripts/retro-proposal.sh" "$T/lesson.json"
  expect_status 0
  expect_output "($kind)"
done

scenario "a cost with no figure files nothing, even with a stop and a repeat"
saved '.lesson.cost.amount = "some wasted effort" | .lesson.repeats = ["a.json"]'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the lesson gives no figure for what the fault cost"

scenario "a cost whose only digits are an issue's number or a link files nothing"
saved '.lesson.cost.amount = "a wasted fix round on pull request #7, https://github.com/o/r/pull/7"'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the lesson gives no figure for what the fault cost"
saved '.lesson.saves = "the fix round of #7"'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the lesson gives no figure for what the change saves"

scenario "work the lesson says was lost only in how the failure was handled files"
saved '.lesson.cost.kind = [] | .lesson.handling = ["lost-work"]'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "## Change"
saved '.lesson.cost.kind = [] | .lesson.handling = ["told-nobody"]'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the run lost no work or money, did not stop for a person and repeats no earlier lesson"

scenario "a lesson from before the cost was asked for files nothing"
saved 'del(.lesson.cost) | .lesson.repeats = ["a.json"]'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the lesson gives no figure for what the fault cost"

scenario "a saving with no figure files nothing"
saved '.lesson.saves = "a fix round"'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the lesson gives no figure for what the change saves"

scenario "a retro that proposes nothing files nothing, whatever the run cost"
saved '.lesson.propose = false'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the retro proposes no change"
saved '.lesson.change.kind = "none"'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_nothing_filed "the retro proposes no change"

scenario "a failed run's proposal names the run, how it was handled and no assistant"
saved '.pr = null | .facts = {run: 99, workflow: "implement", url: "https://github.com/o/r/actions/runs/99"}
  | .lesson.handling = ["lost-work"] | .lesson.retry = "enough" | .lesson.cost.kind = ["lost-work", "lost-money"]
  | .lesson.change.proposal = "Ask @claude again."'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "Seen in the failed \`implement\` run https://github.com/o/r/actions/runs/99."
expect_output "(lost-work, lost-money)"
expect_output "How the factory handled the failure: lost-work. Would trying again have been enough: enough."
expect_output "Ask claude again."
expect_no_output "@claude"

scenario "a first run's proposal names the pull request that changed the workflow"
saved '.facts = {run: 99, workflow: "ci", url: "https://github.com/o/r/actions/runs/99", changed_by: {pr: 12}}'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "Seen in the first run of \`ci\` since pull request #12 changed it, https://github.com/o/r/actions/runs/99."

scenario "a request for help: the proposal names the comment and the run that answered it"
saved '.facts = {run: 99, workflow: "claude", url: "https://github.com/o/r/actions/runs/99", pr: null, issue: 5, ask: {comment: "@claude start #5", url: "https://github.com/o/r/issues/5#issuecomment-3"}}'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "Seen in the request for help https://github.com/o/r/issues/5#issuecomment-3, which the \`claude\` run https://github.com/o/r/actions/runs/99 answered."
expect_no_output "failed"

scenario "a defect met in use: the proposal names the defect's ticket"
saved '.pr = null | .issue = 574 | .facts = {pr: null, issue: 574, defect: {title: "Let a runner keep more than one race"}, fixed_by: [577]}'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "Seen in the defect #574, which the owner met in use."
expect_no_output "pull request #null"

scenario "a defect met in use that no ticket has fixed yet: one ticket is figure enough to file"
saved '.pr = null | .issue = 574 | .facts = {pr: null, issue: 574, defect: {title: "Let a runner keep more than one race"}, fixed_by: []}
  | .lesson.cost = {amount: "1 ticket, #574, not yet built", minutes: 0, kind: ["stopped"]} | .lesson.saves = "1 ticket"'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 0
expect_output "Seen in the defect #574, which the owner met in use."
expect_no_output "pull request #null"

scenario "a file that holds no lesson stops it, and is not taken for a lesson below the bar"
printf 'not json\n' > "$T/lesson.json"
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 1
expect_output "could not be read, so whether it files a proposal is not known"
expect_no_output "no proposal"
run "$scripts/retro-proposal.sh" "$T/missing.json"
expect_status 1
expect_output "could not be read"

scenario "a lesson with a part missing stops it, and prints no half proposal"
saved 'del(.lesson.evidence)'
run "$scripts/retro-proposal.sh" "$T/lesson.json"
expect_status 1
expect_output "could not be written, so nothing is filed"
expect_no_output "## Change"

# The workflow's schema, its steps and what the skill tells the agent are kept alike here (decisions A223a, A223b).
workflow="$root/factory/workflows/retro.yml"
schema=$(sed -n "s/^  LESSON_SCHEMA: '\(.*\)'$/\1/p" "$workflow")
skill="$root/.claude/skills/retro/SKILL.md"

scenario "the schema makes a lesson carry the cost, its minutes as a number, its kinds and the saving"
run jq -e '(.required | index("cost") != null and index("saves") != null)
  and (.properties.cost.required == ["amount", "minutes", "kind"])
  and (.properties.cost.properties.minutes.type == "number")
  and (.properties.cost.properties.kind.items.enum == ["lost-work", "lost-money", "stopped"])' <<<"$schema"
expect_status 0

scenario "the retro skill names the cost, each of its parts and each of its kinds"
run jq -r '"cost", (.properties.cost.properties | keys[] | "cost." + .), .properties.cost.properties.kind.items.enum[]' <<<"$schema"
expect_status 0
[ -n "$out" ] || fail "expected the schema to list the parts of a cost"
for word in $out; do
  grep -qF "\`$word\`" "$skill" || fail "expected the skill to name \`$word\`"
done
