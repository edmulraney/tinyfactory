#!/usr/bin/env bash
# Starts the purpose interview: a Claude Code session that runs the `purpose` skill, which writes PURPOSE.md.
# Usage: purpose.sh [name]   (name defaults to the directory name)
#        Safe to re-run: skips when PURPOSE.md exists. With no terminal attached it starts nothing: the agent
#        that runs the bootstrap runs the skill in its own conversation.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"

if [ -f PURPOSE.md ]; then
  mark done "purpose ok: PURPOSE.md already exists"
  exit 0
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  mark needs-owner "purpose skipped: no terminal to ask in. Run the purpose skill to interview the human."
  exit 0
fi

echo "Opening the purpose interview for $name. Setup carries on by itself once PURPOSE.md is written."
# `exec` turns the shell whose PID is $$ into Claude Code, the process the Stop hook stops to end the session (decisions S671).
settings='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"[ ! -f \"$CLAUDE_PROJECT_DIR/PURPOSE.md\" ] || kill \"$PURPOSE_SESSION\""}]}]}}'
sh -c 'export PURPOSE_SESSION=$$; exec claude "$@"' purpose --settings "$settings" \
  "Run the purpose skill for the project '$name' in this directory." || true

if [ -f PURPOSE.md ]; then
  mark done "purpose ok: wrote PURPOSE.md"
else
  mark needs-owner "purpose not written yet; setup continues. Run the purpose skill in a Claude Code session to add it."
fi
