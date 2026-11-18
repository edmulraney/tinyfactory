#!/usr/bin/env bash
# Tests for file-proposal.sh: a proposal is filed, or noted on the open ticket that holds it; gh is the one stand-in.
. "$(dirname "$0")/helpers.sh"

# saved <jq filter>: the lesson of pull request #7, over the bar, changed by the filter. Issues #40 and #41 are open.
# The lessons folder holds pr-3.json, the lesson of another pull request, ticket and run.
saved() {
  mkdir -p "$T/lessons"
  jq -n '{pr: 3, issue: 2, facts: {pr: 3, issue: 2}, lesson: {summary: "two fix rounds"}}' > "$T/lessons/pr-3.json"
  jq -n '{pr: 7, issue: 5, facts: {pr: 7, issue: 5, outcome: "needs-human", fix_rounds: 3},
    lesson: {summary: "three fix rounds", title: "Fail a build that pushes untyped code", cause: "check-missing",
      detail: "the story", evidence: ["https://github.com/o/r/pull/7"],
      change: {kind: "check", target: "factory/scripts/ship.sh", proposal: "Run the type check first.", removes: "nothing"},
      cost: {amount: "3 fix rounds, $2.10 and 14 minutes", kind: ["stopped"]},
      saves: "2 fix rounds, about $1.40", repeats: [], handling: [], retry: "not-applicable", propose: true, held_by: 0}}
    | '"$1" > "$T/lesson.json"
  jq -n '[{number: 40, title: "Run the type check before a push", labels: ["factory", "proposal", "retro"]},
    {number: 41, title: "Export forecast as CSV", labels: ["tweak"]}]' > "$T/tickets.json"
}

# github: $T/fail holds one line per gh call, by its first words, that should fail.
github() {
  : > "$T/fail"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "issue comment 40 --body "*) echo "https://github.example/40#comment-1" ;;
      "issue create --title "*) echo "https://github.example/50" ;;
      "issue edit 50 --add-label ready" | "issue edit 50 --remove-label ready") ;;
      "workflow run implement.yml -f issue=50") ;;
      "issue comment 50 --body "*) echo "https://github.example/50#comment-1" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}
file() { run env GH_TOKEN=workflow-token "$scripts/file-proposal.sh" "$T/lesson.json" "$T/tickets.json" "$T/lessons"; }
# stdout: only the sentence for the run's ticket, with what the script says about itself left out.
stdout() { GH_TOKEN=workflow-token "$scripts/file-proposal.sh" "$T/lesson.json" "$T/tickets.json" "$T/lessons" 2>/dev/null; }

scenario "a lesson naming an open ticket comments there with the pull request and the lesson, and files nothing"
saved '.lesson.held_by = 40 | .lesson.change.proposal = "Ask @claude to run the type check first."'
github
file
expect_status 0
expect_call "gh issue comment 40 --body A retro of pull request #7 proposes the change this ticket holds"
expect_call "three fix rounds"
expect_call "What the fault cost: 3 fix rounds, \$2.10 and 14 minutes"
expect_call "Ask claude to run the type check first."
expect_call "- https://github.com/o/r/pull/7"
expect_no_call "@claude"
expect_no_call "gh issue create"
expect_output "already in an open ticket, where the retro noted this run: https://github.example/40#comment-1"

scenario "a failed run's lesson names the run in its note"
saved '.lesson.held_by = 40 | .pr = null | .facts = {run: 99, workflow: "implement", url: "https://github.com/o/r/actions/runs/99"}'
github
file
expect_status 0
expect_call "gh issue comment 40 --body A retro of the \`implement\` run https://github.com/o/r/actions/runs/99 proposes"
expect_no_call "gh issue create"

scenario "a lesson naming no ticket files with both labels, and retro beside them"
saved .
github
file
expect_status 0
expect_call "gh issue create --title Fail a build that pushes untyped code --label factory --label proposal --label retro --body ## Change"
expect_call "Run the type check first."
expect_no_call "gh issue comment"
expect_no_call "needs-human"
[ "$(stdout)" = "It proposes a change to the factory: https://github.example/50" ] || fail "expected only the sentence for the run's ticket on stdout"

scenario "a lesson from before it could name a ticket files"
saved 'del(.lesson.held_by)'
github
file
expect_status 0
expect_call "gh issue create --title Fail a build that pushes untyped code --label factory --label proposal --label retro"
expect_no_call "gh issue comment"

scenario "a failed read of the tickets files as before: the file is missing, empty or not a list"
saved '.lesson.held_by = 40'
github
rm "$T/tickets.json"
file
expect_status 0
expect_call "gh issue create --title Fail a build that pushes untyped code --label factory --label proposal --label retro"
expect_no_call "gh issue comment"
expect_output "the lesson names issue #40, which the open tickets in $T/tickets.json do not show: the proposal is filed"
expect_output "It proposes a change to the factory: https://github.example/50"
for content in '' 'gh: could not connect' '{"message": "Bad credentials"}'; do
  printf '%s' "$content" > "$T/tickets.json"
  : > "$T/calls"
  file
  expect_status 0
  expect_call "gh issue create"
  expect_no_call "gh issue comment"
done

scenario "a lesson naming a ticket that is not open, or no number, files"
saved '.lesson.held_by = 39'
github
file
expect_status 0
expect_call "gh issue create"
expect_no_call "gh issue comment"
expect_output "the lesson names issue #39"
saved '.lesson.held_by = "#40"'
: > "$T/calls"
file
expect_status 0
expect_call "gh issue create"
expect_no_call "gh issue comment"

scenario "a lesson below the bar files nothing and comments nowhere, even naming an open ticket"
saved '.lesson.held_by = 40 | .lesson.cost.kind = []'
github
file
expect_status 0
expect_output "no proposal: the run lost no work or money"
[ ! -s "$T/calls" ] || fail "expected no call to GitHub"
[ -z "$(stdout)" ] || fail "expected nothing said for the run's ticket"

# repeated: the lesson cites an earlier one; its cost, as saved gives it, holds minutes.
repeated='.lesson.repeats = ["pr-3.json"]'

scenario "a proposal citing an earlier lesson and a cost in minutes is filed, labelled ready and started, and told which rule started it"
saved "$repeated"
github
file
expect_status 0
[ "$(grep '^gh ' "$T/calls" | cut -d' ' -f1-4 | tr '\n' '|')" = "gh issue create --title|gh issue edit 50|gh workflow run implement.yml|gh issue comment 50|" ] \
  || fail "expected the proposal filed, ready added, its build started, then the comment"
expect_call "gh issue edit 50 --add-label ready"
expect_call "gh workflow run implement.yml -f issue=50"
expect_call "gh issue comment 50 --body Started without asking: this proposal cites an earlier lesson and a cost in minutes"
expect_call "A369a"
[ "$(stdout)" = "It proposes a change to the factory, and started its build, as the owner's rule for a repeated fault allows: https://github.example/50" ] \
  || fail "expected the sentence for the run's ticket to say the build was started"

scenario "a proposal citing no earlier lesson is filed without ready, and waits for the owner"
saved .
github
file
expect_status 0
expect_call "gh issue create"
expect_no_call "--add-label ready"
expect_no_call "workflow run"
expect_no_call "gh issue comment"
expect_output "It proposes a change to the factory: https://github.example/50"

scenario "a proposal citing an earlier lesson and no cost in minutes waits for the owner"
saved "$repeated"' | .lesson.cost.amount = "3 fix rounds and $2.10, see https://github.com/o/r/pull/15 minutes"'
github
file
expect_status 0
expect_call "gh issue create"
expect_no_call "--add-label ready"
expect_no_call "workflow run"
expect_output "It proposes a change to the factory: https://github.example/50"

# waits: the proposal is filed without ready, and no build is started.
waits() {
  file
  expect_status 0
  expect_call "gh issue create"
  expect_no_call "--add-label ready"
  expect_no_call "workflow run"
  expect_output "It proposes a change to the factory: https://github.example/50"
}

scenario "a proposal citing only an earlier lesson of its own pull request, ticket or run waits for the owner"
github
for own in '{pr: 7, issue: 9}' '{pr: 8, issue: 5}' '{pr: null, issue: null, facts: {run: 99}}'; do
  saved "$repeated"' | .facts.run = 99'
  jq -n "$own" > "$T/lessons/pr-3.json"
  : > "$T/calls"
  waits
done

scenario "a proposal citing a lesson the folder does not hold, or one that cannot be read, waits for the owner"
saved '.lesson.repeats = ["pr-4.json"]'
github
waits
saved "$repeated"
printf 'not json\n' > "$T/lessons/pr-3.json"
: > "$T/calls"
waits
saved "$repeated"
rm -r "$T/lessons"
: > "$T/calls"
waits

scenario "a proposal citing its own earlier lesson and another run's, by its path, is started"
saved '.lesson.repeats = ["own.json", "lessons/pr-3.json"]'
jq -n '{pr: 7, issue: 5}' > "$T/lessons/own.json"
github
file
expect_status 0
expect_call "gh workflow run implement.yml -f issue=50"

scenario "a repeat noted on the open ticket that holds it starts nothing"
saved "$repeated | .lesson.held_by = 40"
github
file
expect_status 0
expect_call "gh issue comment 40"
expect_no_call "--add-label ready"
expect_no_call "workflow run"

scenario "a proposal that cannot be labelled ready is filed, starts no build and waits for a person"
saved "$repeated"
github
echo "issue edit 50 --add-label ready" > "$T/fail"
file
expect_status 0
expect_no_call "workflow run"
expect_no_call "gh issue comment"
expect_output "Issue #50, a proposal for a repeated fault, could not be labelled ready: it waits for a person to add the label."
[ "$(stdout)" = "It proposes a change to the factory: https://github.example/50" ] || fail "expected the sentence of a proposal that waits"

scenario "a build that cannot be started leaves the proposal filed without ready, waiting for a person"
saved "$repeated"
github
echo "workflow run" > "$T/fail"
file
expect_status 0
expect_call "gh issue edit 50 --remove-label ready"
expect_no_call "gh issue comment"
expect_output "The build of issue #50, a proposal for a repeated fault, could not be started: it waits for a person to add the ready label."
[ "$(stdout)" = "It proposes a change to the factory: https://github.example/50" ] || fail "expected the sentence of a proposal that waits"

scenario "a build that cannot be started, with ready that cannot be taken off, says when the build starts"
saved "$repeated"
github
printf 'workflow run\nissue edit 50 --remove-label ready\n' > "$T/fail"
file
expect_status 0
expect_output "the ready label could not be taken off it: its build starts when a place next frees."
expect_no_output "started its build"

scenario "a started proposal that cannot be told which rule started it is still reported as started"
saved "$repeated"
github
echo "issue comment 50" > "$T/fail"
file
expect_status 0
expect_call "gh workflow run implement.yml -f issue=50"
expect_output "The build of issue #50 was started, and the issue could not be told which rule started it."
expect_output "It proposes a change to the factory, and started its build"

scenario "an empty title is replaced by the summary's start"
saved '.lesson.title = "  "'
github
file
expect_status 0
expect_call "gh issue create --title three fix rounds --label factory"

scenario "files with needs-human when GitHub refuses the labels"
saved .
github
echo "issue create --title Fail a build that pushes untyped code --label factory --label proposal" > "$T/fail"
file
expect_status 0
expect_first_line "gh issue create --title Fail a build that pushes untyped code --label factory --label needs-human --body" "Add the \`ready\` label to have this proposal built, or close it: nothing is built until then."
expect_call "## Change"
expect_output "It proposes a change to the factory: https://github.example/50"

scenario "stops with a message when the comment fails, and files no second copy"
saved '.lesson.held_by = 40'
github
echo "issue comment" > "$T/fail"
file
expect_status 1
expect_output "Could not comment on issue #40, which holds the lesson's proposal, so nothing is said there and nothing is filed."
expect_no_call "gh issue create"
expect_no_output "noted this run"
[ -z "$(stdout)" ] || fail "expected nothing said for the run's ticket"

scenario "stops with a message when the ticket cannot be filed"
saved .
github
echo "issue create" > "$T/fail"
file
expect_status 1
expect_output "Could not file the proposal of the lesson in $T/lesson.json. The lesson is saved."
expect_no_output "It proposes a change"

scenario "a file that holds no lesson stops it, and nothing is filed"
saved .
github
printf 'not json\n' > "$T/lesson.json"
file
expect_status 1
expect_output "could not be read, so whether it files a proposal is not known"
[ ! -s "$T/calls" ] || fail "expected no call to GitHub"

# The workflow's schema, its steps and what the skill tells the agent are kept alike here (decisions A218a).
workflow="$root/factory/workflows/retro.yml"
schema=$(sed -n "s/^  LESSON_SCHEMA: '\(.*\)'$/\1/p" "$workflow")
skill="$root/.claude/skills/retro/SKILL.md"

scenario "the schema makes a lesson say which open ticket holds its proposal, and the skill names the field"
run jq -e '(.required | index("held_by") != null) and (.properties.held_by.type == "integer")' <<<"$schema"
expect_status 0
grep -qF '`held_by`' "$skill" || fail "expected the skill to name \`held_by\`"

scenario "the workflow lists the open tickets before every try of the agent, tells each where, and goes on without them"
list=$(grep -n 'gh issue list --state open' "$workflow" | cut -d: -f1)
first=$(grep -n 'uses: anthropics/claude-code-action' "$workflow" | head -n 1 | cut -d: -f1)
[ -n "$list" ] && [ -n "$first" ] || fail "expected the workflow to list the open tickets and run the agent"
[ "${list:-0}" -lt "${first:-0}" ] || fail "expected the tickets listed before the agent runs"
grep -qF '> .sessions/tickets.json || {' "$workflow" || fail "expected a failed listing not to stop the retro"
grep -qF 'rm -f .sessions/tickets.json' "$workflow" || fail "expected a failed listing to leave no file"
tries=$(grep -c 'uses: anthropics/claude-code-action' "$workflow")
prompted=$(grep -c 'The open tickets are in .sessions/tickets.json' "$workflow")
[ "$tries" = "$prompted" ] || fail "expected each of the $tries tries to be told where the tickets are, and $prompted were"

scenario "the workflow saves the lesson before it files, and files only through the script"
save=$(grep -n 'save-session.sh lesson' "$workflow" | cut -d: -f1)
ask=$(grep -n 'file-proposal.sh "\$lesson" .sessions/tickets.json .sessions/lessons)' "$workflow" | cut -d: -f1)
[ -n "$save" ] && [ -n "$ask" ] || fail "expected the workflow to save the lesson and call the script with the tickets and the earlier lessons"
[ "${save:-0}" -lt "${ask:-0}" ] || fail "expected the lesson saved before the proposal is filed"
! grep -q 'gh issue create' "$workflow" || fail "expected the workflow to file nothing itself"

scenario "the workflow may start the build of a proposal"
job=$(sed -n '/^  retro:/,/^    steps:/p' "$workflow")
grep -qE '^      actions: write( |$)' <<<"$job" || fail "expected the retro job to hold actions: write, which starts implement.yml"
