#!/usr/bin/env bash
# Tests for factory/scripts/post-verdict.sh, which posts a reviewer's findings and lets their kinds decide the job.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/sessions-remote.sh"

# $T/fail lists the gh calls, by their first words, that fail; $T/posted keeps what was posted, $T/kept the notes kept.
a_review() {
  : > "$T/fail"
  : > "$T/kept"
  echo '[]' > "$T/tickets"
  echo app/claude > "$T/author"
  : > "$T/outputs"
  : > "$T/posted"
  export GITHUB_OUTPUT="$T/outputs" RUNNER_TEMP="$T/runner"
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=900
  mkdir -p "$T/runner"
  stub gh '
    while IFS= read -r words; do
      case "$*" in "$words"*) echo "gh: failed: $*" >&2; exit 1 ;; esac
    done < "$T/fail"
    case "$*" in
      "pr view 7 --json author --jq .author.login") cat "$T/author" ;;
      "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github ;;
      "pr comment 7 --body-file "*) cat "$5" >> "$T/posted" ;;
      "pr comment 7 --body "*) printf "%s\n" "$5" >> "$T/posted" ;;
      "pr edit 7 --add-label needs-human") ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100 --paginate --jq "*) json "$(cat "$T/tickets")" "$@" ;;
      "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) json "[]" "$@" ;;
      "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") echo "[]" ;;
      "issue create --title Apply the review notes of week "*" --label factory --body "*) echo https://github.com/owner/repo/issues/50 ;;
      "issue comment "*" --body "*) printf "%s\n" "$5" >> "$T/kept" ;;
      "issue close 50 --reason not planned") ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
  echo '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529,"session_id":"c22ab626"}]' > "$T/session.json"
}
expect_posted() {
  [[ "$(cat "$T/posted")" == *"$1"* ]] || fail "expected the comment to hold: $1"$'\n'"it was: $(cat "$T/posted")"
}

scenario "a pass is posted and the job passes"
a_review
OUTPUT='{"findings":[]}' run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 0
[ "$(cat "$T/posted")" = '**Adam (architecture and taste): PASS**'$'\n\n''<!-- factory:assumptions [] -->' ] \
  || fail "expected the verdict in one line and the hidden list, and nothing else, got: $(cat "$T/posted")"
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a review with a verdict not to be marked cut short"

scenario "a fail is posted with its findings, the job fails, and it is not marked cut short: a fix round starts"
a_review
OUTPUT='{"findings":[{"file":"apps/web/src/a.ts","line":4,"kind":"misbehaves","problem":"Divides by zero.","fix":"Guard the empty list."},{"file":"apps/web/src/b.ts","kind":"breaks-rule","problem":"Unused, against TASTE.md.","fix":"Delete it."}]}' \
  run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Misbehaves:** `apps/web/src/a.ts:4`: Divides by zero.'
expect_posted "   Fix: Guard the empty list."
expect_posted '2. **Breaks a rule:** `apps/web/src/b.ts`: Unused, against TASTE.md.'
[ "$(sed -n 2,3p "$T/posted")" = $'\n''1. **Misbehaves:** `apps/web/src/a.ts:4`: Divides by zero.' ] || fail "expected the findings straight after the verdict's line, got: $(cat "$T/posted")"
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a failed review not to be marked cut short"

# The same list as it stands hidden at the end of the comment, for the scripts that read it.
hidden() { grep -x -- '<!-- factory:assumptions .* -->' "$T/posted" | sed -e 's/^<!-- factory:assumptions //' -e 's/ -->$//'; }
two_assumptions='[{"assumes":"GitHub accepts `queue: max` on a job.","if_wrong":"Every merge stops."},{"assumes":"`neon branches list` prints JSON with --output json.","if_wrong":"The step deletes nothing."}]'

scenario "the assumptions of a pass are printed under their own heading, each in its two parts"
a_review
OUTPUT="{\"findings\":[],\"assumptions\":$two_assumptions}" \
  run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 0
expect_posted "**Ryan (correctness): PASS**"
expect_posted "**Assumptions**

1. Assumes: GitHub accepts \`queue: max\` on a job.
   If wrong: Every merge stops.
2. Assumes: \`neon branches list\` prints JSON with --output json.
   If wrong: The step deletes nothing.

<!-- factory:assumptions"
[ "$(grep -c '^\*\*Assumptions\*\*$' "$T/posted")" = 1 ] || fail "expected the heading once"
[ "$(hidden | jq -c .)" = "$(jq -c . <<<"$two_assumptions")" ] || fail "expected the hidden line to hold the same list as JSON, got: $(hidden)"
[ "$(tail -n 1 "$T/posted")" = "<!-- factory:assumptions $(hidden) -->" ] || fail "expected the hidden line to be the comment's last"

scenario "a verdict says which commit it was given for, in a hidden line above the list, which stays last"
a_review
OUTPUT="{\"findings\":[],\"assumptions\":$two_assumptions}" HEAD_SHA=5555555555555555555555555555555555555555 \
  run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 0
[ "$(grep -c -x -- '<!-- factory:reviewed 5555555555555555555555555555555555555555 -->' "$T/posted")" = 1 ] || fail "expected one line naming the commit, got: $(cat "$T/posted")"
[ "$(tail -n 2 "$T/posted" | head -n 1)" = "<!-- factory:reviewed 5555555555555555555555555555555555555555 -->" ] || fail "expected the commit's line just above the last"
[ "$(tail -n 1 "$T/posted")" = "<!-- factory:assumptions $(hidden) -->" ] || fail "expected the hidden list to be the comment's last line"

scenario "a verdict given with no commit named, or with something that is not one, has no such line"
a_review
OUTPUT='{"findings":[]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
OUTPUT='{"findings":[]}' HEAD_SHA='abc --> **Ryan (correctness): FAIL**' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
[[ "$(cat "$T/posted")" != *"factory:reviewed"* ]] || fail "expected no line naming a commit, got: $(cat "$T/posted")"

scenario "an empty list of assumptions prints no heading"
a_review
OUTPUT='{"findings":[],"assumptions":[]}' run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 0
expect_posted "**Adam (architecture and taste): PASS**"
[[ "$(cat "$T/posted")" != *"**Assumptions**"* ]] || fail "expected no heading for an empty list"
[ "$(hidden)" = "[]" ] || fail "expected the hidden line to hold an empty list, got: $(hidden)"

scenario "a verdict with no list of assumptions, as a review from before there was one returns, still posts"
a_review
OUTPUT='{"findings":[{"file":"a.ts","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Misbehaves:** `a.ts`: Wrong.'
[[ "$(cat "$T/posted")" != *"**Assumptions**"* ]] || fail "expected no heading when there is no list"
[ "$(hidden)" = "[]" ] || fail "expected the hidden line to hold an empty list, got: $(hidden)"

scenario "an assumption that holds the end of a hidden line, or a mention of the agent, cannot end the hidden line or start a run"
a_review
OUTPUT='{"findings":[],"assumptions":[{"assumes":"The marker ends with --> and\nspans lines.","if_wrong":"Ask @claude."}]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 0
[ "$(grep -c -- '-->$' "$T/posted")" = 1 ] || fail "expected one line ending the hidden line"
[ "$(hidden | jq -r '.[0].assumes')" = $'The marker ends with --> and\nspans lines.' ] || fail "expected the assumption to come back whole, got: $(hidden)"
[ "$(hidden | jq -r '.[0].if_wrong')" = "Ask claude." ] || fail "expected the mention taken out of the hidden line"

scenario "a mention of the agent in a finding is taken out, so the comment starts no agent run"
a_review
OUTPUT='{"findings":[{"file":"a.ts","kind":"misbehaves","problem":"Ask @claude about it.","fix":"Right it."}]}' run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7
expect_status 1
expect_posted '1. **Misbehaves:** `a.ts`: Ask claude about it.'

scenario "a summary, as a review from before it was taken out returns, is not posted"
a_review
OUTPUT='{"summary":"Small and well tested.","findings":[]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
[[ "$(cat "$T/posted")" != *"Small and well tested."* ]] || fail "expected no summary, got: $(cat "$T/posted")"

note='{"file":"a.ts","line":9,"kind":"note","problem":"The name could say more.","fix":"Call it runsPerDay."}'

scenario "notes alone pass: they are posted under a heading that says nothing has to change, and no fix round starts"
a_review
OUTPUT="{\"findings\":[$note,{\"file\":\"b.ts\",\"kind\":\"note\",\"problem\":\"A long function.\",\"fix\":\"Split it.\"}],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
[ "$(sed -n 1,8p "$T/posted")" = '**Ryan (correctness): PASS**

**Out of scope: nothing here has to change**

1. `a.ts:9`: The name could say more.
   Fix: Call it runsPerDay.
2. `b.ts`: A long function.
   Fix: Split it.' ] || fail "expected the pass, then the notes under their heading, got: $(cat "$T/posted")"
[[ "$(cat "$T/posted")" != *"FAIL"* ]] || fail "expected notes not to be posted as a fail"
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a pass with notes not to be marked cut short"

wrong='{"file":"c.ts","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}'
two_notes="{\"findings\":[$note,{\"file\":\"b.ts\",\"kind\":\"note\",\"problem\":\"A long function.\",\"fix\":\"Split it.\"}]}"

scenario "a verdict with two notes adds one comment to the ticket that collects them, saying whose they are"
a_review
echo '[{"number":40,"title":"Apply the review notes of week 6"}]' > "$T/tickets"
OUTPUT="$two_notes" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
[ "$(grep -c '^gh issue comment' "$T/calls")" = 1 ] || fail "expected one comment for the two notes"
expect_call "gh issue comment 40 --body"
[ "$(cat "$T/kept")" = '**Ryan (correctness)** on pull request #7:

1. `a.ts:9`: The name could say more.
   Fix: Call it runsPerDay.
2. `b.ts`: A long function.
   Fix: Split it.' ] || fail "expected the two notes as the verdict prints them, got: $(cat "$T/kept")"
expect_no_call "issue create"

scenario "the first notes of a week make the ticket"
a_review
OUTPUT="$two_notes" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
expect_call "gh issue create --title Apply the review notes of week $((10#$(date -u +%V))) --label factory"
expect_call "gh issue comment 50 --body"

scenario "a verdict with no note adds nothing: no ticket is looked for, made or commented on"
a_review
OUTPUT="{\"findings\":[$wrong]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
expect_no_call "gh api"
expect_no_call "gh issue"

scenario "the notes of a fail are kept too, and it still fails"
a_review
OUTPUT="{\"findings\":[$wrong,$note]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
[[ "$(cat "$T/kept")" == *"The name could say more."* ]] || fail "expected the note kept"
[[ "$(cat "$T/kept")" != *"FAIL"* && "$(cat "$T/kept")" != *"Misbehaves"* ]] || fail "expected only the notes kept, got: $(cat "$T/kept")"

scenario "notes that cannot be kept do not fail the review: the verdict is posted, the job passes, and the log says where they are"
for call in "api repos" "pr list" "issue create" "issue comment"; do
  a_review
  [ "$call" != "pr list" ] || echo '[{"number":40,"title":"Apply the review notes of week 6"}]' > "$T/tickets"
  echo "$call" > "$T/fail"
  OUTPUT="$two_notes" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
  expect_status 0
  expect_posted "**Ryan (correctness): PASS**"
  expect_output "its notes are only in its comment on pull request #7"
  expect_no_call "needs-human"
  ! grep -q cut-short "$T/outputs" || fail "expected no cut-short mark when $call fails"
done

scenario "a pass prints its notes above its assumptions"
a_review
OUTPUT="{\"findings\":[$note],\"assumptions\":$two_assumptions}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
[ "$(grep -n -e '^\*\*Out of scope' -e '^\*\*Assumptions' "$T/posted" | cut -d: -f1 | tr '\n' ' ')" = "3 8 " ] || fail "expected the notes, then the assumptions, got: $(cat "$T/posted")"
[ "$(tail -n 1 "$T/posted")" = "<!-- factory:assumptions $(hidden) -->" ] || fail "expected the hidden line to be the comment's last"

# expect_refused_for <findings> [<the reviewer's blocking kind>]: Ryan's verdict unless the kind is Adam's.
expect_refused_for() {
  local reviewer="Ryan (correctness)"
  [ "${2:-bug}" = bug ] || reviewer="Adam (architecture and taste)"
  expect_status 1
  expect_posted "Its verdict was refused, because each of its findings is \`${2:-bug}\` or \`out-of-scope\`, and these are not: $1. It is not posted, so no fix round starts"
  expect_posted "Run the failed jobs again in https://github.com/owner/repo/actions/runs/900"
  [[ "$(cat "$T/posted")" != *": FAIL**"* && "$(cat "$T/posted")" != *": PASS**"* ]] || fail "expected it to be posted as neither a pass nor a fail"
  [[ "$(cat "$T/posted")" != *"Wrong."* ]] || fail "expected no finding to be posted"
  [[ "$(cat "$T/posted")" != *"factory:assumptions"* ]] || fail "expected no hidden list a script could take for a verdict's"
  [[ "$(cat "$T/posted")" != *"Nothing is known to be wrong"* ]] || fail "expected a refused verdict not to be called a pull request with nothing wrong"
  expect_call "gh pr edit 7 --add-label needs-human"
  grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"
}

# A verdict from before the install: either reviewer gave any of the four kinds (decisions A256e).
for reviewer in "Ryan (correctness)" "Adam (architecture and taste)"; do
  for kind in misbehaves unproven breaks-rule; do
    scenario "an old verdict is still read: one finding of ${reviewer%% *}'s that is $kind fails the review, among any number of notes"
    a_review
    OUTPUT="{\"findings\":[$note,{\"file\":\"c.ts\",\"kind\":\"$kind\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"},$note],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "$reviewer" 7
    expect_status 1
    expect_posted "**$reviewer: FAIL**"
    ! grep -q cut-short "$T/outputs" || fail "expected a failed review not to be marked cut short"
  done
done

# finding <kind>: one finding of that kind.
finding() { echo "{\"file\":\"c.ts\",\"line\":3,\"kind\":\"$1\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"}"; }
elsewhere='{"file":"d.ts","kind":"out-of-scope","problem":"The export beside it drops the header.","fix":"Write the header row."}'

scenario "Ryan's bug fails the review, led by its kind, and a fix round starts"
a_review
OUTPUT="{\"findings\":[$(finding bug)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Bug:** `c.ts:3`: Wrong.'
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a failed review not to be marked cut short"

scenario "Adam's design finding fails the review, led by its kind, and a fix round starts"
a_review
OUTPUT="{\"findings\":[$(finding design)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7
expect_status 1
expect_posted "**Adam (architecture and taste): FAIL**"
expect_posted '1. **Design:** `c.ts:3`: Wrong.'
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a failed review not to be marked cut short"

scenario "Adam's bug is refused, beside a finding of his own: the kind is Ryan's"
a_review
OUTPUT="{\"findings\":[$(finding design),$(finding bug)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_refused_for "finding 2" design

scenario "Ryan's design finding is refused, beside a finding of his own: the kind is Adam's"
a_review
OUTPUT="{\"findings\":[$(finding bug),$(finding design)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_refused_for "finding 2"

for reviewer in "Ryan (correctness)" "Adam (architecture and taste)"; do
  scenario "a finding of ${reviewer%% *}'s that is out of scope fails nothing: it is posted under its heading and kept in the notes ticket"
  a_review
  OUTPUT="{\"findings\":[$elsewhere],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "$reviewer" 7
  expect_status 0
  [ "$(sed -n 1,6p "$T/posted")" = "**$reviewer: PASS**

**Out of scope: nothing here has to change**

1. \`d.ts\`: The export beside it drops the header.
   Fix: Write the header row." ] || fail "expected the pass, then the finding under its heading, got: $(cat "$T/posted")"
  [ "$(cat "$T/kept")" = "**$reviewer** on pull request #7:

1. \`d.ts\`: The export beside it drops the header.
   Fix: Write the header row." ] || fail "expected the finding kept in the notes ticket, got: $(cat "$T/kept")"
  expect_no_call "needs-human"
  ! grep -q cut-short "$T/outputs" || fail "expected a pass not to be marked cut short"
done

scenario "a fail lists a finding that is out of scope after what fails it, and keeps only that one"
a_review
OUTPUT="{\"findings\":[$elsewhere,$(finding bug)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
[ "$(sed -n 1,9p "$T/posted")" = '**Ryan (correctness): FAIL**

1. **Bug:** `c.ts:3`: Wrong.
   Fix: Right it.

**Out of scope: nothing here has to change**

1. `d.ts`: The export beside it drops the header.
   Fix: Write the header row.' ] || fail "expected the bug, then the finding that is out of scope, got: $(cat "$T/posted")"
[[ "$(cat "$T/kept")" == *"drops the header"* && "$(cat "$T/kept")" != *"Bug"* ]] || fail "expected only the finding that is out of scope kept, got: $(cat "$T/kept")"

scenario "a reviewer that is neither Ryan nor Adam has no kinds: nothing is posted, the job fails, and no fix round starts"
a_review
OUTPUT="{\"findings\":[$(finding bug)],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Greta (grammar)" 7 "$T/session.json"
expect_status 1
expect_output 'the reviewer is Ryan or Adam, and "Greta (grammar)" is neither'
expect_no_call "gh "
[ ! -s "$T/posted" ] || fail "expected nothing posted, got: $(cat "$T/posted")"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a fail lists what fails it first, each led by its kind, and the notes after under their heading"
a_review
OUTPUT="{\"findings\":[$note,{\"file\":\"c.ts\",\"kind\":\"unproven\",\"problem\":\"AC2 passes with the columns missing.\",\"fix\":\"Assert the header row.\"}],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7
expect_status 1
[ "$(sed -n 1,9p "$T/posted")" = '**Adam (architecture and taste): FAIL**

1. **Unproven:** `c.ts`: AC2 passes with the columns missing.
   Fix: Assert the header row.

**Out of scope: nothing here has to change**

1. `a.ts:9`: The name could say more.
   Fix: Call it runsPerDay.' ] || fail "expected the blocking finding, then the note, got: $(cat "$T/posted")"

scenario "the kinds decide, not a verdict in the reviewer's own word: a 'fail' of notes passes, and a 'pass' with a defect fails"
a_review
OUTPUT="{\"verdict\":\"fail\",\"findings\":[$note],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 0
expect_posted "**Ryan (correctness): PASS**"
: > "$T/posted"
OUTPUT='{"verdict":"pass","findings":[{"file":"a.ts","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}],"assumptions":[]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"

scenario "a fail posts its assumptions only in the hidden line"
a_review
OUTPUT="{\"findings\":[{\"file\":\"a.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"}],\"assumptions\":$two_assumptions}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
expect_posted '1. **Misbehaves:** `a.ts`: Wrong.'
[[ "$(cat "$T/posted")" != *"**Assumptions**"* ]] || fail "expected a fail to print no list of assumptions, got: $(cat "$T/posted")"
[ "$(hidden | jq -c .)" = "$(jq -c . <<<"$two_assumptions")" ] || fail "expected the hidden line to keep the list, got: $(hidden)"

scenario "a finding with no kind is refused, beside ones that have theirs: it is neither a pass nor a fail"
a_review
OUTPUT="{\"findings\":[$note,{\"file\":\"a.ts\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"}],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_refused_for "finding 2"

scenario "a kind that no reviewer has is no kind, and the reviewer's own word for it never reaches the comment"
a_review
OUTPUT=$(jq -n '{findings: [{file: "a.ts", kind: "@claude blocker", problem: "Wrong.", fix: "Right it."}, {file: "b.ts", kind: 3, problem: "Wrong.", fix: "Right it."}, "Wrong.", {file: "c.ts", kind: "Note", problem: "Wrong.", fix: "Right it."}], assumptions: []}') \
  run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_refused_for "finding 1, finding 2, finding 3, finding 4"
[[ "$(cat "$T/posted")" != *"blocker"* ]] || fail "expected the reviewer's own kind not to be posted"

scenario "when a verdict refused for a finding of no kind cannot be said on the pull request, the job fails and still starts no fix round"
a_review
echo "pr comment" > "$T/fail"
OUTPUT='{"findings":[{"file":"a.ts","problem":"Wrong.","fix":"Right it."}]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

# A sentence of $1 words.
words() { local n; for ((n = 1; n < $1; n++)); do printf 'word '; done; printf 'end.'; }

scenario "a field of 40 words is posted"
a_review
OUTPUT="{\"findings\":[{\"file\":\"a.ts\",\"kind\":\"misbehaves\",\"problem\":\"$(words 40)\",\"fix\":\"$(words 40)\"}],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted "   Fix: $(words 40)"
expect_no_call "needs-human"

scenario "a fail with a finding over 40 words is refused: nothing of it is posted, a person is asked, and no fix round starts"
a_review
OUTPUT="{\"findings\":[{\"file\":\"a.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"Right it.\"},{\"file\":\"b.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"$(words 41)\"}],\"assumptions\":[]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "Its verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: finding 2's \`fix\` is 41 words."
expect_posted "no fix round starts"
expect_posted "Run the failed jobs again in https://github.com/owner/repo/actions/runs/900"
[[ "$(cat "$T/posted")" != *": FAIL**"* ]] || fail "expected it not to be posted as a fail"
[[ "$(cat "$T/posted")" != *"word word"* ]] || fail "expected the long field not to be posted"
[[ "$(cat "$T/posted")" != *"Nothing is known to be wrong"* ]] || fail "expected a refused fail not to be called a pull request with nothing wrong"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a pass with an assumption over 40 words is refused, and the job fails: nothing merges on it"
a_review
OUTPUT="{\"findings\":[],\"assumptions\":[{\"assumes\":\"A claim.\",\"if_wrong\":\"$(words 57)\"}]}" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "assumption 1's \`if_wrong\` is 57 words."
[[ "$(cat "$T/posted")" != *": PASS**"* ]] || fail "expected it not to be posted as a pass"
[[ "$(cat "$T/posted")" != *"factory:assumptions"* ]] || fail "expected no hidden list a script could take for a verdict's"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

# A pass with $1 assumptions, numbered in the order given.
assuming() { jq -nc --argjson n "$1" '{findings: [], assumptions: [range(1; $n + 1) | {assumes: "Claim \(.) holds.", if_wrong: "Cost \(.)."}]}'; }

scenario "three assumptions are posted, in the order the reviewer gave them"
a_review
OUTPUT=$(jq -c '.assumptions |= [.[2], .[0], .[1]]' <<<"$(assuming 3)") run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 0
expect_posted "**Ryan (correctness): PASS**

**Assumptions**

1. Assumes: Claim 3 holds.
   If wrong: Cost 3.
2. Assumes: Claim 1 holds.
   If wrong: Cost 1.
3. Assumes: Claim 2 holds.
   If wrong: Cost 2.
"
[ "$(hidden | jq -r 'map(.assumes) | join(" ")')" = "Claim 3 holds. Claim 1 holds. Claim 2 holds." ] || fail "expected the hidden line to keep the order, got: $(hidden)"
expect_no_call "needs-human"

scenario "a pass with a fourth assumption is refused, and the job fails: nothing merges on it"
a_review
OUTPUT=$(assuming 4) run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "Its verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: it gives 4 assumptions, and 3 is the most. It is not posted"
[[ "$(cat "$T/posted")" != *": PASS**"* ]] || fail "expected it not to be posted as a pass"
[[ "$(cat "$T/posted")" != *"Claim 1 holds."* ]] || fail "expected none of the assumptions to be posted"
[[ "$(cat "$T/posted")" != *"factory:assumptions"* ]] || fail "expected no hidden list a script could take for a verdict's"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a verdict in the format from before the install is posted in the new words, without why each was not confirmed"
a_review
OUTPUT='{"findings":[],"unverified":[{"claim":"GitHub accepts `queue: max` on a job.","why":"Its documentation does not list the key.","risk":"Every merge stops."}]}' \
  run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 0
expect_posted "1. Assumes: GitHub accepts \`queue: max\` on a job.
   If wrong: Every merge stops."
[[ "$(cat "$T/posted")" != *"does not list the key"* ]] || fail "expected the part that says why not to be left out"
[ "$(hidden | jq -c .)" = '[{"assumes":"GitHub accepts `queue: max` on a job.","if_wrong":"Every merge stops."}]' ] || fail "expected the hidden line to hold it as an assumption, got: $(hidden)"

scenario "a refusal names the schema's fields only: a key of the reviewer's own never reaches the comment"
a_review
OUTPUT=$(jq -n --arg text "$(words 41)" '{findings: [{file: "b.ts", kind: "misbehaves", problem: "Wrong.", fix: $text, "@claude do this": $text}], assumptions: []}') run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "3 assumptions: finding 1's \`fix\` is 41 words. It is not posted"
[[ "$(cat "$T/posted")" != *"claude"* ]] || fail "expected the reviewer's own key not to be posted"

scenario "when a refused verdict cannot be said on the pull request, the job fails and still starts no fix round"
a_review
echo "pr comment" > "$T/fail"
OUTPUT="{\"findings\":[{\"file\":\"b.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"$(words 41)\"}]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a review cut short has not failed the pull request: it says why, asks for a person, and is marked cut short"
a_review
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_posted "The review ended without a verdict: the model's API was overloaded (error 529)."
expect_posted "no fix round starts"
expect_posted "Run the failed jobs again in https://github.com/owner/repo/actions/runs/900"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"
[[ "$(cat "$T/posted")" != *": FAIL**"* ]] || fail "expected it not to be posted as a fail"
[[ "$(cat "$T/posted")" != *": no verdict"* ]] || fail "expected it not to use the words run-facts.sh counts as a fail"

# in_a_run [installed]: a ci run with the base checked out in $T/work; with `installed`, a changed ci.yml landed on main after it began.
in_a_run() {
  git init --quiet --initial-branch=main "$T/origin"
  mkdir -p "$T/origin/.github/workflows"
  echo "name: ci" > "$T/origin/.github/workflows/ci.yml"
  git -C "$T/origin" add . && git -C "$T/origin" commit --quiet -m "the workflow"
  git -C "$T/origin" config uploadpack.allowAnySHA1InWant true
  GITHUB_WORKFLOW_SHA=$(git -C "$T/origin" rev-parse HEAD)
  [ "${1:-}" != installed ] || { echo "name: ci, changed" > "$T/origin/.github/workflows/ci.yml"; git -C "$T/origin" commit --quiet -am "ci: install ci.yml"; }
  git clone --quiet "$T/origin" "$T/work"
  export GITHUB_WORKFLOW_SHA GITHUB_WORKFLOW_REF=owner/repo/.github/workflows/ci.yml@refs/pull/7/merge GITHUB_BASE_REF=main
}

scenario "no verdict in a run whose ci.yml differs from main's at review time: the job fails so that a fresh run is asked for, and no person is"
a_review; in_a_run installed
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 ""
expect_status 1
expect_output "Adam (architecture and taste): not reviewed. .github/workflows/ci.yml on main has changed since this run began: this run uses the workflow from before the install"
expect_output "git fetch origin main && git merge origin/main"
expect_no_call "needs-human"
expect_no_call "gh pr comment"
[ ! -s "$T/outputs" ] || fail "expected it not to be marked cut short: that would keep the fix round from starting"

scenario "no verdict in such a run, on a pull request a person opened: no fix round will start, so a comment tells its author what to do"
a_review; in_a_run installed
echo octocat > "$T/author"
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 ""
expect_status 1
expect_posted "**Ryan (correctness): not reviewed.** .github/workflows/ci.yml on main has changed since this run began: this run uses the workflow from before the install"
expect_posted "git fetch origin main && git merge origin/main"
expect_no_call "needs-human"
[ ! -s "$T/outputs" ] || fail "expected it not to be marked cut short"

scenario "no verdict in such a run, and GitHub does not say who opened the pull request: it is told, as a person's is"
a_review; in_a_run installed
echo "pr view 7" > "$T/fail"
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 ""
expect_status 1
expect_posted "**Ryan (correctness): not reviewed.**"
expect_no_call "needs-human"

scenario "no verdict in such a run, on a person's pull request, and the comment cannot be posted: the job still fails, and says why in its log"
a_review; in_a_run installed
echo octocat > "$T/author"
echo "pr comment 7" > "$T/fail"
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 ""
expect_status 1
expect_output "Ryan (correctness): not reviewed. .github/workflows/ci.yml on main has changed since this run began"
expect_no_call "needs-human"

scenario "no verdict in a run whose ci.yml is main's is an unfinished review, as before"
a_review; in_a_run
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "**Adam (architecture and taste): review not finished.**"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a verdict is posted as given in a run whose ci.yml differs from main's: the reviewer had its token"
a_review; in_a_run installed
OUTPUT='{"findings":[]}' run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 0
expect_posted "**Adam (architecture and taste): PASS**"

scenario "a refused verdict in such a run is still refused: its reviewer ran"
a_review; in_a_run installed
OUTPUT="{\"findings\":[{\"file\":\"b.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"$(words 41)\"}]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "Its verdict was refused"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a finding of no kind in such a run is still refused: its reviewer ran"
a_review; in_a_run installed
OUTPUT='{"findings":[{"file":"b.ts","problem":"Wrong.","fix":"Right it."}]}' run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "and these are not: finding 1"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "no verdict, and main cannot be read to compare: an unfinished review, and a person is asked"
a_review; in_a_run installed
git remote set-url origin "$T/nowhere"
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "review not finished"
[ "$(sed -n 1p "$T/posted")" = "**Adam (architecture and taste): review not finished.** Run the failed jobs again in https://github.com/owner/repo/actions/runs/900: the reviewer then reviews this pull request." ] && [ -z "$(sed -n 2p "$T/posted")" ] \
  || fail "expected the comment's first line to say what a person must do, got: $(head -n 1 "$T/posted")"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a result with no list of findings is an unfinished review too, whatever verdict it names"
for result in '{"verdict":"fail"}' '{"verdict":"pass","findings":"none"}' '[]' 'not json'; do
  a_review
  OUTPUT="$result" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
  expect_status 1
  expect_posted "The review ended without a verdict"
  grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs for: $result"
  [[ "$(cat "$T/posted")" != *": FAIL**"* && "$(cat "$T/posted")" != *": PASS**"* ]] || fail "expected it not to be posted as a verdict: $result"
done

scenario "an unfinished review with no saved result still says what is known"
a_review
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 ""
expect_status 1
expect_posted "The review ended without a verdict: the agent left no result that could be read."
expect_call "gh pr edit 7 --add-label needs-human"

# past_limit <verdict>: the last session finished with this verdict after more turns than its limit (decisions A199).
past_limit() {
  a_review
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed","num_turns":56,"session_id":"c22ab626","structured_output":%s}]\n' "$1" > "$T/session.json"
}

scenario "a pass the action did not give, its session having ended past the turn limit, is posted from the saved result"
past_limit '{"findings":[],"assumptions":[]}'
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 0
expect_posted "**Adam (architecture and taste): PASS**"
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a review with a saved verdict not to be marked cut short"

scenario "a fail the action did not give is posted with its findings and fails the job: a fix round starts"
past_limit '{"findings":[{"file":"a.ts","line":4,"kind":"misbehaves","problem":"Divides by zero.","fix":"Guard the empty list."}]}'
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted '1. **Misbehaves:** `a.ts:4`: Divides by zero.'
expect_no_call "needs-human"
! grep -q cut-short "$T/outputs" || fail "expected a failed review not to be marked cut short"

scenario "a verdict shortened in a continued session past the limit is posted, not the refused one of the session before"
past_limit '{"findings":[{"file":"b.ts","kind":"misbehaves","problem":"Wrong.","fix":"Right it."}]}'
OUTPUT="{\"findings\":[{\"file\":\"b.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"$(words 41)\"}]}" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): FAIL**"
expect_posted "   Fix: Right it."
! grep -q cut-short "$T/outputs" || fail "expected the shortened verdict not to be refused"

scenario "a saved verdict with a field over 40 words is refused like one the action gave"
past_limit "{\"findings\":[{\"file\":\"b.ts\",\"kind\":\"misbehaves\",\"problem\":\"Wrong.\",\"fix\":\"$(words 41)\"}]}"
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "Its verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: finding 1's \`fix\` is 41 words."
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a session past the limit that ended with no verdict is still a review not finished"
past_limit null
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "**Adam (architecture and taste): review not finished.**"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "when the unfinished review cannot be posted, the job fails and still starts no fix round"
a_review
echo "pr comment" > "$T/fail"
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "when the label cannot be added, the job fails and still starts no fix round"
a_review
echo "pr edit" > "$T/fail"
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
expect_posted "review not finished"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a pass that cannot be posted fails the job: nothing merges on a verdict nobody can read"
a_review
echo "pr comment" > "$T/fail"
OUTPUT='{"findings":[]}' run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_failure

# limit_ended <resets>: the review's session ended at the Claude usage limit, which resets then.
limit_ended() {
  printf '[{"type":"system","subtype":"init","session_id":"c22ab626"},{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s}},{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You'\''ve hit your Fable limit · resets Nov 23, 11am (UTC). Switch to another model to continue.","session_id":"c22ab626"}]\n' "$1" > "$T/session.json"
}

scenario "a review the usage limit ended holds every agent until the reset time, keeps its place and asks for no person"
sessions_remote sessions
a_review
limit_ended 99999999999
OUTPUT="" run "$scripts/post-verdict.sh" "Adam (architecture and taste)" 7 "$T/session.json"
expect_status 1
[ "$(the_hold)" = "99999999999"$'\n'"failed 900" ] || fail "expected the reset time, and run 900 to be run again for its failed jobs, got: $(the_hold)"
[ "$(sort -u "$T/outputs")" = "cut-short=true"$'\n'"held=true" ] || fail "expected the job to be marked cut short and held, so no fix round starts, got: $(cat "$T/outputs")"
[[ "$(cat "$T/kept")" == "Nothing to do: Adam's review starts after the Claude usage limit resets on 5138-11-16 09:46 UTC."* ]] \
  || fail "expected the pull request to be told when the review starts, got: $(cat "$T/kept")"
expect_no_call "needs-human"
[ ! -s "$T/posted" ] || fail "expected no other comment, got: $(cat "$T/posted")"

scenario "a review the usage limit ended asks for a person, as any cut short, when the reset time cannot be written"
sessions_remote sessions
refuses_pushes
a_review
limit_ended 99999999999
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): review not finished.**"
expect_posted "The review ended without a verdict: the Claude usage limit was reached"
expect_call "gh pr edit 7 --add-label needs-human"
grep -qxF "cut-short=true" "$T/outputs" || fail "expected cut-short=true in the step's outputs"

scenario "a review ended by a usage limit that has since reset asks for a person too"
sessions_remote sessions
a_review
limit_ended 1000000000
OUTPUT="" run "$scripts/post-verdict.sh" "Ryan (correctness)" 7 "$T/session.json"
expect_status 1
expect_posted "**Ryan (correctness): review not finished.**"
expect_call "gh pr edit 7 --add-label needs-human"
