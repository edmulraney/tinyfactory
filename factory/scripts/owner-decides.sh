#!/usr/bin/env bash
# Prints what a diff changes that only the repo's owner may decide, and exits 1 if there is any (decisions M272a).
# Usage: owner-decides.sh   (a unified diff on stdin, as `gh pr diff` or `git diff` prints it)
#        Prints "<kind>: <path>" or "<kind>: <path>: <changed line>", once each. The kinds are "spend or limits",
#        "secrets or permissions", "this rule", "the product's bar" and "the agents' instructions" (CLAUDE.md).
#        A diff it cannot read ends in exit 2.
#        It calls nothing but awk and reads no other file: the installer runs it by its git id (decisions W272b).
set -euo pipefail

# shellcheck disable=SC2016
exec awk '
  function hold(kind, what,    key) {
    key = kind ": " what
    if (!(key in seen)) { seen[key] = 1; print key }
    held = 1
  }
  function unread(why) { print "owner-decides.sh: line " NR " of the diff " why > "/dev/stderr"; bad = 1; exit }
  function workflow(path) { return path ~ "^(factory|\\.github)/workflows/" }
  function whole(path) {
    # Git quotes a path it had to escape, and no rule below would know it.
    if (path ~ /^"/) unread("names a path git had to quote")
    # The gate, the approval and the installer; only the installer writes an installed copy (decisions W1).
    if (path ~ "^factory/scripts/(owner-decides|protected-paths|merge-gate|approve-merge)\\.sh$" ||
        path ~ "^factory/workflows/(install-workflows|approve-merge)\\.yml$" || path ~ "^\\.github/workflows/")
      hold("this rule", path)
    if (path ~ "^factory/free-tier(\\.md$|/)")
      hold("spend or limits", path)
    # The scripts that make or store a credential, or that a merge runs with one (apply-setup.sh).
    if (path ~ "^\\.claude/skills/bootstrap/scripts/([a-z-]+-(token|key)|workflow-app|preview-access|vercel|board)\\.sh$" ||
        path == "factory/scripts/apply-setup.sh" || path ~ "^\\.claude/settings[^/]*\\.json$")
      hold("secrets or permissions", path)
    # These wait for the owner whoever changes them, on any type of ticket (decisions M272e).
    if (path ~ "^(TASTE|DESIGN)\\.md$" ||
        path ~ "(^|/)(eslint\\.config\\.[a-z]+|tsconfig[^/]*\\.json|vitest\\.config\\.[a-z]+|playwright\\.config\\.[a-z]+|globals\\.css|components\\.json|e2e/test\\.ts)$")
      hold("the product\047s bar", path)
    if (path == "CLAUDE.md") hold("the agents\047 instructions", path)
  }
  function changed(text,    low, said) {
    low = tolower(text)
    gsub(/^[ \t]+|[ \t]+$/, "", text)
    said = file ": " text
    if (workflow(file)) {
      if (low ~ /model|effort|max-turns|timeout/) hold("spend or limits", said)
      # A permission is also a line of its own under `permissions:`, which a hunk may not show.
      if (low ~ /permission|secrets|private-key|client-id|allowed|tools|bots|mcp|settings/ ||
          low ~ /^[ \t]*[a-z-]+:[ \t]*(read|write|none)[ \t]*(#.*)?$/)
        hold("secrets or permissions", said)
      # Whose rules a job runs (`ref:`), who the owner is, the scripts that decide, and the jobs and the author
      # a job waits for: the `merge` job asks for both reviews there.
      if (low ~ /(^|[^a-z_])ref:|owner|merge-gate|approve-merge|install-workflows/ ||
          low ~ /^[ \t]*needs:|needs\.[a-z0-9_-]+\.result|user\.login/)
        hold("this rule", said)
    }
    if (file == "factory/scripts/in-flight.sh" && low ~ /limit/) hold("spend or limits", said)
    # fix.yml hands its agent the tools this script prints.
    if (file == "factory/scripts/begin-fix-round.sh" && low ~ /tools/) hold("secrets or permissions", said)
  }

  # Lines are counted through each hunk, so a changed line that looks like a header is never read as one.
  old > 0 || new > 0 {
    mark = substr($0, 1, 1)
    if (mark == "\\") next
    if (mark == "-") { old--; changed(substr($0, 2)) }
    else if (mark == "+") { new--; changed(substr($0, 2)) }
    else if (mark == " " || $0 == "") { old--; new-- }
    else unread("is no line of its hunk")
    next
  }
  /^diff --git / {
    file = ""
    # "a/<path> b/<path>": the two halves are one path unless it was renamed, and then the lines below name both.
    rest = substr($0, 12); half = (length(rest) - 5) / 2
    if (rest ~ /^"/) unread("names a path git had to quote")
    if (half == int(half) && substr(rest, 3, half) == substr(rest, half + 6)) { file = substr(rest, 3, half); whole(file) }
    next
  }
  /^(rename|copy) (from|to) / {
    path = $0; sub(/^(rename|copy) (from|to) /, "", path)
    whole(path)
    # A workflow under a new name runs with every permission and secret of the old one.
    if (workflow(path)) hold("secrets or permissions", path)
    next
  }
  /^(---|\+\+\+) / {
    path = substr($0, 5); sub(/\t.*$/, "", path)
    if (path != "/dev/null") { sub(/^[ab]\//, "", path); file = path; whole(file) }
    next
  }
  /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
    if (file == "") unread("opens a hunk of no file")
    split($2, was, ","); split($3, now, ",")
    old = (2 in was) ? was[2] + 0 : 1
    new = (2 in now) ? now[2] + 0 : 1
    next
  }
  END {
    if (bad) exit 2
    if (old > 0 || new > 0) { print "owner-decides.sh: the diff ends inside a hunk" > "/dev/stderr"; exit 2 }
    exit held ? 1 : 0
  }
'
