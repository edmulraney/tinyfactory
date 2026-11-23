#!/usr/bin/env bash
# Holds every agent while the Claude usage limit holds its model, or starts it on a second one (decisions A231b, A663a).
# Usage: usage-limit.sh held                         prints when the limit resets, or nothing when an agent may
#                                                    start
#        usage-limit.sh hold <resets>                records the reset time a session's result gave, in seconds
#                                                    since 1970, for the model in MODEL when AGENT_MODEL_FALLBACK
#                                                    names a second one and for every model otherwise, and prints
#                                                    the time in words
#        usage-limit.sh wait <number> <what> [failed]
#                                                    as the first step of an agent's run: when the limit holds, it
#                                                    keeps the run's place, tells issue or pull request <number>
#                                                    (none when empty) when <what> starts, prints one sentence and
#                                                    writes held=true to GITHUB_OUTPUT, and kept=true once the run
#                                                    has its place. With `failed` it then exits 1: only the failed
#                                                    jobs of that run are run again. In a later step, with MODEL
#                                                    set, it holds the run only while MODEL is held.
#        usage-limit.sh start <number> <what>        once a job's first step knows its run starts: writes
#                                                    MODEL=<the model its agents run on> to GITHUB_ENV, and when
#                                                    that is the second model, tells issue or pull request <number>
#                                                    (none when empty)
#        usage-limit.sh ended <execution-file> <number> <what>
#                                                    after an agent's session: when its saved result says the usage
#                                                    limit ended it, does `hold` with the reset time the result
#                                                    gives, then `wait`; any other ending does nothing.
#        usage-limit.sh resume [now]                 once the limit has reset, or at once with `now`: removes the
#                                                    hold, runs each run that waited again and starts the tickets
#                                                    that wait with `ready`. Prints nothing when no hold is recorded.
#        AGENT_MODEL names the model an agent runs on and AGENT_MODEL_FALLBACK the second one, in a job that runs
#        one; with neither, a hold of one model holds no job. A second model that is the first is none.
#        Needs GH_TOKEN and GITHUB_REPOSITORY (contents: read; hold, wait, ended and resume: contents write; wait
#        and ended: issues or pull-requests write; resume: actions write, and what start-waiting.sh needs).
#        A call that fails stops it with a message and exit 1.
set -euo pipefail

usage="Usage: usage-limit.sh held | start <number> <what> | hold <resets> | wait <number> <what> [failed] | ended <execution-file> <number> <what> | resume [now]"
script_dir="$(cd "$(dirname "$0")" && pwd)"
die() { echo "$1" >&2; exit 1; }
# Decisions A683b.
[ "${AGENT_MODEL_FALLBACK:-}" != "${AGENT_MODEL:-}" ] || AGENT_MODEL_FALLBACK=""

# The hold is the file `usage-limit` on the sessions branch: the reset time and the model it holds, none naming every
# model, then a line for each run that waits (decisions A395a, A395b, A663a).
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
  at=$(sed -n '1{s/ .*//;p;}' <<<"$1")
  [[ "$at" =~ ^[0-9]{1,12}$ ]] || at=0
  echo "$at"
}
# model_of <record>: the model its first line names, or nothing for every model.
model_of() {
  local model
  model=$(sed -n '1s/^[^ ]* *//p' <<<"$1")
  [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || model=""
  echo "$model"
}
in_words() { jq -rn --argjson at "$1" '$at | strftime("%Y-%m-%d %H:%M UTC")'; }

# gate: sets $when to when the recorded limit resets, in words, while it holds this job, or to nothing; and $model
# to the model the job's agents run on, and $held_model to the one the limit holds. MODEL set means an agent of the
# job has run on it, so only its hold holds the job.
gate() {
  local held
  held=$(record) || return 1
  held_at=$(resets "$held"); held_model=$(model_of "$held")
  when=""; model="${MODEL:-${AGENT_MODEL:-}}"
  [ "$(date +%s)" -lt "$held_at" ] || return 0
  if [ -n "$held_model" ] && [ "$model" != "$held_model" ]; then
    # A hold of one model leaves the second free: it holds no job on another model, nor one that runs no agent.
    return 0
  elif [ -n "$held_model" ] && [ -z "${MODEL:-}" ] && [ -n "${AGENT_MODEL_FALLBACK:-}" ] \
      && [ "$AGENT_MODEL_FALLBACK" != "$held_model" ]; then
    # A job that has not begun on the held model begins on the second one.
    model=$AGENT_MODEL_FALLBACK
  else
    when=$(in_words "$held_at")
  fi
}

. "$script_dir/sessions-branch.sh"

# What push_to_sessions runs in each fresh clone of the branch, so a lost race writes to what the winner left.
# set_time <clone>: the later of $at and the time the file holds, and $holds, above the lines of the runs that wait.
# A hold still ahead of another model, or of every model, makes it hold every model (decisions A663a).
set_time() {
  local file="$1/usage-limit" before=0 named="" rest="" what="$holds"
  if [ -f "$file" ]; then
    before=$(resets "$(cat "$file")")
    named=$(model_of "$(cat "$file")")
    rest=$(sed 1d "$file")
  fi
  [ "$(date +%s)" -ge "$before" ] || [ "$named" = "$what" ] || what=""
  [ "$before" -le "$at" ] || at=$before
  printf '%s\n' "$at${what:+ $what}" ${rest:+"$rest"} > "$file"
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
    gate || die "Whether the Claude usage limit holds every agent could not be read from the sessions branch."
    [ -z "$when" ] || echo "$when"
    ;;
  start)
    number="${2:-}"; what="${3:-}"
    [[ "$number" =~ ^[0-9]*$ ]] && [ -n "$what" ] || die "$usage"
    gate || die "Which model $what runs on could not be read from the sessions branch, so its agents run on the first."
    [ -z "$when" ] && [ -n "$model" ] && [ -z "${MODEL:-}" ] || exit 0
    echo "MODEL=$model" >> "${GITHUB_ENV:-/dev/null}"
    [ "$model" != "${AGENT_MODEL:-}" ] && [ -n "$number" ] || exit 0
    gh issue comment "$number" --body "Nothing to do: $what runs on \`$model\`, the second model, because the Claude usage limit of \`$held_model\` holds until $(in_words "$held_at")." >/dev/null \
      || die "$what runs on $model, and #$number could not be told so."
    echo "$what runs on $model, the second model"
    ;;
  hold)
    at="${2:-}"
    [[ "$at" =~ ^[0-9]{1,12}$ ]] || die "$usage"
    # Only with a second model may another model run, so only then is the hold kept to one (decisions A663a).
    holds=""
    [ -z "${AGENT_MODEL_FALLBACK:-}" ] || [[ ! "${MODEL:-}" =~ ^[A-Za-z0-9._:/-]+$ ]] || holds=$MODEL
    push_to_sessions "usage limit: no agent ${holds:+on $holds }starts until $(in_words "$at")" set_time \
      || die "The Claude usage limit resets on $(in_words "$at"), and that could not be written to the sessions branch, so nothing holds the other agents until then."
    in_words "$at"
    ;;
  wait)
    number="${2:-}"; what="${3:-}"; rerun="${4:-}"
    [[ "$number" =~ ^[0-9]*$ ]] || die "$usage"
    [ -n "$what" ] || die "$usage"
    [ -z "$rerun" ] || [ "$rerun" = failed ] || die "$usage"
    # Written before anything can fail: a review job that fails here must start no fix round (decisions A69e).
    gate || {
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
    why="The limit covers the whole account, so no agent starts before then."
    [ -z "$held_model" ] || [ -z "${AGENT_MODEL_FALLBACK:-}" ] || why="The limit holds \`$held_model\`, which this run began on, and the runs that begin meanwhile run on the second model."
    # The first line says what a person must do (decisions A371a).
    [ -z "$number" ] || gh issue comment "$number" --body "Nothing to do: $what starts after the Claude usage limit resets on $when.

$why If the limit was lifted sooner, run \`gh workflow run resume.yml\`: everything that waits starts at once." >/dev/null \
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
      if gh run rerun "$run" ${only[@]+"${only[@]}"} >/dev/null </dev/null; then
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
