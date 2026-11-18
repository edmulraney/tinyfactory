#!/usr/bin/env bash
# Creates a Claude subscription token and stores it as the repo secret CLAUDE_CODE_OAUTH_TOKEN.
# The token is never printed or written to disk. The human only approves in the browser.
# Then runs the agent-check workflow to prove the token and model work in Actions.
# Usage: agent-token.sh [name]   (name defaults to the directory name)
set -uo pipefail

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
repo="$owner/$name"

# `claude setup-token` draws a terminal UI and hard-wraps the token at the terminal width;
# copying it by hand loses everything after the first line. Run it in a very wide pseudo-terminal
# and pull the token straight out of the output stream.
script -q /dev/null sh -c 'stty cols 1000 rows 50; claude setup-token' </dev/null 2>&1 \
  | REPO="$repo" python3 -u -c '
import os, re, select, subprocess, sys
ansi = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[=>]")
token_re = re.compile(rb"sk-ant-oat\d\d-[A-Za-z0-9_\-]{60,}")
url_re = re.compile(rb"https://[^\s\x1b]+")
buf, shown, fd = b"", set(), sys.stdin.fileno()
token = None
while True:
    ready, _, _ = select.select([fd], [], [], 1.0 if token else 600)
    if not ready:
        break                      # token seen and output went quiet, or nobody approved in 10 minutes
    chunk = os.read(fd, 65536)
    if not chunk:
        break
    buf += ansi.sub(b"", chunk)
    for url in url_re.findall(buf):
        if url not in shown and b"sk-ant" not in url:
            shown.add(url); print("approve in the browser:", url.decode(errors="replace"), flush=True)
    found = token_re.findall(buf)
    if found:
        token = max(found, key=len)
if not token:
    print("no token appeared; the login was not approved or the output format changed"); sys.exit(1)
subprocess.run(["gh", "secret", "set", "CLAUDE_CODE_OAUTH_TOKEN", "-R", os.environ["REPO"]],
               input=token, check=True, stdout=subprocess.DEVNULL)
print("secret CLAUDE_CODE_OAUTH_TOKEN stored (%d characters)" % len(token))
' || exit 1

gh workflow run agent-check -R "$repo" >/dev/null
echo "started agent-check; waiting for the result"
for _ in $(seq 1 12); do
  id=$(gh run list -R "$repo" --workflow agent-check --limit 1 --json databaseId,status --jq '.[0] | select(.status != "completed") | .databaseId')
  [ -n "$id" ] && break
  perl -e 'select(undef, undef, undef, 5)'
done
if [ -z "${id:-}" ]; then echo "agent-check run did not start"; exit 1; fi
if gh run watch "$id" -R "$repo" --interval 5 --exit-status >/dev/null 2>&1; then
  echo "agent ok: token and model work in Actions"
else
  echo "agent-check failed: gh run view $id -R $repo --log"
  exit 1
fi
