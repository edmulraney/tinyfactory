#!/usr/bin/env bash
# Tests that every agent a workflow runs takes its model and effort from the owner's two variables (decisions A504a).
. "$(dirname "$0")/helpers.sh"

# shellcheck disable=SC2016
model='--model ${{ vars.AGENT_MODEL || '\''claude-fable-5-2'\'' }}'
# shellcheck disable=SC2016
effort='--effort ${{ vars.AGENT_EFFORT || '\''medium'\'' }}'

lines() { grep -n -v '^[[:space:]]*#' "$root"/factory/workflows/*.yml | sed "s|^$root/||"; }
# with_variables <model> <effort>: the lines that give an agent its model, as GitHub fills them in with the two
# variables holding these values; an empty value is a variable that is not set.
with_variables() {
  lines | grep -e '--model \${{' | sed -E \
    -e "s/\\$\\{\\{ vars\\.AGENT_MODEL \\|\\| '([^']*)' \\}\\}/${1:-\\1}/" \
    -e "s/\\$\\{\\{ vars\\.AGENT_EFFORT \\|\\| '([^']*)' \\}\\}/${2:-\\1}/"
}

scenario "no workflow names a model or an effort except through the two variables"
rest=$(lines | awk -v model="$model" -v effort="$effort" '{
  while ((at = index($0, model))) $0 = substr($0, 1, at - 1) substr($0, at + length(model))
  while ((at = index($0, effort))) $0 = substr($0, 1, at - 1) substr($0, at + length(effort))
  print
}')
found=$(grep -E -e '--(model|effort)([ =]|$)|claude-[a-z]+-[0-9]|AGENT_(MODEL|EFFORT)' <<<"$rest" || true)
[ -z "$found" ] || fail "expected a model or an effort only as \`$model $effort\`, got:
$found"

scenario "every agent a workflow runs is given the two variables"
for file in "$root"/factory/workflows/*.yml; do
  agents=$(grep -c -E 'uses: anthropics/claude-code-action@|^[[:space:]]*(claude -p|factory/scripts/review\.sh sessions) ' "$file" || true)
  given=$(grep -c -F -- "$model $effort" "$file" || true)
  [ "$agents" = "$given" ] || fail "expected each of the $agents agents of ${file##*/} to be given \`$model $effort\`, and $given are"
done
[ "$(lines | grep -c -F -- "$model $effort")" -gt 0 ] || fail "expected the workflows to run at least one agent"

scenario "with both variables unset, each agent's line reads claude-fable-5-2 and medium"
wrong=$(with_variables "" "" | grep -v -E -e '--model claude-fable-5-2 --effort medium( |$)' || true)
[ -z "$wrong" ] || fail "expected each line to read \`--model claude-fable-5-2 --effort medium\`, got:
$wrong"
[ -n "$(with_variables "" "")" ] || fail "expected at least one agent's line"

scenario "with both variables set, each agent's line reads the model and the effort they hold"
wrong=$(with_variables claude-opus-5-5 xhigh | grep -v -E -e '--model claude-opus-5-5 --effort xhigh( |$)' || true)
[ -z "$wrong" ] || fail "expected each line to read \`--model claude-opus-5-5 --effort xhigh\`, got:
$wrong"
[ -n "$(with_variables claude-opus-5-5 xhigh)" ] || fail "expected at least one agent's line"
