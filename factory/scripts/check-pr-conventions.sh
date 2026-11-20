#!/usr/bin/env bash
# Checks a pull request's title, branch name and description against the conventions in CLAUDE.md (decisions P1, P3).
# Usage: check-pr-conventions.sh "<pr title>" "<branch name>" [<pr-number> | <description-file>]
#        <pr-number>         an open pull request: its description and changed files are read from GitHub.
#        <description-file>  before the pull request exists: the changed files are what this branch holds on top of
#                            main, committed or not. Fails once when the branch's ticket was edited after its
#                            first commit.
#        With neither, only the title and the branch are checked. A pull request number needs `gh` and a login that
#        can read this repo's pull requests and issues (GH_TOKEN in a workflow).
set -euo pipefail

title="$1"; branch="$2"; what="${3:-}"
types='feat|fix|chore|docs|refactor|test|ci'
template=".github/PULL_REQUEST_TEMPLATE.md"
shape='"Closes #<n>", a blank line, one paragraph of 50 words at most on what changed, then "Differs from the ticket: <how>" and "Needs from the owner after merging: <what>", each on one line and left out when it has nothing to say'
differs="Differs from the ticket:"
needs="Needs from the owner after merging:"
# The shape that came before, which is still checked (decisions P170a).
sections=("## What changed" "## Why" "## Docs updated" "## How it was verified" "## Not proven" "## After merging" "## Notes for the reviewer")
factory_docs=("factory/README.md" "factory/owner-guide.md" "factory/decisions.md" "factory/free-tier.md" "factory/manual-steps.md" "CLAUDE.md")

ok=0
problem() { echo "$1"; ok=1; }
# For a lookup that failed: an answer that never came must not be read as "nothing changed" or "no such ticket".
die() { echo "$1" >&2; exit 1; }

if ! grep -qE "^($types): .+" <<<"$title"; then
  problem "PR title \"$title\" must look like \"<type>: <summary>\" with type one of: ${types//|/, }."
else
  # The summary follows the format of a ticket title (decisions T14).
  summary="${title#*: }"
  case "$summary" in *:*) problem "PR title \"$title\" has a second colon. The summary is one clause: an imperative verb, then what changes." ;; esac
  case "$summary" in *,*) problem "PR title \"$title\" has a comma. The summary is one clause: an imperative verb, then what changes." ;; esac
  case "$summary" in *.) problem "PR title \"$title\" ends in a full stop. Take it off." ;; esac
fi
# It becomes the commit on main, and 72 is where git's summary line ends.
if [ "${#title}" -gt 72 ]; then
  problem "PR title \"$title\" is ${#title} characters long, and the limit is 72. Name the change in one clause; the reason belongs in the description."
fi
if ! grep -qE "^($types)/([0-9]+-)?[a-z0-9]+(-[a-z0-9]+)*$" <<<"$branch"; then
  problem "Branch \"$branch\" must look like \"<type>/<issue-number>-<short-slug>\", e.g. feat/12-export-csv."
fi

if [ -z "$what" ]; then
  echo "The description was not checked: no pull request number or description file was given."
  exit "$ok"
fi

closes=""
if [[ "$what" =~ ^[0-9]+$ ]]; then
  # GitHub knows the links made in the sidebar or written as a URL. Its tickets are the first line, the rest the body.
  response=$(gh pr view "$what" --json body,closingIssuesReferences \
    --jq '([.closingIssuesReferences[].number | tostring] | join(" ")), (.body // "")') \
    || die "Could not read the description of pull request #$what from GitHub, so it was not checked. Run this check again."
  closes=$(head -1 <<<"$response" | tr ' ' '\n')
  body=$(tail -n +2 <<<"$response")
elif [ -f "$what" ]; then
  body=$(cat "$what")
else
  die "\"$what\" is neither a pull request number nor a description file."
fi
# Only at hand-over, and once for each edit: the engineer can still read the ticket again (decisions T325a, T325b).
if [ -f "$what" ] && [[ "$branch" =~ ^[a-z]+/([0-9]+)- ]]; then
  ticket="${BASH_REMATCH[1]}"
  reported="${TMPDIR:-/tmp}/check-pr-conventions-reported"
  if ! edited=$(gh api graphql -f query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { issue(number: $number) { lastEditedAt } } }' \
    -F owner='{owner}' -F repo='{repo}' -F number="$ticket" --jq '.data.repository.issue.lastEditedAt // empty'); then
    echo "Could not read from GitHub when ticket #$ticket was last edited, so that was not checked."
  elif [ -z "$edited" ] || grep -qxF "$ticket $edited" "$reported" 2>/dev/null; then
    :
  # GitHub gives the time in UTC, so a commit's time in UTC sorts against it as text.
  elif ! began=$(TZ=UTC0 git log --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd "origin/${GITHUB_BASE_REF:-main}..HEAD" 2>/dev/null | sort | head -1) \
    || [ -z "$began" ]; then
    echo "Ticket #$ticket was edited at $edited, and the first commit of this branch could not be found, so whether that was after this build began was not checked."
  elif [[ "$edited" > "$began" ]]; then
    echo "Ticket #$ticket was edited at $edited, after this build began: read it again (gh issue view $ticket) and make what it now asks. This check fails for an edit once."
    ! echo "$ticket $edited" 2>/dev/null >> "$reported" || ok=1
  fi
fi
# Sets $changed. Only the seven sections name documents, so only they ask.
changed_files() {
  if [[ "$what" =~ ^[0-9]+$ ]]; then
    changed=$(gh api "repos/{owner}/{repo}/pulls/$what/files" --paginate --jq '.[].filename') \
      || die "Could not read the files pull request #$what changes from GitHub, so its description was not checked. Run this check again."
    return
  fi
  local base="origin/${GITHUB_BASE_REF:-main}"
  # Committed or not: the engineers run this before they push, and uncommitted work is part of what the branch changes.
  changed=$(fork=$(git merge-base "$base" HEAD) && git diff --name-only "$fork" && git ls-files --others --exclude-standard) \
    || die "Could not list what this branch changes since $base, so the description was not checked. Fetch it (git fetch origin ${base#origin/}) and run this check again."
  [ -n "$changed" ] \
    || die "This branch changes nothing since $base, committed or not, so there is nothing to describe. Run this check from the branch that holds the work."
}
# Every closing word GitHub honours, not only the first: a "fixes #53" further down closes that ticket as well.
closes=$(printf '%s\n' "$closes"; grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+' <<<"$body" | grep -oE '[0-9]+$' || true)

# Tags each line H, for what GitHub shows as a heading, or T, with <!-- comments --> removed. U: one was never closed.
tagged=$(tr -d '\r' <<<"$body" | awk '
  # The line with its inline code spans blanked out, the same length, so that what is quoted
  # in backticks (a "<!--", an "<h2>") is not read as the thing itself.
  function mask(s,   out, i, n, j, k, m, run, found) {
    out = ""; i = 1; n = length(s)
    while (i <= n) {
      if (substr(s, i, 1) != "`") { out = out substr(s, i, 1); i++; continue }
      j = i; while (j <= n && substr(s, j, 1) == "`") j++
      run = j - i; k = j; found = 0
      while (k <= n) {
        if (substr(s, k, 1) != "`") { k++; continue }
        m = k; while (m <= n && substr(s, m, 1) == "`") m++
        if (m - k == run) { found = 1; break }
        k = m
      }
      if (!found) { out = out substr(s, i, run); i = j; continue }
      while (i < m) { out = out "x"; i++ }
    }
    return out
  }
  # One line is held back, because only the next line says whether it was underlined.
  function flush() { if (have) print held_tag "\t" held; have = 0 }
  function hold(tag, text) { flush(); held_tag = tag; held = text; have = 1 }
  {
    quoted = $0
    while (sub(/^ ? ? ?> ?/, "", quoted)) ;
    if (fence) {
      # Only a fence of the same character, at least as long, closes it: a ```` block may
      # quote a ``` one, and pasted output may hold a line of ~~~.
      probe = quoted; sub(/^[ \t]+/, "", probe); sub(/[ \t]+$/, "", probe)
      if (probe ~ ("^[" fence_char "]+$") && length(probe) >= fence_length) fence = 0
      hold("T", $0); plain = ""; next
    }
    line = $0; out = ""
    while (line != "") {
      if (comment) {
        i = index(line, "-->")
        if (!i) break
        line = substr(line, i + 3); comment = 0
      } else {
        i = index(mask(line), "<!--")
        if (!i) { out = out line; break }
        out = out substr(line, 1, i - 1); line = substr(line, i + 4); comment = 1
      }
    }
    # What the line says once the marks of a quote or a list item are taken off the front.
    bare = out
    while (sub(/^ ? ? ?>/, "", bare) || sub(/^ ? ? ?([-*+]|[0-9]+[.)])[ \t]+/, "", bare)) ;
    if (match(bare, /^ ? ? ?(```+|~~~+)/)) {
      probe = substr(bare, RSTART, RLENGTH); sub(/^ +/, "", probe)
      # A ``` line with another backtick after it is inline code, not a fence.
      if (substr(probe, 1, 1) == "~" || index(substr(bare, RSTART + RLENGTH), "`") == 0) {
        fence = 1; fence_char = substr(probe, 1, 1); fence_length = length(probe)
        hold("T", out); plain = ""; next
      }
    }
    under = out
    while (sub(/^[ \t]*>/, "", under)) ;
    gsub(/^[ \t]+|[ \t]+$/, "", under)
    if (under ~ /^(=+|-+)$/) {
      if (plain == "") hold("T", out)
      else { held_tag = "H"; held = plain " (underlined with " under ", which makes it a heading; leave a blank line above a rule)" }
      plain = ""; next
    }
    if (bare ~ /^ ? ? ?#+([ \t]|$)/) {
      sub(/^ */, "", bare); sub(/[ \t]+#*[ \t]*$/, "", bare); sub(/[ \t]+/, " ", bare)
      hold("H", bare); plain = ""
    } else if (match(tolower(mask(out)), /<h[1-6][ \t>]/)) {
      hold("H", substr(out, RSTART)); plain = ""
    } else {
      hold("T", out); plain = bare; gsub(/^[ \t]+|[ \t]+$/, "", plain)
    }
  }
  END { flush(); if (comment) print "U\t" }')

if grep -q '^U' <<<"$tagged"; then
  problem "A \"<!--\" in the description is never closed with \"-->\", so GitHub hides everything after it and none of it was read. Close the comment, or put the \"<!--\" in backticks if it is meant to be seen."
fi

headings=$(awk -F'\t' '$1 == "H" { print $2 }' <<<"$tagged")
finish() {
  [ "$ok" -ne 0 ] || echo "pull request conventions ok: the title, the branch and the description follow them"
  exit "$ok"
}

if [ "$headings" != "$(printf '%s\n' "${sections[@]}")" ]; then
  if [ -n "$headings" ]; then
    # Under headings there is no telling which line is which, so nothing more is read.
    problem "The description has headings, and its shape has none: $(sed 's/.*/"&"/' <<<"$headings" | paste -sd' ' -). The whole of it is $shape ($template)."
    exit "$ok"
  fi

  stage=closing   # then: before (the paragraph), paragraph, lines
  paragraph=0; listed=no; outside=no; seen_differs=no; seen_needs=no
  only_tickets='^([-*+][[:space:]]+)?#[0-9]+([,[:space:]]+(and[[:space:]]+)?#[0-9]+)*\.?$'
  # A closing word and one ticket reference, however written. Alone it is not the paragraph (decisions P170d).
  closing='^([Cc]lose[sd]?|[Ff]ix(e[sd])?|[Rr]esolve[sd]?):?[[:space:]]+(([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+|<[^>[:space:]]*>)|https?://[^[:space:]]+)\.?$'
  nothing='^([Nn]othing|[Nn]one|[Nn]o|N/A|n/a|-)?\.?$'
  no_tickets="A pull request finishes its ticket or is not ready (decisions P4): do what is left in this pull request, and say what only the owner can do in a sentence on the \"$needs\" line."
  # labelled <label> <line>: one of the two lines that follow the paragraph.
  labelled() {
    local value="${2#"$1"}"
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ "$value" =~ $nothing ]]; then
      problem "\"$1\" has nothing to say (\"$2\"). Leave the line out."
    elif [[ "$value" =~ $only_tickets ]]; then
      problem "\"$2\" lists tickets. $no_tickets"
    fi
  }
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    if [ -z "$line" ]; then
      [ "$stage" != paragraph ] || stage=lines
      continue
    fi
    if [ "$stage" = closing ]; then
      stage=before
      [[ "$line" =~ $closing ]] && continue
    fi
    if [[ "$line" == "$differs"* ]]; then
      [ "$seen_differs" = no ] || problem "\"$differs\" appears twice. Say it once, on one line."
      [ "$seen_needs" = no ] || problem "\"$differs\" comes before \"$needs\"."
      seen_differs=yes; stage=lines
      labelled "$differs" "$line"
    elif [[ "$line" == "$needs"* ]]; then
      [ "$seen_needs" = no ] || problem "\"$needs\" appears twice. Say it once, on one line."
      seen_needs=yes; stage=lines
      labelled "$needs" "$line"
    elif [[ "$line" =~ $only_tickets ]]; then
      problem "The description lists tickets (\"$line\"). $no_tickets"
    elif [ "$stage" != lines ]; then
      stage=paragraph
      paragraph=$((paragraph + $(wc -w <<<"$line")))
      [[ "$line" =~ ^([-*+]|[0-9]+[.\)])[[:space:]] ]] && listed=yes
    elif [ "$outside" = no ]; then
      # Said once, for the first such line: the rest of a second paragraph would repeat it.
      outside=yes
      problem "This line is outside the description's shape: \"$line\". One paragraph says what changed, and after it come only the two labelled lines, each on one line. The whole of it is $shape."
    fi
  done < <(awk -F'\t' '$1 == "T" { print substr($0, 3) }' <<<"$tagged")

  if [ "$paragraph" -eq 0 ]; then
    problem "The description does not say what changed. Say it in one paragraph of 50 words at most, after the closing line. Its first sentence says what changed and stands alone."
  elif [ "$paragraph" -gt 50 ]; then
    problem "The paragraph on what changed is $paragraph words long, and the limit is 50. Keep a first sentence that says what changed and stands alone, and cut until it fits."
  fi
  if [ "$listed" = yes ]; then
    problem "The paragraph on what changed holds a list. Write it as sentences: the diff lists the files, and the checks list the tests."
  fi
  # Why a limit on the whole as well: decisions P170b.
  total=$(awk -F'\t' '$1 == "T" { print substr($0, 3) }' <<<"$tagged" | wc -w)
  if [ "$total" -ge 100 ]; then
    problem "The description is $total words long, and the whole of it must be under 100."
  fi
  finish
fi

# From here on, a description in the seven sections that came before is checked as it was (decisions P170a).
section() {
  awk -F'\t' -v expected="$1" '
    $1 == "H" { inside = ($2 == expected); next }
    inside { text = substr($0, 3); gsub(/^[ \t]+|[ \t]+$/, "", text); if (text != "") print text }' <<<"$tagged"
}
changed_files

after=$(section "## After merging")
if [ -z "$after" ]; then
  problem "\"## After merging\" is empty. Write \"Nothing\", or list the tickets that hold what is left, one per line (\"- #12\")."
elif ! [[ "$after" =~ ^Nothing\.?$ ]]; then
  while IFS= read -r line; do
    if ! [[ "$line" =~ ^([-*][[:space:]]+)?#([0-9]+)$ ]]; then
      problem "\"## After merging\" may hold only \"Nothing\" or ticket references, one per line (\"- #12\"). This line is neither: \"$line\". File a ticket for what it describes (label it needs-human if a person must do it) and list the ticket's number instead."
      continue
    fi
    ticket="${BASH_REMATCH[2]}"
    if grep -qxF -- "$ticket" <<<"$closes"; then
      problem "\"## After merging\" lists #$ticket, a ticket this pull request closes when it merges, so nothing would track what is left. File a new ticket for it and list that one, or take the closing word (closes, fixes, resolves) away from #$ticket if the merge should leave it open."
      continue
    fi
    if found=$(gh api "repos/{owner}/{repo}/issues/$ticket" --jq 'if .pull_request then "pull request" else .state end' 2>&1); then
      case "$found" in
        open) ;;
        "pull request") problem "\"## After merging\" lists #$ticket, which is a pull request. File a ticket for what is left and list that." ;;
        *) problem "\"## After merging\" lists #$ticket, which is closed, so nothing tracks what is left. Reopen it, or file a new ticket and list that." ;;
      esac
    elif grep -qE 'HTTP (404|410)' <<<"$found"; then
      problem "\"## After merging\" lists #$ticket, which does not exist. File the ticket first (gh issue create), then list its number."
    else
      die "Could not look up ticket #$ticket, so \"## After merging\" was not checked: $found"
    fi
  done <<<"$after"
fi

docs=$(section "## Docs updated")
reason=no
# "- path: what differs", the path in backticks or bare.
listed='^[-*][[:space:]]+`?([^`:[:space:]]+)`?:?[[:space:]]+[^[:space:]]'
if [ -z "$docs" ]; then
  problem "\"## Docs updated\" is empty. List each document this pull request changed and what now differs in it (\"- path/from/the/repo/root.md: what differs\"), or write \"None needed:\" followed by the reason."
else
  while IFS= read -r line; do
    if [[ "$line" =~ ^[Nn]one\ needed ]]; then
      if [[ "$line" =~ ^[Nn]one\ needed:[[:space:]]*[^[:space:]] ]]; then
        reason=yes
      else
        problem "\"## Docs updated\" says \"None needed\" without a reason. Write \"None needed: <why no document describes what this changes>\"."
      fi
    elif [[ "$line" =~ $listed ]]; then
      doc="${BASH_REMATCH[1]}"
      if ! grep -qxF -- "$doc" <<<"$changed"; then
        problem "\"## Docs updated\" names $doc, which this pull request does not change. Name each document by its path from the repo root, and list only the ones this pull request changes."
      fi
    else
      problem "\"## Docs updated\" holds a line that is neither a document nor a reason: \"$line\". Write one line per document (\"- path/from/the/repo/root.md: what differs\"), or \"None needed:\" followed by the reason."
    fi
  done <<<"$docs"
fi

# A ticket's own file of rows or entries is one of the documents (decisions H130a, H130e).
if grep -qE '^(factory/|\.claude/skills/)' <<<"$changed" && [ "$reason" = no ] \
  && ! grep -qxFf <(printf '%s\n' "${factory_docs[@]}") <<<"$changed" \
  && ! grep -qE '^factory/(README|decisions|free-tier)/' <<<"$changed"; then
  problem "This pull request changes the factory and none of the documents that describe it (${factory_docs[*]}, or a row in factory/decisions/ or an entry in factory/README/ or factory/free-tier/). Update the one that is no longer true, or add a line to \"## Docs updated\": \"None needed:\" followed by the reason."
fi

finish
