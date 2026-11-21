#!/usr/bin/env bash
# Holds every agent while the Claude usage limit, which covers the whole account, holds (decisions A231b).
# Usage: usage-limit.sh held                         prints when the limit resets, or nothing when none holds
#        usage-limit.sh hold <resets>                records the reset time a session's result gave, in seconds
#                                                    since 1970, and prints it as `held` does
#        usage-limit.sh wait <number> <what> [failed]
#                                                    as the first step of an agent's run: when the limit holds, it
#                                                    keeps the run's place, tells issue or pull request <number>
#                                                    (none when empty) when <what> starts, prints one sentence and
#                                                    writes held=true to GITHUB_OUTPUT, and kept=true once the run
#                                                    has its place. With `failed` it then exits 1: only the failed
#                                                    jobs of that run are run again.
#        usage-limit.sh ended <execution-file> <number> <what>
#                                                    after an agent's session: when its saved result says the usage
#                                                    limit ended it, does `hold` with the reset time the result
#                                                    gives, then `wait`; any other ending does nothing.
#        usage-limit.sh resume [now]                 once the limit has reset, or at once with `now`: removes the
#                                                    hold, runs each run that waited again and starts the tickets
#                                                    that wait with `ready`. Prints nothing when no hold is recorded.
#        Needs GH_TOKEN and GITHUB_REPOSITORY (contents: read; hold, wait, ended and resume: contents write; wait
#        and ended: issues or pull-requests write; resume: actions write, and what start-waiting.sh needs).
#        A call that fails stops it with a message and exit 1.
set -euo pipefail

usage="Usage: usage-limit.sh held | hold <resets> | wait <number> <what> [failed] | ended <execution-file> <number> <what> | resume [now]"
script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }

# The hold is the file `usage-limit` on the sessions branch: the reset time, then a line for each run that waits
# (decisions A395a, A395b).
record() {
  local answer
  if answer=$(gh api "repos/{owner}/{repo}/contents/usage-limit?ref=sessions" -H "Accept: application/vnd.github.raw" 2>&1); then
    printf '%s\n' "$answer"
  # No file, or no branch yet, is no hold; any other answer is not one.
  elif [[ "$answer" != *"HTTP 404"* ]]; then
    echo "$answer" >&2
    return 1
  fi
}

# resets <record>: the time on its first line, or 0.
resets() {
  local at
  at=$(sed -n 1p <<<"$1")
  [[ "$at" =~ ^[0-9]{1,12}$ ]] || at=0
  echo "$at"
}
in_words() { jq -rn --argjson at "$1" '$at | strftime("%Y-%m-%d %H:%M UTC")'; }

# holds_until: when the recorded limit resets, in words, or nothing when that time has passed or none is recorded.
holds_until() {
  local held at
  held=$(record) || return 1
  at=$(resets "$held")
  [ "$(date +%s)" -ge "$at" ] || in_words "$at"
}

. "$script_dir/sessions-branch.sh"

# What push_to_sessions runs in each fresh clone of the branch, so a lost race writes to what the winner left.
# set_time <clone>: the later of $at and the time the file holds, above the lines of the runs that wait.
set_time() {
  local file="$1/usage-limit" before=0 rest=""
  if [ -f "$file" ]; then
    before=$(resets "$(cat "$file")")
    rest=$(sed 1d "$file")
  fi
  [ "$before" -le "$at" ] || at=$before
  printf '%s\n' "$at" ${rest:+"$rest"} > "$file"
}
# add_run <clone>: $line once, under the time.
add_run() {
  local file="$1/usage-limit"
  [ -f "$file" ] || echo 0 > "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}
remove_hold() { rm -f "$1/usage-limit"; }

case "${1:-}" in
  held)
    holds_until || die "Whether the Claude usage limit holds every agent could not be read from the sessions branch."
    ;;
  hold)
    at="${2:-}"
    [[ "$at" =~ ^[0-9]{1,12}$ ]] || die "$usage"
    push_to_sessions "usage limit: no agent starts until $(in_words "$at")" set_time \
      || die "The Claude usage limit resets on $(in_words "$at"), and that could not be written to the sessions branch, so nothing holds the other agents until then."
    in_words "$at"
    ;;
  wait)
    number="${2:-}"; what="${3:-}"; rerun="${4:-}"
    [[ "$number" =~ ^[0-9]*$ ]] || die "$usage"
    [ -n "$what" ] || die "$usage"
    [ -z "$rerun" ] || [ "$rerun" = failed ] || die "$usage"
    # Written before anything can fail: a review job that fails here must start no fix round (decisions A69e).
    when=$(holds_until) || {
      echo "held=true" >> "${GITHUB_OUTPUT:-/dev/null}"
      die "Whether the Claude usage limit holds every agent could not be read from the sessions branch, so $what did not start."
    }
    [ -n "$when" ] || exit 0
    echo "held=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]] \
      || die "The Claude usage limit holds every agent until $when, and GITHUB_RUN_ID names no run to run again then, so $what has no place."
    line="${rerun:-run} $GITHUB_RUN_ID"
    push_to_sessions "usage limit: run $GITHUB_RUN_ID waits" add_run \
      || die "The Claude usage limit holds every agent until $when, and the place of run $GITHUB_RUN_ID could not be written to the sessions branch: nothing starts $what again."
    echo "kept=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    # The first line says what a person must do (decisions A371a).
    [ -z "$number" ] || gh issue comment "$number" --body "Nothing to do: $what starts after the Claude usage limit resets on $when.

The limit covers the whole account, so no agent starts before then. If the limit was lifted sooner, run \`gh workflow run resume.yml\`: everything that waits starts at once." >/dev/null \
      || die "The Claude usage limit holds every agent until $when, and #$number could not be told that $what starts after it."
    echo "the Claude usage limit holds every agent until $when: $what starts after it"
    [ -z "$rerun" ] || exit 1
    ;;
  ended)
    [ -n "${4:-}" ] || die "$usage"
    # Only a result that names the reset time is acted on: with none, nothing says when to start again (decisions A231b).
    resets=$("$script_dir/session-outcome.sh" "${2:-}" | sed -n 's/^resets=//p')
    [ -n "$resets" ] || exit 0
    "$0" hold "$resets" >/dev/null || exit 1
    exec "$0" wait "${3:-}" "$4"
    ;;
  resume)
    now="${2:-}"
    [ -z "$now" ] || [ "$now" = now ] || die "$usage"
    held=$(record) || die "Whether the Claude usage limit holds every agent could not be read from the sessions branch, so nothing was started again."
    if [ -z "$held" ]; then
      [ -z "$now" ] || echo "No usage limit is recorded: no agent is held, and nothing was started again."
      exit 0
    fi
    at=$(resets "$held")
    if [ -z "$now" ] && [ "$(date +%s)" -lt "$at" ]; then
      echo "The Claude usage limit holds every agent until $(in_words "$at"): nothing was started again."
      exit 0
    fi
    # Removed first: a run started while the hold stands would be held again.
    push_to_sessions "usage limit: the hold is lifted" remove_hold \
      || die "The hold of the Claude usage limit could not be removed from the sessions branch, so nothing was started again."
    echo "The hold of the Claude usage limit is lifted."
    status=0
    while read -r kind run; do
      [[ "$run" =~ ^[0-9]+$ ]] || continue
      # Asked once: a call that failed may still have started it (decisions M26).
      only=()
      [ "$kind" != failed ] || only=(--failed)
      if gh run rerun "$run" "${only[@]}" >/dev/null </dev/null; then
        echo "running again: run $run"
      else
        echo "Run $run waited for the Claude usage limit, and GitHub did not run it again: start what it was for by hand." >&2
        status=1
      fi
    done < <(sed 1d <<<"$held")
    "$script_dir/start-waiting.sh" || {
      echo "The tickets that wait with ready were not all started; each is started when a place next frees." >&2
      status=1
    }
    exit "$status"
    ;;
  *) die "$usage" ;;
esac
