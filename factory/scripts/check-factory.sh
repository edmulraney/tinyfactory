#!/usr/bin/env bash
# Lints the factory's shell scripts and test files, their headers and each workflow's, and the reviewers' tools.
# Usage: check-factory.sh   (from the repo root)
set -euo pipefail

# A listing that failed is not a repo with no script in it (decisions H106).
if ! scripts=$(git ls-files 'factory/scripts/*.sh' 'factory/tests/*.sh' '.claude/skills/bootstrap/scripts/*.sh'); then
  echo "check-factory.sh must be run inside a git repository: it could not list the scripts with git ls-files, so nothing was checked."
  exit 1
fi
failed=0
for script in $scripts; do
  bash -n "$script" || failed=1
done
if command -v shellcheck >/dev/null; then
  # Errors only: style findings are not worth a red build (decisions H20).
  # shellcheck disable=SC2086
  shellcheck --severity=error $scripts || failed=1
else
  echo "shellcheck is not installed; only syntax was checked"
fi
# A Mac's bash 3.2 reads this ${name/old/new} differently (decisions H22).
for script in $scripts; do
  if found=$(grep -nE '\$\{[A-Za-z_0-9]+//?[^}]*(["'"'"']|$)' "$script"); then
    echo "$script: a \${name/old/new} substitution holds a quote or spans lines, which the bash 3.2 of a Mac reads differently from bash 5. Put the old and new text in variables, or use replace_first from factory/tests/helpers.sh:"
    sed 's/^/  /' <<<"$found"
    failed=1
  fi
done
# A Mac's bash 3.2 expands this brace list (decisions H121). D is an open double quote, P an open $( .
for script in $scripts; do
  found=$(awk '{
    line = $0
    gsub(/\\./, "", line)
    open = ""
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      next_c = substr(line, i + 1, 1)
      top = substr(open, length(open))
      if (c == "\"" && top == "D") open = substr(open, 1, length(open) - 1)
      else if (c == "\"") open = open "D"
      else if (c == "$" && next_c == "(") { open = open "P"; i++ }
      else if (c == "$" && next_c == "{") i++
      else if (c == ")" && top == "P") open = substr(open, 1, length(open) - 1)
      else if (c == "{" && open ~ /D.*D$/ && substr(line, i) ~ /^[{][^"]*(,|[.][.])[^"]*[}]/) {
        print FNR ":" $0
        break
      }
    }
  }' "$script")
  if [ -n "$found" ]; then
    echo "$script: a brace list in double quotes, inside a command substitution in double quotes, which the bash 3.2 of a Mac expands and bash 5 leaves alone. Write it with no brace and comma, or work the value out on a line of its own first:"
    sed 's/^/  /' <<<"$found"
    failed=1
  fi
done
# A header that grows is read on every run that opens the file (decisions H176a).
if ! workflows=$(git ls-files 'factory/workflows/*.yml'); then
  echo "check-factory.sh could not list the workflows with git ls-files, so no header was checked."
  exit 1
fi
for file in $scripts $workflows; do
  case "$file" in factory/*) ;; *) continue ;; esac
  # events.sh prints a workflow's first line as what it does (decisions H293a).
  needed=0
  case "$file" in factory/workflows/*) needed=1 ;; esac
  found=$(awk -v needed="$needed" '
    NR == 1 && /^#!/ { next }
    !/^#/ { exit }
    { n++ }
    n == 1 { if (length($0) > 120) print "its first line is " length($0) " characters"; next }
    n == 2 && /^# Usage:/ { usage = 1; next }
    usage && /^#   / { next }
    { print "line " NR " is neither: " $0; exit }
    END { if (needed && !n) print "it has no opening comment" }
  ' "$file")
  if [ -n "$found" ]; then
    echo "$file: its header is one line of 120 characters or fewer saying what the file does, then only \`# Usage:\` and lines indented under it by three spaces or more. A reason goes on the line it explains, in one line citing its decision (decisions H176a, H176b):"
    sed 's/^/  /' <<<"$found"
    failed=1
  fi
done
# A reviewer's tools run only gh and git (decisions H293d, H300).
for file in $workflows; do
  [ "$file" = factory/workflows/ci.yml ] || continue
  found=$(awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:.*/, "", job) }
    (job == "adam" || job == "ryan") && /--allowedTools/ {
      rest = $0
      while (match(rest, /Bash(\([^)]*\))?/)) {
        entry = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (entry !~ /^Bash\((gh|git) /) print "line " NR ", in the job " job ": " entry
      }
    }
  ' "$file")
  if [ -n "$found" ]; then
    echo "$file: a reviewer's job checks out the pull request with a token that writes, so it runs no script from the repo (H293d). Each Bash entry in its --allowedTools begins \`gh \` or \`git \`:"
    sed 's/^/  /' <<<"$found"
    failed=1
  fi
done
[ "$failed" -eq 0 ] && echo "factory scripts ok: $(wc -w <<<"$scripts" | tr -d ' ') checked"
exit "$failed"
