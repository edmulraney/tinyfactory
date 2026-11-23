#!/usr/bin/env bash
# Replaces a secret with [redacted] in every file under a folder, and fails if any file still holds it.
# Usage: SECRET=<value> redact-secret.sh <folder>
#        Does nothing when SECRET is empty or the folder is missing. A file it cannot change fails it.
set -euo pipefail

folder="${1:?Usage: SECRET=<value> redact-secret.sh <folder>}"
[ -n "${SECRET:-}" ] && [ -d "$folder" ] || exit 0

# grep exits 1 when no file holds the secret, which is not a failure.
{ grep -rlZF -- "$SECRET" "$folder" || [ $? -eq 1 ]; } | xargs -0r perl -pi -e 's/\Q$ENV{SECRET}\E/[redacted]/g'
if left=$(grep -rlF -- "$SECRET" "$folder"); then
  echo "redact-secret.sh: these files still hold the secret: $left" >&2
  exit 1
fi
