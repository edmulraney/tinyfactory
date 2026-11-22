#!/usr/bin/env bash
# Shows on a pull request, in a comment, each acceptance criterion's page at each width (decisions P19, P98, P607).
# Usage: post-screenshots.sh <pr-number> <head-sha> <dir>
#        <dir> is the end-to-end job's artifact: test-results/results.json (Playwright's JSON report) and screenshots.
#        Needs GH_TOKEN (contents: write, pull-requests: write) and GITHUB_REPOSITORY.
#        A failure stops it with a message and exit 1; ci.yml lets the review go on without the images.
set -euo pipefail

pr="$1"; head="$2"; dir="$3"
script_dir=$(cd "$(dirname "$0")" && pwd)
report="$dir/test-results/results.json"

issue=$("$script_dir/linked-issue.sh" "$pr") || exit 1
if [ -z "$issue" ]; then
  echo "Pull request #$pr closes no issue, so it has no acceptance tests to show."
  exit 0
fi
[ -f "$report" ] || { echo "No test report at $report, so there are no screenshots to show." >&2; exit 1; }

# Only this ticket's tests (decisions P20) that e2e/test.ts marks as opening a page: Playwright shoots a blank (P21).
screenshots=$(jq -c --arg issue "$issue" '
  [ .. | objects | select(has("specs")) | .specs[]
    | select(.file | startswith("acceptance/\($issue)-"))
    | .title as $title
    # A test holds one entry for each Playwright project, which is one width (decisions P607).
    | [ .tests[]
        | select(any(.annotations[]?; .type == "opened-a-page"))
        | (.results | last | .attachments // [] | map(select(.name == "screenshot" and .contentType == "image/png")) | last) as $shot
        | select($shot != null)
        | {title: $title, width: .projectName, path: $shot.path} ]
    | to_entries[] | .value + {first: (.key == 0)} ]' "$report") \
  || { echo "Could not read the test report at $report." >&2; exit 1; }
count=$(jq length <<<"$screenshots")
if [ "$count" -eq 0 ]; then
  echo "No acceptance test of #$issue opened a page, so there is nothing to show."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The pull request's code wrote the report and this job's token can write the repo, so no path outside <dir> is taken.
mkdir "$tmp/shots"
folder="pr-$pr/screenshots/$head"
# No marker starts the comment: nothing looks for an earlier one (decisions P98).
echo "Screenshots from the acceptance tests of #$issue, at commit ${head:0:7}. Each is the page as its test left it, at each width the tests run at." > "$tmp/comment.md"
# as_text <text>: a title or a width is shown as text, never read as Markdown; and a stray mention would start an agent run.
as_text() { printf '%s' "$1" | sed -e 's/[][\\`*_<>]/\\&/g' -e 's/@claude/claude/g'; }
for ((i = 0; i < count; i++)); do
  title=$(jq -r ".[$i].title" <<<"$screenshots")
  path=$(jq -r ".[$i].path" <<<"$screenshots")
  rel="${path##*/test-results/}"
  case "$rel" in
    *..*|/*) echo "The test report names a screenshot outside the test results: $path" >&2; exit 1 ;;
    *.png) ;;
    *) echo "The test report names a screenshot that is not a .png file: $path" >&2; exit 1 ;;
  esac
  [ -f "$dir/test-results/$rel" ] && [ ! -L "$dir/test-results/$rel" ] \
    || { echo "The screenshot of \"$title\" is not in $dir: test-results/$rel" >&2; exit 1; }
  cp "$dir/test-results/$rel" "$tmp/shots/$((i + 1)).png"
  caption=$(as_text "$title")
  width=$(as_text "$(jq -r ".[$i].width" <<<"$screenshots")")
  {
    if [ "$(jq -r ".[$i].first" <<<"$screenshots")" = true ]; then
      echo
      echo "**$caption**"
    fi
    echo
    echo "At $width width:"
    echo
    # The address that renders for a reader of a private repo (decisions P23).
    echo "![$caption, at $width width](${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/blob/sessions/$folder/$((i + 1)).png?raw=true)"
  } >> "$tmp/comment.md"
done

. "$script_dir/sessions-branch.sh"

# replace_screenshots <clone>: replaced, not added to, so a job run again for the commit leaves no image its comment lacks.
replace_screenshots() {
  rm -rf "${1:?}/$folder" && mkdir -p "$1/$folder" && cp "$tmp/shots/"*.png "$1/$folder/"
}

# No comment without the images: it would show $count broken pictures.
push_to_sessions "screenshots: pr-$pr ${head:0:7}" replace_screenshots \
  || { echo "Could not push the screenshots to the sessions branch (six tries), so no comment was posted." >&2; exit 1; }

# The images stay on the branch when the comment fails: the next run for this commit replaces them.
gh pr comment "$pr" --body-file "$tmp/comment.md" >/dev/null \
  || { echo "The screenshots are on the sessions branch under $folder, but the comment showing them could not be posted on pull request #$pr." >&2; exit 1; }
echo "Posted $count screenshot(s) from the acceptance tests of #$issue on pull request #$pr."
