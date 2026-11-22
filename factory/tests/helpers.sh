#!/usr/bin/env bash
# Stand-ins for outside commands and checks on what a script then did, sourced by every test here (decisions H3).
# Usage: . "$(dirname "$0")/helpers.sh"
#        scenario "merges exactly the commit that was checked"   # a fresh, empty directory
#        stub gh 'case "$*" in "pr merge"*) exit 0 ;; *) exit 1 ;; esac'
#        run "$scripts/ship.sh" 7 abc123                         # sets $out and $status
#        expect_status 0
#        expect_call "gh pr merge 7 --squash --delete-branch --match-head-commit abc123"
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC2034
scripts="$root/factory/scripts"

# Its real path, which is what git prints for a repo inside it: a Mac's temporary folder is reached through a link.
_base=$(cd "$(mktemp -d)" && pwd -P)
_path="$PATH"
_count=0
_failed=0
_name=""
_problems=""
out=""
status=""
replaced=""

# What a workflow would set is taken away, so a test passes or fails the same in CI as on a laptop.
unset BOARD_TOKEN PRODUCTION_URL GITHUB_BASE_REF GH_TOKEN GITHUB_TOKEN GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA
# The tests that need a git repo make their own; it must not depend on who runs them.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

_close() {
  [ -n "$_name" ] || return 0
  if [ -z "$_problems" ]; then
    echo "ok - $_name"
  else
    _failed=1
    echo "not ok - $_name"
    printf '%s' "$_problems" | sed 's/^/    /'
    echo "    the script exited ${status:-without being run} and printed:"
    sed 's/^/      /' <<<"$out"
    echo "    the outside calls it made:"
    sed 's/^/      /' "$T/calls"
  fi
  _name=""
}

# A test file that broke half-way (an unset variable, a typo) keeps its exit code, so it does not read as passed.
trap '_code=$?; _close; cd /; rm -rf "$_base"; [ "$_code" -eq 0 ] || exit "$_code"; exit "$_failed"' EXIT

# The stand-ins refuse every call, so that no test reaches the network because it forgot one.
scenario() {
  _close
  _name="$1"; _problems=""; out=""; status=""
  _count=$((_count + 1))
  T="$_base/$_count"
  mkdir -p "$T/bin" "$T/work" "$T/tmp"
  : > "$T/calls"
  export T TMPDIR="$T/tmp" PATH="$T/bin:$_path"
  cd "$T/work" || exit 1
  local command
  for command in gh curl npx; do
    stub "$command" "echo \"no stand-in was given for: $command \$*\" >&2; exit 97"
  done
}

# stub <command> <bash>: records the call in $T/calls, then runs the bash; `json '<data>' "$@"` answers as gh does.
stub() {
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "%s $*" >> "$T/calls"\n' "$1"
    cat <<'EOF'
json() {
  local data="$1" filter=""
  shift
  while [ $# -gt 0 ]; do
    if [ "$1" = --jq ] || [ "$1" = -q ]; then filter="$2"; fi
    shift
  done
  if [ -n "$filter" ]; then jq -r "$filter" <<<"$data"; else printf '%s\n' "$data"; fi
}
EOF
    printf '%s\n' "$2"
  } > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# sessions_on_github "$@": answers a gh stand-in's git/trees and git/blobs calls from the folders of $T/sessions.
sessions_on_github() {
  local at="${2#*/git/}" entry entries=""
  case "$at" in
    blobs/*) at=${at#blobs/}; cat "$T/sessions/${at/@//}" ;;
    trees/*)
      at=${at#trees/}
      [ "$at" != sessions ] || at=""
      for entry in "$T/sessions/$at"/*; do
        [ -e "$entry" ] || continue
        entries+=$(jq -nc --arg in "$at" --arg path "${entry##*/}" --arg type "$([ -d "$entry" ] && echo tree || echo blob)" \
          '{path: $path, type: $type, sha: (if $in == "" then $path else $in + "@" + $path end)}')$'\n'
      done
      json "$(jq -sc --argjson cut "$([ -e "$T/truncated" ] && echo true || echo false)" '{tree: ., truncated: $cut}' <<<"$entries")" "$@" ;;
  esac
}
export -f sessions_on_github

# hold_on_github: answers a gh stand-in's read of the hold usage-limit.sh keeps: from the sessions branch of the repo
# sessions_remote made, which the script's own pushes reach, or else from $T/usage-limit. With no such file it
# answers as GitHub does for one the branch does not hold.
hold_on_github() {
  if [ -d "$T/remote.git" ]; then
    git --git-dir="$T/remote.git" show sessions:usage-limit 2>/dev/null && return 0
  elif [ -e "$T/usage-limit" ]; then
    cat "$T/usage-limit"
    return 0
  fi
  echo "gh: Not Found (HTTP 404)" >&2
  return 1
}
export -f hold_on_github

# waiting_on_github "$@": answers a gh stand-in's calls from start-waiting.sh, which a script that frees a place runs.
# $T/ready holds the open issues labelled ready, $T/issues and $T/pulls what in-flight.sh reads: each `[]` when absent.
# $T/usage-limit holds the hold of the Claude usage limit, and none holds when absent.
# $T/open holds every open issue and pull request. A ticket with a lower number has carried ready longer.
waiting_on_github() {
  local file n
  case "$*" in
    "api repos/{owner}/{repo}/contents/usage-limit?ref=sessions "*) hold_on_github; return ;;
    "api repos/{owner}/{repo}/issues?state=open&labels=ready&per_page=100 --paginate --jq "*) file=ready ;;
    "api repos/{owner}/{repo}/issues?state=open&per_page=100 --paginate --jq "*) file=open ;;
    "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*) json '[]' "$@"; return ;;
    "api repos/{owner}/{repo}/issues?state=open&labels=in-progress&per_page=100 --paginate --jq "*) file=issues ;;
    "pr list --state open --limit 100 --json number,headRefName,author,labels,isDraft") file=pulls ;;
    "api repos/{owner}/{repo}/issues/"*"/events?per_page=100 --paginate --jq "*)
      n=${2#*/issues/}; n=${n%/events*}
      json "[{\"id\":$n,\"event\":\"labeled\",\"label\":{\"name\":\"ready\"}}]" "$@"
      return ;;
    # A ticket the list of ready does not hold yet, whose body names no other.
    "api repos/{owner}/{repo}/issues/"*" --jq "*) json "{\"number\":${2##*/}}" "$@"; return ;;
    "workflow run implement.yml -f issue="*) return 0 ;;
    *) echo "unexpected call: gh $*" >&2; return 1 ;;
  esac
  [ -e "$T/$file" ] || echo '[]' > "$T/$file"
  json "$(cat "$T/$file")" "$@"
}
export -f waiting_on_github

run() {
  status=0
  out=$("$@" 2>&1) || status=$?
}

# in_terminal <command>...: runs the command with a terminal as its output, and passes on what it wrote and its exit code.
in_terminal() {
  python3 -c '
import os, pty, sys
sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@" </dev/null
}

fail() { _problems+="$1"$'\n'; }

# replace_first <text> <old> <new>: sets $replaced to the text with its first <old> replaced, as written (decisions H22).
replace_first() {
  local before after
  replaced="$1"
  case "$1" in
    *"$2"*) ;;
    *) fail "replace_first found nothing to replace: $2"; return 0 ;;
  esac
  before=${1%%"$2"*}
  after=${1#*"$2"}
  replaced="$before$3$after"
}

expect_status() {
  [ "$status" = "$1" ] || fail "expected exit $1, got $status"
}
expect_failure() {
  [ "$status" != 0 ] || fail "expected a failing exit, got 0"
}
expect_output() {
  [[ "$out" == *"$1"* ]] || fail "expected the output to hold: $1"
}
expect_no_output() {
  [[ "$out" != *"$1"* ]] || fail "expected the output not to hold: $1"
}
expect_call() {
  [[ "$(cat "$T/calls")" == *"$1"* ]] || fail "expected the call: $1"
}
# expect_first_line <call> <line>: the comment the call posts starts with the line, on a line of its own (decisions A371a).
expect_first_line() {
  [[ "$(cat "$T/calls")" == *"$1 $2"$'\n\n'* ]] || fail "expected the comment of \`$1\` to start with the line: $2"
}
expect_no_call() {
  [[ "$(cat "$T/calls")" != *"$1"* ]] || fail "expected no call like: $1"
}
calls() { grep -cF -- "$1" "$T/calls" || true; }
expect_calls() {
  [ "$(calls "$2")" = "$1" ] || fail "expected $1 of the call, got $(calls "$2"): $2"
}
