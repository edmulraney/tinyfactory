#!/usr/bin/env bash
# Keeps the reviewers' notes in one ticket, and starts the build of that ticket.
# Usage: review-notes.sh keep "<reviewer name>" <pr-number> < notes   adds the notes, as post-verdict.sh prints them
#        review-notes.sh start                                       starts the build of the oldest ticket holding notes
#        Needs GH_TOKEN (issues: write; pull-requests: read; for `start`, actions: write).
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
titled="Apply the review notes of week "
die() { echo "$1" >&2; exit 1; }

# The tickets a note may still join, oldest first (decisions A241b). Listed: a search would miss one seconds old.
# collecting unflagged: only those not labelled needs-human, which wait for the owner (decisions A241f).
collecting() {
  local tickets in_flight held flagged=""
  [ "${1:-}" != unflagged ] || flagged=' and ([.labels[].name] | index("needs-human") == null)'
  tickets=$(gh api "repos/{owner}/{repo}/issues?state=open&labels=factory&per_page=100" --paginate \
    --jq ".[] | select(.pull_request == null and (.title | startswith(\"$titled\"))$flagged) | .number") || return 1
  [ -n "$tickets" ] || return 0
  in_flight=$("$script_dir/in-flight.sh") || return 1
  # A build cut short at a draft starts again from its ticket (decisions T64h).
  held=$(grep -v 'left unfinished)$' <<<"$in_flight" | cut -d' ' -f1)
  grep -vxF -e "$held" <<<"$tickets" | sort -n || true
}

case "${1:-}" in
  keep)
    reviewer="${2:?Usage: review-notes.sh keep \"<reviewer name>\" <pr-number> < notes}"
    pr="${3:?Usage: review-notes.sh keep \"<reviewer name>\" <pr-number> < notes}"
    notes=$(cat)
    [ -n "$notes" ] || exit 0
    tickets=$(collecting) \
      || die "The notes of $reviewer on pull request #$pr were not kept: the ticket that collects them could not be looked for."
    ticket=$(sed -n 1p <<<"$tickets")
    made=""
    if [ -z "$ticket" ]; then
      # The engineer is told here, in a ticket read once a week, not in a skill read on every build (decisions A241d).
      body="## Change
Apply the reviewers' notes: each is in a comment on this ticket headed by a reviewer's name and a pull request's number (\`gh issue view <this ticket> --comments\`); skip any other comment. A note fails no review, so nothing else acts on one.

- Apply each note in the file it names, \`apps/\` included, or answer it in one line saying why not.
- Put the answers in one comment on this ticket, and name there each kind of note seen three times: a repeat is a rule or a check that is missing.

## How we will know it works
- \`pnpm lint\` and \`pnpm test\` pass.
- Every note is applied, or answered in that comment."
      url=$(gh issue create --title "$titled$((10#$(date -u +%V)))" --label factory --body "$body") \
        || die "The notes of $reviewer on pull request #$pr were not kept: the ticket for them could not be made."
      ticket=${url##*/}
      [[ "$ticket" =~ ^[0-9]+$ ]] \
        || die "The notes of $reviewer on pull request #$pr were not kept: GitHub did not say which ticket it made for them."
      made=yes
    fi
    comment="**$reviewer** on pull request #$pr:

$notes"
    # A stray mention would start another agent run.
    if ! gh issue comment "$ticket" --body "$(sed 's/@claude/claude/g' <<<"$comment")" >/dev/null; then
      [ -z "$made" ] || gh issue close "$ticket" --reason "not planned" >/dev/null \
        || die "The notes of $reviewer on pull request #$pr were not kept, and issue #$ticket, made for them, is open with no note in it: close it."
      die "The notes of $reviewer on pull request #$pr were not kept: issue #$ticket could not be commented on."
    fi
    echo "the notes of $reviewer on pull request #$pr are kept in issue #$ticket"
    ;;
  start)
    tickets=$(collecting unflagged) || die "No build was started: the tickets that hold review notes could not be looked for."
    # One build a week: a second ticket, made by two reviews seconds apart, takes the notes that come next (decisions A241f).
    ticket=$(sed -n 1p <<<"$tickets")
    [ -n "$ticket" ] || { echo "no ticket holds review notes that wait to be applied: nothing was started"; exit 0; }
    # ready, as no build starts without it, and by number: a workflow's own token adding the label starts none (decisions A241c).
    if gh issue edit "$ticket" --add-label ready >/dev/null && gh workflow run implement.yml -f issue="$ticket" >/dev/null; then
      echo "started the build of issue #$ticket"
      exit 0
    fi
    echo "The build of issue #$ticket could not be started." >&2
    gh issue comment "$ticket" --body "Add the \`ready\` label: the build of this ticket starts when a place is free.

This week's build of this ticket could not be started by itself." >/dev/null \
      && gh issue edit "$ticket" --remove-label ready --add-label needs-human >/dev/null \
      || echo "Issue #$ticket could not be told so, or flagged for a person." >&2
    exit 1
    ;;
  *) die "Usage: review-notes.sh keep \"<reviewer name>\" <pr-number> < notes | review-notes.sh start" ;;
esac
