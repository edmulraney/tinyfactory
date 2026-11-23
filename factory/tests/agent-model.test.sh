#!/usr/bin/env bash
# Tests that every agent a workflow runs takes its model and effort as the owner's variables say (decisions A663a).
. "$(dirname "$0")/helpers.sh"

# shellcheck disable=SC2016
model='--model ${{ env.MODEL || env.AGENT_MODEL }}'
# shellcheck disable=SC2016
plain='--model ${{ vars.AGENT_MODEL || '\''claude-fable-5-2'\'' }}'
# shellcheck disable=SC2016
effort='--effort ${{ vars.AGENT_EFFORT || '\''medium'\'' }}'
# shellcheck disable=SC2016
first='  AGENT_MODEL: ${{ vars.AGENT_MODEL || '\''claude-fable-5-2'\'' }}'
# shellcheck disable=SC2016
second='  AGENT_MODEL_FALLBACK: ${{ vars.AGENT_MODEL_FALLBACK || '\''claude-opus-5-5'\'' }}'

lines() { grep -n -v '^[[:space:]]*#' "$root"/factory/workflows/*.yml | sed "s|^$root/||"; }
agents() { grep -c -E 'uses: anthropics/claude-code-action@|^[[:space:]]*(claude -p|factory/scripts/review\.sh sessions) ' "$1" || true; }
# A job's first step, which writes MODEL: each script that decides whether an agent's run starts calls usage-limit.sh.
gated() { grep -q -E 'usage-limit\.sh (wait|start)|start-build\.sh|begin-fix-round\.sh|start-refine\.sh' "$1"; }
# model_for <file>: the model a workflow's agents are given; one with no such first step reads the variable itself.
model_for() { if gated "$1"; then echo "$model"; else echo "$plain"; fi; }

scenario "no workflow names a model or an effort except through the owner's variables"
rest=$(lines | awk -v model="$model" -v plain="$plain" -v effort="$effort" -v first="$first" -v second="$second" '{
  while ((at = index($0, model))) $0 = substr($0, 1, at - 1) substr($0, at + length(model))
  while ((at = index($0, plain))) $0 = substr($0, 1, at - 1) substr($0, at + length(plain))
  while ((at = index($0, effort))) $0 = substr($0, 1, at - 1) substr($0, at + length(effort))
  line = $0; sub(/^[^:]*:[0-9]+:/, "", line)
  if (line == first || line == second) next
  print
}')
found=$(grep -E -e '--(model|effort)([ =]|$)|claude-[a-z]+-[0-9]|AGENT_(MODEL|EFFORT)|env\.MODEL' <<<"$rest" || true)
[ -z "$found" ] || fail "expected a model or an effort only as \`$model $effort\` or \`$plain $effort\`, and the variables only in the workflow's env, got:
$found"

scenario "every agent a workflow runs is given the model and the effort, and a workflow that writes MODEL names the first model"
for file in "$root"/factory/workflows/*.yml; do
  count=$(agents "$file")
  given=$(grep -c -F -- "$(model_for "$file") $effort" "$file" || true)
  [ "$count" = "$given" ] || fail "expected each of the $count agents of ${file##*/} to be given \`$(model_for "$file") $effort\`, and $given are"
  [ "$count" = 0 ] || ! gated "$file" || grep -qxF -- "$first" "$file" || fail "expected ${file##*/}, which runs an agent, to define AGENT_MODEL in its env"
done
[ "$(lines | grep -c -F -- "$model $effort")" -gt 0 ] && [ "$(lines | grep -c -F -- "$plain $effort")" -gt 0 ] || fail "expected the workflows to run at least one agent"

scenario "a workflow whose first step decides whether its agents start names the second model, and only such a one"
for file in "$root"/factory/workflows/*.yml; do
  if [ "$(agents "$file")" != 0 ] && gated "$file"; then
    grep -qxF -- "$second" "$file" || fail "expected ${file##*/} to define AGENT_MODEL_FALLBACK in its env"
  else
    ! grep -qF -- "$second" "$file" || fail "expected ${file##*/}, which chooses no model, not to define AGENT_MODEL_FALLBACK"
  fi
done
