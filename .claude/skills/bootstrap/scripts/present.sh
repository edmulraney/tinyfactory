#!/usr/bin/env bash
# Sourced by each setup script: prints a step's heading, a mark for how it ended and a block of what the owner must do.
# Usage: . "$(dirname "$0")/present.sh"
#        heading "[9/13] board"
#        mark done|needs-owner|failed "<what happened>"
#        owner_block   (stdin: the action on the first line, then the link and any one-time code on lines of their own)

# No setup step's gh opens a pager, run by bootstrap.sh or by itself (decisions S697).
export GH_PAGER=cat

# Decided once, where the script's output is still the terminal: a block made inside $( ) is styled the same (decisions S421b).
present_styled=""
[ ! -t 1 ] || [ -n "${NO_COLOR:-}" ] || present_styled=1

heading() {
  if [ -n "$present_styled" ]; then printf '\n\033[1m%s\033[0m\n' "$1"; else printf '\n%s\n' "$1"; fi
}

mark() {
  local sign colour
  case "$1" in
    done) sign='✓' colour=32 ;;
    needs-owner) sign='!' colour=33 ;;
    failed) sign='✗' colour=31 ;;
  esac
  if [ -n "$present_styled" ]; then printf '\033[%sm%s\033[0m %s\n' "$colour" "$sign" "$2"; else printf '%s %s\n' "$sign" "$2"; fi
  # bootstrap.sh lists at the end of a run what was left for the owner (decisions S421c).
  [ "$1" != needs-owner ] || [ -z "${SETUP_NEEDS_OWNER:-}" ] || printf '%s\n' "$2" >> "$SETUP_NEEDS_OWNER"
}

# The box has no right side: a line's width on screen is not its length in characters (decisions S421d).
owner_block() {
  local line first=1
  if [ -z "$present_styled" ]; then
    printf '\n'
    while IFS= read -r line; do printf '  %s\n' "$line"; done
    printf '\n'
    return
  fi
  printf '\n\033[33m┌──────────────────────────────────────────────────────────\033[0m\n'
  while IFS= read -r line; do
    if [ -n "$first" ]; then printf '\033[33m│\033[0m \033[1m%s\033[0m\n' "$line"; else printf '\033[33m│\033[0m %s\n' "$line"; fi
    first=""
  done
  printf '\033[33m└──────────────────────────────────────────────────────────\033[0m\n\n'
}
