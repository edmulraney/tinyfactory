#!/usr/bin/env bash
# Prints the factory's events as a table: each workflow's trigger, what it does and what starts it (decisions H293a).
# Usage: events.sh   (from the repo root)
set -euo pipefail

die() { echo "$1" >&2; exit 1; }

set -- factory/workflows/*.yml
[ -f "$1" ] || die "factory/workflows/ holds no workflow, so there is no event to print. Run events.sh from the repo root."

# Where a `gh workflow run` can be: the scripts, the bootstrap's, and the workflows themselves.
# One inside backticks is a message telling a person what to run, and starts nothing.
starters=()
for file in factory/scripts/*.sh .claude/skills/bootstrap/scripts/*.sh "$@"; do
  [ ! -f "$file" ] || starters+=("$file")
done

table="| Workflow | Starts on | What it does | Started by |
|---|---|---|---|"
for workflow in "$@"; do
  name=$(basename "$workflow" .yml)
  description=$(sed -n '1s/^# *//p' "$workflow")
  [ -n "$description" ] || die "$workflow has no opening comment, so what it does is not known. Its first line is a comment saying so (decisions H176a)."
  # One event a line under `on:`, with what narrows it: its types, branches, paths, schedule, inputs.
  trigger=$(awk '
    function flush() {
      if (event == "") return
      printed = printed (printed == "" ? "" : "; ") event (detail == "" ? "" : " (" detail ")")
      event = ""; detail = ""
    }
    function clean(text) { gsub(/[]["\047[]/, "", text); gsub(/, */, " ", text); sub(/[ \t]+$/, "", text); return text }
    /^["\047]?on["\047]?:/ {
      inside = 1
      sub(/^[^:]*:[ \t]*/, "")
      if ($0 != "") { printed = clean($0); exit }
      next
    }
    !inside || /^[ \t]*(#|$)/ { next }
    /^[^ ]/ { exit }
    /^  [^ ]/ { flush(); event = $0; sub(/^  /, "", event); sub(/:.*/, "", event); next }
    /^    [^ ]/ {
      line = $0
      sub(/^    (- )?/, "", line)
      detail = detail (detail == "" ? "" : ", ") clean(line)
      listed = line ~ /:$/
      next
    }
    /^      [^ ]/ && listed {
      line = $0
      sub(/^      (- )?/, "", line); sub(/:.*/, "", line)
      detail = detail " " clean(line)
    }
    END { flush(); print printed }
  ' "$workflow")
  [ -n "$trigger" ] || die "$workflow has no \`on:\`, so what starts it is not known."
  by=""
  for file in "${starters[@]}"; do
    [ "$file" != "$workflow" ] || continue
    if grep -Eq "(^|[^\`])gh workflow run $name(\.yml)?([^A-Za-z0-9_.-]|\$)" "$file"; then
      by+="${by:+, }\`$(basename "$file")\`"
    fi
  done
  row="| \`$name.yml\` | ${trigger//|/\\|} | ${description//|/\\|} | ${by:-no script or workflow} |"
  table+=$'\n'"$row"
done
printf '%s\n' "$table"
