#!/usr/bin/env bash
# Checks a research ticket's output: the files its "Checks" section names exist and hold the lines it asks for.
# Usage: check-research.sh <issue-number> [pr-number]   (from the repo root; needs GH_TOKEN or a gh login)
#        check-research.sh --runnable < the "- " lines of a "Checks" section
set -euo pipefail

problems=0
problem() { echo "$1"; problems=1; }

# read_check <line>: sets `quoted`, `path` and `min_files`, or fails when no script can run the line (decisions T33c).
read_check() {
  quoted=$(grep -oE '`[^`]+`' <<<"$1" | sed 's/^`//; s/`$//' || true)
  path=$(head -n 1 <<<"$quoted")
  min_files=1
  if [[ "$1" =~ ^-\ ([0-9]+)\  ]]; then min_files=${BASH_REMATCH[1]}; fi
  # No path climbs out of product/. A count of 0 passes with no file, and one too long for bash reads as passing.
  if ! [[ "$path" =~ ^product/[A-Za-z0-9._/*-]+$ ]] || [[ "$path" == *..* ]] || ! [[ "$min_files" =~ ^[1-9][0-9]{0,3}$ ]]; then
    problem "No script can run the check \"$1\": it must name a path under product/ in backticks, first, and a number before it is 1 to 9999."
    return 1
  fi
}

# check-ticket.sh asks this before a build, so the two never disagree (decisions T33g).
if [ "${1:-}" = "--runnable" ]; then
  while IFS= read -r check; do
    [ -z "$check" ] || read_check "$check" || true
  done
  exit "$problems"
fi

issue="${1:?Usage: check-research.sh <issue-number> [pr-number]}"; pr="${2:-}"
# Read on a line of its own, so a failed read is not taken for a ticket with nothing to check (decisions H7).
json=$(gh issue view "$issue" --json body,labels) \
  || { echo "Could not read issue #$issue from GitHub, so its research output was not checked. Run this check again." >&2; exit 1; }
research=$(jq -r '[.labels[].name] | index("research") != null' <<<"$json")
# ci.yml calls this for every pull request, so a ticket of another kind passes (decisions T33e).
[ "$research" = true ] || { echo "Issue #$issue is not a research ticket; no research output to check."; exit 0; }

checks=$(jq -r '.body // ""' <<<"$json" | tr -d '\r' \
  | awk '$0 == "## Checks" {on = 1; next} /^## / {on = 0} on' \
  | sed 's/<!--.*-->//g' | grep -E '^- ' || true)
[ -n "$checks" ] || { echo "Issue #$issue has no line under \"## Checks\", so nothing says what its research must hold."; exit 1; }

while IFS= read -r check; do
  read_check "$check" || continue
  files=()
  while IFS= read -r file; do
    if [ -f "$file" ]; then files+=("$file"); fi
  done < <(compgen -G "$path" | sort || true)
  if [ "${#files[@]}" -lt "$min_files" ]; then
    problem "\`$path\` matches ${#files[@]} files, and the ticket asks for $min_files."
  fi
  [ "${#files[@]}" -gt 0 ] || continue
  for file in "${files[@]}"; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      # No pipe into grep: it stops reading at the first match, which under pipefail fails a large file that holds it.
      grep -qxF -- "$line" <(tr -d '\r' < "$file") || problem "$file has no line \"$line\"."
    done < <(tail -n +2 <<<"$quoted")
  done
done <<<"$checks"

# Its author reads the web, and research has no reason to change code (decisions T33d).
if [ -n "$pr" ]; then
  repo="${GITHUB_REPOSITORY:-}"
  [ -n "$repo" ] || repo='{owner}/{repo}'
  # GitHub lists at most this many of a pull request's files, so a list this long may be cut short.
  max_files=3000
  # A renamed file is listed under both its names: one moved out of another folder changes that folder.
  changed=$(gh api "repos/$repo/pulls/$pr/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)') \
    || { echo "Could not read the files pull request #$pr changes from GitHub, so its research output was not checked. Run this check again." >&2; exit 1; }
  if [ "$(grep -c . <<<"$changed" || true)" -ge "$max_files" ]; then
    problem "Pull request #$pr changes $max_files files or more, and GitHub lists no more than that, so it cannot be shown to change only product/."
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    problem "Pull request #$pr changes $file. A research ticket's pull request changes only files under product/."
  done < <(grep -vE '^product/' <<<"$changed" || true)
fi

[ "$problems" -eq 0 ] && echo "The research output of #$issue is as its ticket's checks say."
exit "$problems"
