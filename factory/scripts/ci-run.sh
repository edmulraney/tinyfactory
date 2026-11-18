#!/usr/bin/env bash
# Prints the ci run that judges a commit: the newest one for it that was not skipped, or nothing.
# Usage: ci-run.sh <commit> <fields>
#        The fields are those of `gh run list --json`, comma-separated: `databaseId,status` prints "900 completed".
#        Needs GH_TOKEN (actions: read).
set -euo pipefail

commit="${1:?Usage: ci-run.sh <commit> <fields>}"; fields="${2:?Usage: ci-run.sh <commit> <fields>}"

case ",$fields," in
  *,,* | *[!a-zA-Z,]*) echo "ci-run.sh: the fields must be names separated by commas, not: $fields" >&2; exit 1 ;;
esac
# The conclusion is always asked for: it is what says a run was skipped (decisions M205).
requested="$fields"
case ",$fields," in *,conclusion,*) ;; *) requested+=",conclusion" ;; esac
show="\"\\(.${fields//,/) \\(.})\""

# 20: a commit gets a run each time its pull request is opened, reopened or marked ready, never near that many.
gh run list --workflow ci.yml --commit "$commit" --limit 20 --json "$requested" \
  --jq "[.[] | select(.conclusion != \"skipped\")][0] // empty | $show"
