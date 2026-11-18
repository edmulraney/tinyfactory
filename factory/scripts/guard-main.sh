#!/usr/bin/env bash
# Installs a git hook in this checkout that refuses any push to the default branch.
# Usage: guard-main.sh [branch]   (default: main)
set -euo pipefail

branch="${1:-main}"
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
# GitHub offers no branch protection on a private repo on the free plan, so the lock lives here.
cat > "$hooks/pre-push" <<HOOK
#!/bin/sh
# Installed by factory/scripts/guard-main.sh.
while read -r _local_ref _local_sha remote_ref _remote_sha; do
  if [ "\$remote_ref" = "refs/heads/$branch" ]; then
    echo "refused: pushing to $branch is not allowed from this checkout. Push a branch and open a pull request." >&2
    exit 1
  fi
done
exit 0
HOOK
chmod +x "$hooks/pre-push"
echo "pushes to $branch are refused in this checkout"
