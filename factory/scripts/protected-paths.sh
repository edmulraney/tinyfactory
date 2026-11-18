#!/usr/bin/env bash
# Prints the factory's files among the paths on stdin, which only a `factory` ticket may change; exits 1 if any.
# Usage: protected-paths.sh   (changed file paths on stdin)
set -euo pipefail

# The merge gate runs main's copy of this list (decisions M2); owner-decides.sh holds the product's bar (M272f).
protected='^(\.claude|\.github|factory)/'
hits=$(grep -E "$protected" || true)
[ -z "$hits" ] && exit 0
echo "$hits"
exit 1
