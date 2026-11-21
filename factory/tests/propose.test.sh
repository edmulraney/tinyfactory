#!/usr/bin/env bash
# Tests for propose.sh: Peta's comment on an idea is posted only when it is short and asks the owner little.
. "$(dirname "$0")/helpers.sh"

github() { stub gh 'case "$*" in "issue comment 12 --body-file "*) exit 0 ;; *) echo "unexpected call: gh $*" >&2; exit 1 ;; esac'; }
# words <n>: a line of that many words.
words() { yes word | head -n "$1" | tr '\n' ' '; echo; }
# decisions <n>: the part of a proposal that asks the owner that many decisions.
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
