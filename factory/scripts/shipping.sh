#!/usr/bin/env bash
# Shared by the scripts that ship a pull request: asks GitHub again, and says when one was not merged.
# Usage: . shipping.sh   (sourced by merge-gate.sh, approve-merge.sh and merge-queue.sh, which set $pr first; revert.sh, first-runs.sh and minutes.sh take only retry; begin-fix-round.sh takes retry and run_log, and ship.sh start_merge_group too)

# retry <command> [args]: for a call safe to make twice, never the merge, nor a workflow start that a second would repeat (decisions M26).
retry() {
  local out try
  for try in 1 2 3 4 5 6; do
    if out=$("$@"); then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$try" -eq 6 ] || sleep 10
  done
  return 1
}

# start_merge_group [try]: starts merge-group.yml, asked again when the start fails: a second run only waits behind
# the first and finds what is left (decisions M455j).
start_merge_group() { retry gh workflow run merge-group.yml ${1:+-f try="$1"} >/dev/null; }

# Where the log of this run is, for a comment: GitHub's own error is there.
run_log() {
  [ -z "${GITHUB_RUN_ID:-}" ] || printf ' The log has what GitHub answered: %s/%s/actions/runs/%s' \
    "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-}" "$GITHUB_RUN_ID"
}

# notify_not_merged <why>: tells the pull request and flags it for the owner; fails when either could not be done.
notify_not_merged() {
  local body failed=0
  # The first line says what a person must do (decisions A371a).
  body="Approve this pull request again: the merge is tried again then.

Not merged: $1.$(run_log)"
  echo "$body" >&2
  retry gh pr comment "$pr" --body "$body" >/dev/null || { echo "and the pull request could not be told so" >&2; failed=1; }
  retry gh pr edit "$pr" --add-label needs-human >/dev/null || { echo "and needs-human could not be added to it" >&2; failed=1; }
  return "$failed"
}

# not_merged <why>: stops the script as failed, having said why (decisions M30).
not_merged() {
  notify_not_merged "$1" || true
  exit 1
}
