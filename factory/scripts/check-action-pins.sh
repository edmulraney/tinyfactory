#!/usr/bin/env bash
# Fails when a pinned action's commit is not in its repository, or is not the commit behind the tag its comment names.
# Usage: check-action-pins.sh   (from the repo root; GH_TOKEN, GITHUB_TOKEN or a `gh` login lets zizmor ask GitHub)
set -euo pipefail

# Where zizmor is not installed, ci checks the pins (decisions S676b).
if ! command -v zizmor >/dev/null; then
  echo "zizmor is not installed; no pinned action was checked against its repository"
  exit 0
fi
if ! files=$(git ls-files --cached --others --exclude-standard 'factory/workflows/*.yml' '.github/actions/*/action.yml'); then
  echo "check-action-pins.sh must be run inside a git repository: it could not list the workflows and actions with git ls-files, so no pin was checked."
  exit 1
fi
if [ -z "$files" ]; then
  echo "no workflow or action to check"
  exit 0
fi
# Without a token zizmor would skip both audits and pass (decisions S676b).
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
if [ -z "$token" ] && command -v gh >/dev/null; then
  token=$(gh auth token 2>/dev/null || true)
fi
if [ -z "$token" ]; then
  echo "check-action-pins.sh needs a GitHub token to ask GitHub where each pinned commit comes from: set GH_TOKEN or GITHUB_TOKEN, or log in with \`gh auth login\`. No pin was checked."
  exit 1
fi

errors=$(mktemp)
trap 'rm -f "$errors"' EXIT
status=0
# No configuration or ignore comment in the repo can switch the two audits off.
# shellcheck disable=SC2086
report=$(GH_TOKEN="$token" zizmor --format=json --no-config --no-ignores $files 2>"$errors") || status=$?
# zizmor exits 0 with no finding and 10 to 14 with one; any other code is an error, such as GitHub out of reach.
case "$status" in
  0 | 1[0-4]) ;;
  *)
    cat "$errors"
    echo "zizmor failed (exit $status) before it could check every pinned action against GitHub, so no pin was checked. Its message is above."
    exit 1
    ;;
esac
if ! found=$(jq -r '
  .[] | select(.ident == "impostor-commit" or .ident == "ref-version-mismatch")
  | ((first(.locations[] | select(.symbolic.kind == "Primary")) // .locations[0])) as $at
  | "  \($at.symbolic.key.Local.verbatim_path):\($at.concrete.location.start_point.row + 1): \(.ident): \(.desc): \($at.concrete.feature | rtrimstr("\n"))"
' <<<"$report"); then
  echo "check-action-pins.sh could not read zizmor's report, so no pin was checked."
  exit 1
fi
if [ -n "$found" ]; then
  echo "A pinned action's commit is not in the action's repository, or is not the commit behind the tag its comment names. Pin the commit the tag points at, and name that tag in the comment (decisions S668a, S676a):"
  echo "$found"
  exit 1
fi
echo "action pins ok: $(wc -w <<<"$files" | tr -d ' ') files checked"
