#!/usr/bin/env bash
# Decides, in implement.yml, whether a ticket's build may start: a trusted account opened it, and a place is free.
# Usage: start-build.sh <issue-number>
#        Needs GH_TOKEN (issues: write; pull requests and contents: read) and GITHUB_REPOSITORY.
#        GITHUB_EVENT_NAME, which a workflow sets, says whether the ticket's label or another workflow started the run.
set -euo pipefail

issue="${1:?Usage: start-build.sh <issue-number>}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
outputs="${GITHUB_OUTPUT:-/dev/null}"

# A refusal exits 0: the workflow runs no later step and ends green, so it starts no retro (decisions T64f).
refuse() { echo "start=false" >> "$outputs"; echo "not started: $1"; exit 0; }
die() { echo "start=false" >> "$outputs"; echo "$1" >&2; exit 1; }

# The number goes into calls and a pattern, so anything that is not one is refused.
[[ "$issue" =~ ^[0-9]+$ ]] || die "\"$issue\" is not an issue number."

# others <list>: how many of its lines are another ticket's.
others() { grep -v "^$issue " <<<"$1" | grep -c . || true; }

# no_place <list>: prints why no place is free for this ticket, as `in-flight.sh full` does, or nothing when one is.
no_place() { { grep -v "^$issue " <<<"$1" || true; } | "$script_dir/in-flight.sh" full; }

# full <what no_place printed> <note>: tells the ticket what is at its limit, and what holds each place.
full() {
  local body
  # A ticket the waiting were started from was told when it was labelled (decisions T64c).
  [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ] || return 0
  body="Waiting: $(sed -n 1p <<<"$1"), and that is the most the factory allows at once.

$(sed -n '3,$p' <<<"$1" | sed -E 's/^[0-9-]+ /- /')

This ticket keeps the \`ready\` label, and its build starts when $(sed -n 2p <<<"$1").$2"
  gh issue comment "$issue" --body "$body" >/dev/null
}

# A run whose ticket no longer carries ready was overtaken by another start of it (decisions T269b).
labels=$(gh issue view "$issue" --json labels --jq '[.labels[].name] | join(" ")') \
  || die "Issue #$issue was not started: its labels could not be read from GitHub. It keeps the ready label; take it off and add it again to start the build."
case " $labels " in
  *" ready "*) ;;
  *) refuse "issue #$issue does not carry ready: another run started its build, or the label was taken off" ;;
esac

# A ticket's text stays its author's to edit, so none is built that an account the factory does not act for opened (decisions T563f).
author=$(gh api "repos/{owner}/{repo}/issues/$issue" --jq '.user.login // ""') \
  || die "Issue #$issue was not started: who opened it could not be read from GitHub. It keeps the ready label; take it off and add it again to start the build."
trusted=0
"$script_dir/trusted.sh" "$author" || trusted=$?
if [ "$trusted" -eq 1 ]; then
  by="\`$author\`"
  [ -n "$author" ] || by="an account GitHub no longer names"
  # The first line says what a person must do (decisions A371a). ready comes off, or start-waiting.sh would start it again.
  gh issue comment "$issue" --body "File this ticket again from an account that may write to this repository, if it is to be built.

Not started: $by opened this ticket and may not write to this repository. A ticket's text stays its author's to change, so the factory builds only a ticket opened by an account that may write here, or by the factory itself. The \`ready\` label was taken off." >/dev/null \
    && gh issue edit "$issue" --remove-label ready --add-label needs-human >/dev/null \
    || die "Issue #$issue was not started, because an account that may not write to this repository opened it, but it could not be told so and flagged for a person. It may still carry the ready label."
  refuse "issue #$issue was opened by ${author:-an account GitHub no longer names}, who may not write to this repository: it was told so and flagged for a person"
fi
[ "$trusted" -eq 0 ] \
  || die "Issue #$issue was not started: whether $author, who opened it, may write to this repository is not known. It keeps the ready label; take it off and add it again to start the build."

in_flight=$("$script_dir/in-flight.sh") \
  || die "Issue #$issue was not started: what is in flight could not be read from GitHub. It keeps the ready label; take it off and add it again to start the build."

# A draft left unfinished is the work this build carries on from (decisions T64h).
if grep "^$issue " <<<"$in_flight" | grep -qv "left unfinished)$"; then
  # The label may be one no build holds, so the ticket is told how to free it (decisions T64e).
  if grep -q "^$issue .*(being built" <<<"$in_flight"; then
    gh issue comment "$issue" --body "Not started again: this ticket is labelled \`in-progress\`, so a build of it is running, or one ended without giving its place back. If no build of it is running, take \`in-progress\` off and add the \`ready\` label again." >/dev/null \
      || die "Issue #$issue is already in flight and was not started again, but it could not be told so. It keeps the ready label."
  fi
  gh issue edit "$issue" --remove-label ready >/dev/null \
    || die "Issue #$issue is already in flight and was not started again, but the ready label could not be taken off it."
  refuse "issue #$issue is already in flight: $(grep "^$issue " <<<"$in_flight" | cut -d' ' -f2-)"
fi

# ready stays on, and start-waiting.sh starts the ticket when a place frees (decisions T64c, T269a).
taken=$(no_place "$in_flight")
if [ -n "$taken" ]; then
  why=$(sed -n 1p <<<"$taken")
  full "$taken" "" \
    || die "Issue #$issue waits, because $why, but it could not be told so. It keeps the ready label, and is started when a place frees."
  refuse "$why, so issue #$issue waits with ready until a place frees"
fi

# No build starts while the Claude usage limit holds every agent: ready stays on, and usage-limit.sh starts the ticket (decisions A231b).
limit=$("$script_dir/usage-limit.sh" held) \
  || die "Issue #$issue was not started: whether the Claude usage limit holds every agent could not be read from GitHub. It keeps the ready label; take it off and add it again to start the build."
if [ -n "$limit" ]; then
  if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]; then
    resume_page=$("$script_dir/workflow-page.sh" resume.yml)
    gh issue comment "$issue" --body "Waiting: the Claude usage limit covers the whole account, and no agent starts until it resets on $limit. This ticket keeps the \`ready\` label, and its build starts after that. If the limit was lifted sooner, start everything that waits at once on $resume_page." >/dev/null \
      || die "Issue #$issue waits, because the Claude usage limit holds every agent until $limit, but it could not be told so. It keeps the ready label, and is started after the limit resets."
  fi
  refuse "the Claude usage limit holds every agent until $limit, so issue #$issue waits with ready"
fi

# A free place goes to the first ticket in the queue, and a newly labelled one takes it only in its turn (decisions T323, T335a).
if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]; then
  turn=0
  "$script_dir/start-waiting.sh" "$issue" || turn=$?
  if [ "$turn" -eq 3 ]; then
    gh issue comment "$issue" --body "Waiting: a place was free, and it went to a ticket ahead of this one in the queue. This ticket keeps the \`ready\` label, and its build starts when a place frees." >/dev/null \
      || die "Issue #$issue waits, because the free place went to a ticket ahead of it in the queue, but it could not be told so. It keeps the ready label, and is started when a place frees."
    refuse "the free place went to a ticket ahead of it in the queue, so issue #$issue waits with ready until a place frees"
  fi
  # start-waiting.sh told the ticket which one (decisions T339a).
  [ "$turn" -ne 4 ] || refuse "issue #$issue comes after a ticket that is still open, so it waits with ready until that ticket closes"
  [ "$turn" -eq 0 ] \
    || die "Issue #$issue was not started: start-waiting.sh could not settle its turn in the queue, for the reason it gives above. It keeps the ready label; take it off and add it again to start the build."
fi

# gh refuses an edit naming a label the repo does not have, so proposal is named only for a ticket that carries it (decisions T158).
# Each is expanded as ${name[@]+"${name[@]}"}: a Mac's bash 3.2 takes an empty array for an unset variable under `set -u`.
accepted=() unaccepted=()
[[ " $labels " != *" proposal "* ]] || { accepted=(--remove-label proposal); unaccepted=(--add-label proposal); }

# needs-human comes off, so that after the engineer's step it means this build stopped on purpose (decisions A69h).
gh issue edit "$issue" --remove-label ready --remove-label needs-human ${accepted[@]+"${accepted[@]}"} --add-label in-progress >/dev/null \
  || die "Issue #$issue was not started: it could not be labelled in-progress."

# From here the ticket holds a place, and every ending but a start gives it back.
give_back() {
  gh issue edit "$issue" --remove-label in-progress ${unaccepted[@]+"${unaccepted[@]}"} >/dev/null \
    || die "Issue #$issue was not started ($1), and in-progress could not be taken off it: it holds a place with no build until the label is removed by hand."
}

# Tickets labelled at the same moment each now see the other (decisions T64d).
in_flight_now=$("$script_dir/in-flight.sh") || {
  give_back "what is in flight could not be read from GitHub a second time"
  die "Issue #$issue was not started: what is in flight could not be read from GitHub a second time. Its place was given back; add the ready label again to start the build."
}
taken=$(no_place "$in_flight_now")
if [ -n "$taken" ]; then
  # GitHub lists the newest first: a ticket labelled in-progress after this one steps back before it does (decisions T64d).
  later=$(gh api "repos/{owner}/{repo}/issues/events?per_page=100" \
      --jq "[.[] | select(.event == \"labeled\" and .label.name == \"in-progress\") | .issue.number] | index($issue) as \$mine | if \$mine == null then empty else .[:\$mine][] end") || {
    give_back "which ticket took its place first could not be read from GitHub"
    die "Issue #$issue was not started: another ticket asked for the last place at the same moment, and which took it first could not be read from GitHub. Its place was given back; add the ready label again to start the build."
  }
  # With or without a draft: one left unfinished held no place while its ticket waited with ready (decisions T505c).
  while read -r number; do
    [ -z "$number" ] || in_flight_now=$(grep -vE "^$number #$number \(being built(, in [^)]*)?\)$" <<<"$in_flight_now" || true)
  done <<<"$later"
  taken=$(no_place "$in_flight_now")
fi
if [ -n "$taken" ]; then
  gh issue edit "$issue" --remove-label in-progress --add-label ready ${unaccepted[@]+"${unaccepted[@]}"} >/dev/null \
    || die "Issue #$issue was not started (another ticket took the last place at the same moment), and its labels could not be put back: it holds a place with no build until in-progress is removed by hand."
  full "$taken" " Another ticket asked for the last place at the same moment as this one, and took it." \
    || die "Issue #$issue waits, because another ticket took the last place at the same moment, but it could not be told so. Its place was given back, and it is started when a place frees."
  refuse "another ticket took the last place at the same moment as issue #$issue, which waits with ready until a place frees"
fi

# Its agents run on the second model while the first's limit holds it; a run whose model cannot be read starts on the first (decisions A663a).
"$script_dir/usage-limit.sh" start "$issue" "its build" >&2 || echo "Issue #$issue: its build runs on the first model." >&2
echo "start=true" >> "$outputs"
echo "started: issue #$issue takes a place, with $(others "$in_flight_now") other tickets in flight"
