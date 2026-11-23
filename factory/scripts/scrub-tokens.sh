#!/usr/bin/env bash
# Replaces each token in a transcript with a placeholder before it is published (decisions A667a).
# Usage: scrub-tokens.sh <file-or-folder>...   rewrites each file in place; a path that is not there is skipped.
set -euo pipefail

# A prefix alone stays readable (decisions A667b).
script='
  s/sk-ant-[A-Za-z0-9_-]{20,}/sk-ant-[REDACTED]/g;
  s/github_pat_[A-Za-z0-9_]{20,}/github_pat_[REDACTED]/g;
  s/gh([pousr])_[A-Za-z0-9._-]{20,}/gh$1_[REDACTED]/g;
  s/x-access-token:[^\s"\x27\@\\]+/x-access-token:[REDACTED]/g;
  s/-----BEGIN ([A-Z ]*)PRIVATE KEY-----.*?-----END \1PRIVATE KEY-----/[REDACTED $1PRIVATE KEY]/gs;
'
for path in "$@"; do
  [ -e "$path" ] || continue
  find "$path" -type f -exec perl -0777 -pi -e "$script" {} + \
    || { echo "could not scrub the tokens from $path" >&2; exit 1; }
done
