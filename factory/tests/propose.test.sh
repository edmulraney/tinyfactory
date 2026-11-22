#!/usr/bin/env bash
# Tests for propose.sh: Peta's comment on an idea is posted only when it is short and asks the owner little.
. "$(dirname "$0")/helpers.sh"

github() { stub gh 'case "$*" in "issue comment 12 --body-file "*) exit 0 ;; *) echo "unexpected call: gh $*" >&2; exit 1 ;; esac'; }
words() { yes word | head -n "$1" | tr '\n' ' '; echo; }
decisions() {
  echo "## Needs you"
  local i
  for i in $(seq 1 "$1"); do echo "- Choice $i: I recommend yes."; done
}
propose() { run "$scripts/propose.sh" 12 proposal.md; }

scenario "posts a comment of 250 words"
github
words 250 > proposal.md
propose
expect_status 0
expect_output "Posted on #12: 250 words."
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "refuses a comment of 251 words with the count, and posts nothing"
github
words 251 > proposal.md
propose
expect_status 1
expect_output "It holds 251 words, and a comment on an idea holds 250 at most."
expect_output "Nothing was posted."
expect_no_call "gh issue comment"

scenario "posts a comment that asks the owner three decisions"
github
decisions 3 > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "refuses a comment that asks the owner four decisions, and posts nothing"
github
decisions 4 > proposal.md
propose
expect_status 1
expect_output "It asks the owner 4 decisions, and 3 is the most."
expect_no_call "gh issue comment"

scenario "refuses four decisions written as plain lines or with another mark, and posts nothing"
github
{ echo "## Needs you"; echo "Pick the plan."; echo "* Pick the price."; echo "3) Pick the name."; echo "Pick the colour."; } > proposal.md
propose
expect_status 1
expect_output "It asks the owner 4 decisions, and 3 is the most."
expect_no_call "gh issue comment"

scenario "counts None with or without its full stop as no decision"
github
for none in None None.; do
  { decisions 3; echo "$none"; } > proposal.md
  propose
  expect_status 0
done

scenario "refuses a comment whose decisions sit under a bold line and not the heading, and posts nothing"
github
decisions 4 | sed 's/^## Needs you$/4. **Needs you.**/' > proposal.md
propose
expect_status 1
expect_output 'Write that part under exactly that heading.'
expect_no_call "gh issue comment"

scenario "counts no decision where the part says None, and none in a list of another part"
github
{ echo "## Decided"; for i in 1 2 3 4 5; do echo "- Choice $i: its reason."; done; echo; echo "## Needs you"; echo "None."; } > proposal.md
propose
expect_status 0

scenario "does not count a heading's marks, a list's dashes or a table's bars as words"
github
{ words 242; echo "| a | b |"; echo "|---|---|"; echo "| c | d |"; echo "## Needs you"; echo "- One: yes."; } > proposal.md
propose
expect_status 0
expect_output "Posted on #12: 250 words."

# journey <row>...: a proposal of two slices whose map of the onboarding journey holds the rows.
journey() { printf '%s\n' "## Should it be built" "Yes: product/signals.md asks for it." "" "## Tickets" "1. Ask which race: a runner picks one." "2. Show the plan: a runner sees it." "" "## Journey" "onboarding" "$@" "" "## Needs you" "None."; }

scenario "posts a proposal whose map puts every row in a slice or says unchanged"
github
journey "- Home page, signed out: the race search, then the plan page (slice 1)" "- Plan page, signed in with a race: the plan (slice 2)" \
  "- Plan page, signed in with no race: unchanged" > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "refuses a map with a row that is in no slice and does not say unchanged, and posts nothing"
github
journey "- Home page, signed out: the race search, then the plan page (slice 1)" "- Plan page, signed in with no race: a dead end" > proposal.md
propose
expect_status 1
expect_output "The row \"- Plan page, signed in with no race: a dead end\" under \"## Journey\" names no slice and does not say \"unchanged\"."
expect_no_output "signed out"
expect_no_call "gh issue comment"

scenario "refuses a map with a row in a slice the proposal does not list, and posts nothing"
github
journey "- Home page, signed out: the race search, then the plan page (slice 3)" > proposal.md
propose
expect_status 1
expect_output "names slice 3, and \"## Tickets\" has no line 3."
expect_no_call "gh issue comment"

scenario "refuses a map with a line that is not a row, or with no row, or with no name, and posts nothing"
github
journey "The runner then sees the plan." > proposal.md
propose
expect_status 1
expect_output "The line \"The runner then sees the plan.\" under \"## Journey\" is not a row."
journey > proposal.md
propose
expect_status 1
expect_output "The map under \"## Journey\" holds no row."
journey "- Home page, signed out: the race search (slice 1)" | sed 's/^onboarding$/The onboarding journey/' > proposal.md
propose
expect_status 1
expect_output "The first line under \"## Journey\" is \"The onboarding journey\", which is not the journey's name."
expect_no_call "gh issue comment"

scenario "does not count the words of the map"
github
{ journey "- Home page, signed out: $(words 300 | sed 's/ $//') (slice 1)"; echo "## Decided"; words 220; } > proposal.md
propose
expect_status 0
expect_output "Posted on #12: 250 words."

# proposal <line under "Should it be built">: a proposal of one slice.
proposal() { printf '%s\n' "## Should it be built" "$1" "" "## Building" "A runner gets a plan." "" "## Tickets" "1. Show the plan: a runner sees it."; }

scenario "posts a proposal that opens with whether to build the idea and names a file of the product's record"
github
proposal "Yes. product/signals.md holds three runners who asked for it." > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "posts a proposal that says the product's record holds nothing on the idea"
github
proposal "Yes. \`product/\` holds nothing on it." > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "refuses a proposal that does not open with whether to build the idea, and posts nothing"
github
proposal "Yes. product/signals.md asks for it." | sed 1,3d > proposal.md
propose
expect_status 1
expect_output 'does not open with the heading "## Should it be built"'
{ echo "## Building"; echo "A runner gets a plan."; echo; proposal "Yes. product/signals.md asks for it." | sed '/^## Building$/,/^$/d'; } > proposal.md
propose
expect_status 1
expect_output 'does not open with the heading "## Should it be built"'
expect_no_call "gh issue comment"

scenario "refuses a proposal whose first part names nothing of the product's record, and posts nothing"
github
{ proposal "Yes: runners want it."; echo; echo "## Decided"; echo "- As product/decisions/348.md has it: its reason."; } > proposal.md
propose
expect_status 1
expect_output 'The part "Should it be built" does not name product/.'
expect_no_call "gh issue comment"

scenario "refuses a proposal that says not to build the idea and lists no slice, and posts nothing"
github
proposal "No: PURPOSE.md says it will not cover cycling, and product/signals.md holds no runner who asked." | sed '/^## Tickets$/,$d' > proposal.md
propose
expect_status 1
expect_output 'It holds no numbered line under "## Tickets".'
expect_no_call "gh issue comment"

scenario "posts a proposal that says not to build the idea and still lists its slices"
github
proposal "No: PURPOSE.md says it will not cover cycling, and product/signals.md holds no runner who asked." > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "posts the list of the tickets Peta filed, which is no proposal"
github
{ echo "## Filed"; echo "1. #610 Show the plan"; echo; echo "## What you answered"; echo "Go."; } > proposal.md
propose
expect_status 0
expect_call "gh issue comment 12 --body-file proposal.md"

scenario "says so and fails when the comment could not be posted"
stub gh 'exit 1'
words 10 > proposal.md
propose
expect_status 1
expect_output "the comment could not be posted on #12, so the owner has not seen it"

scenario "stops when the file is not there"
github
propose
expect_status 1
expect_output "proposal.md is not a file"
expect_no_call "gh issue comment"
