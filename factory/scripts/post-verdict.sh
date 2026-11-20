#!/usr/bin/env bash
# Posts a reviewer's verdict: a fail exits 1, so its job is red; an unfinished review asks for a person instead.
# Usage: OUTPUT='<json>' [HEAD_SHA=<commit>] post-verdict.sh "<reviewer name>" <pr-number> [<execution-file>]
#        The execution file is the last session's saved result, read for the verdict and the cause.
#        Needs GH_TOKEN (pull-requests and issues: write; contents: write, to hold every agent when the usage limit ended the review).
set -euo pipefail

reviewer="$1"; pr="$2"; file="${3:-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
# The action gives no verdict for a session it counts past `--max-turns` (decisions A199).
OUTPUT=$("$script_dir/review-verdict.sh" "$file"); export OUTPUT
# A reviewer gives its own kinds, or those from before the install (decisions A256a, A256e).
case "$reviewer" in
  Ryan*) own=bug ;;
  Adam*) own=design ;;
  *)
    # Marked first, as below: a verdict nobody can judge starts no fix round.
    echo "cut-short=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "post-verdict.sh: the reviewer is Ryan or Adam, and \"$reviewer\" is neither, so its kinds of finding are not known. Nothing was posted." >&2
    exit 1 ;;
esac
# These kinds never fail (decisions A182a, A256d).
passing='.kind == "out-of-scope" or .kind == "note"'
# A kind that is not the reviewer's is its own text, so it is never printed (decisions A182c).
state=$(jq -r --arg own "$own" '
  if type != "object" or (.findings | type) != "array" then empty else
    [.findings | to_entries[]
      | select((.value | type) != "object" or (.value.kind | type) != "string"
          or (.value.kind | IN($own, "out-of-scope", "misbehaves", "unproven", "breaks-rule", "note") | not))
      | "finding \(.key + 1)"] as $unkind
    | if $unkind != [] then "unkind \($unkind | join(", "))"
      elif any(.findings[]; '"$passing"' | not) then "fail" else "pass" end
  end' <<<"${OUTPUT:-}" 2>/dev/null || true)
verdict=""; unkind=""; long=""
case "$state" in
  pass|fail) verdict=$state; long=$("$script_dir/long-fields.sh") ;;
  "unkind "*) unkind=${state#unkind } ;;
esac
# No verdict, or one refused for being over a limit, has not failed the pull request (decisions A69e, A169b, A224a).
if [ -z "$verdict" ] || [ -n "$long" ]; then
  # Asked before anything is written; not for a refused verdict, whose reviewer ran so had its token (decisions A142c).
  behind=""
  [ -n "$verdict" ] || [ -n "$unkind" ] || behind=$("$script_dir/workflow-behind.sh") || behind=""
  if [ -n "$behind" ]; then
    echo "$reviewer: not reviewed. $behind"
    # An author that could not be read is taken for a person: a comment too many does no harm (decisions A142e).
    author=$(gh pr view "$pr" --json author --jq .author.login) || author=""
    [ "$author" = app/claude ] || gh pr comment "$pr" --body "**$reviewer: not reviewed.** $behind"
    exit 1
  fi
  # Written first: if GitHub cannot be told, the job still fails, and still starts no fix round.
  echo "cut-short=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  refused="It is not posted, so no fix round starts, and this pull request does not merge until it has been reviewed."
  if [ -n "$long" ]; then
    message="Its verdict was refused, because a field holds 40 words at most and a verdict 3 assumptions: $long. $refused"
  elif [ -n "$unkind" ]; then
    message="Its verdict was refused, because each of its findings is \`$own\` or \`out-of-scope\`, and these are not: $unkind. $refused"
  else
    outcome=$("$script_dir/session-outcome.sh" "$file")
    cause=$(sed -n 's/^cause=//p' <<<"$outcome")
    # A review the usage limit ended waits for the reset and not for a person; held, the call exits 1 (decisions A395c).
    resets=$(sed -n 's/^resets=//p' <<<"$outcome")
    if [ -n "$resets" ] && "$script_dir/usage-limit.sh" hold "$resets" >/dev/null; then
      "$script_dir/usage-limit.sh" wait "$pr" "${reviewer%% *}'s review" failed || exit 1
    fi
    message="The review ended without a verdict: $cause. Nothing is known to be wrong with this pull request, so no fix round starts, and it does not merge until it has been reviewed."
  fi
  run_link=""
  [ -z "${GITHUB_RUN_ID:-}" ] || run_link=" in $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  # The first line says what a person must do, after the name a reviewer's comment is found by (decisions A371a, A371c).
  gh pr comment "$pr" --body "**$reviewer: review not finished.** Run the failed jobs again$run_link: the reviewer then reviews this pull request.

$message"
  gh pr edit "$pr" --add-label needs-human >/dev/null
  echo "$reviewer: review not finished. $message"
  exit 1
fi

# A run whose workflow is from before the install still returns `unverified`, in its three parts (decisions A224b).
assumptions=$(jq -c '.assumptions // [(.unverified // [])[] | {assumes: .claim, if_wrong: .risk}]' <<<"$OUTPUT")

# The findings $1 chooses, numbered from 1, each blocking one led by its kind.
findings() {
  jq -r --argjson kinds '{"bug":"Bug","design":"Design","misbehaves":"Misbehaves","unproven":"Unproven","breaks-rule":"Breaks a rule"}' "
    [.findings[] | select($1)] | to_entries[] | .value as \$f
    | \"\(.key + 1). \(\$kinds[\$f.kind] | if . then \"**\(.):** \" else \"\" end)\`\(\$f.file)\(if \$f.line then \":\(\$f.line)\" else \"\" end)\`: \(\$f.problem)\n   Fix: \(\$f.fix)\"" <<<"$OUTPUT"
}
notes=$(findings "$passing")

{
  echo "**$reviewer: $(tr '[:lower:]' '[:upper:]' <<<"$verdict")**"
  if [ "$verdict" = fail ]; then
    echo
    findings "($passing) | not"
  fi
  # The heading tells whoever fixes a fail which findings it may leave (decisions A182b).
  if [ -n "$notes" ]; then
    echo
    echo "**Out of scope: nothing here has to change**"
    echo
    echo "$notes"
  fi
  # What the pull request rests on unchecked (decisions A55b). A fail does not print it (decisions A169a).
  if [ "$verdict" = pass ] && [ "$(jq 'length' <<<"$assumptions")" -gt 0 ]; then
    echo
    echo "**Assumptions**"
    echo
    jq -r 'to_entries[] | "\(.key + 1). Assumes: \(.value.assumes)\n   If wrong: \(.value.if_wrong)"' <<<"$assumptions"
  fi
  # For carry-review.sh: without this line the verdict is never carried (decisions A160c).
  echo
  [[ ! "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || echo "<!-- factory:reviewed $HEAD_SHA -->"
  # Always the last line, for merge-gate.sh and run-facts.sh (decisions A55c); `>` is escaped so no claim ends it early.
  jq -r 'tojson | gsub(">"; "\\u003e") | "<!-- factory:assumptions \(.) -->"' <<<"$assumptions"
} | sed 's/@claude/claude/g' > "${RUNNER_TEMP:-/tmp}/verdict.md"   # a stray mention would start another agent run

gh pr comment "$pr" --body-file "${RUNNER_TEMP:-/tmp}/verdict.md"
# Nothing else acts on these, and ones that could not be kept fail no review (decisions A241a).
[ -z "$notes" ] || "$script_dir/review-notes.sh" keep "$reviewer" "$pr" <<<"$notes" \
  || echo "$reviewer: the review stands; its notes are only in its comment on pull request #$pr."
[ "$verdict" = pass ]
