#!/usr/bin/env bash
# Starts the purpose interview: a Claude Code session that runs the `purpose` skill, which writes PURPOSE.md.
# Usage: purpose.sh [name]   (name defaults to the directory name)
#        Safe to re-run: skips when PURPOSE.md exists. With no terminal attached it starts nothing: the agent
#        that runs the bootstrap runs the skill in its own conversation.
set -euo pipefail

name="${1:-$(basename "$PWD")}"

if [ -f PURPOSE.md ]; then
  echo "purpose ok: PURPOSE.md already exists"
  exit 0
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "purpose skipped: no terminal to ask in. Run the purpose skill to interview the human."
  exit 0
fi

echo "Opening the purpose interview for $name. When PURPOSE.md is written, type /exit to carry on with setup."
claude "Run the purpose skill for the project '$name' in this directory. When PURPOSE.md is written, tell me to type /exit so setup can continue." || true

if [ -f PURPOSE.md ]; then
  echo "purpose ok: wrote PURPOSE.md"
else
  echo "purpose not written yet; setup continues. Run the purpose skill in a Claude Code session to add it."
fi
