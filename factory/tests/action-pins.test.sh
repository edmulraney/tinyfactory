#!/usr/bin/env bash
# Tests that every third-party action the workflows run is pinned by a commit id (decisions S668a).
. "$(dirname "$0")/helpers.sh"

# The actions the workflows and the repo's own actions use, one `<file>:<line>: <action>@<ref>` each.
used() {
  grep -n -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$root"/factory/workflows/*.yml "$root"/.github/actions/*/action.yml \
    | sed -E "s|^$root/||; s/^([^:]*:[0-9]+):[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]]+).*/\\1: \\3/"
}

scenario "every action from outside GitHub and this repo is pinned by a 40-character commit id"
found=$(used | grep -v -E ': (actions/[^@]+@|\./)' | grep -v -E '@[0-9a-f]{40}$' || true)
[ -z "$found" ] || fail "expected a commit id after each third-party action's @, got:
$found"
[ "$(used | grep -c -v -E ': (actions/[^@]+@|\./)')" -gt 0 ] || fail "expected the workflows to use at least one third-party action"
