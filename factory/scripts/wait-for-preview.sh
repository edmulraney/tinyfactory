#!/usr/bin/env bash
# Waits for Vercel to finish with a pull request's head commit, then prints the preview URL to test, alone on stdout.
# Usage: wait-for-preview.sh <pr-number> <head-sha>   (needs GH_TOKEN and GITHUB_REPOSITORY)
#        Exits 1, with the reason on stderr and no URL, when there is no preview to test.
set -euo pipefail

pr="$1"; sha="$2"
# An answer that never came is not "no status" or "no URL" (decisions H7).
die() { echo "$1" >&2; exit 1; }

# Sets $state and $description to Vercel's newest status on the commit $1.
vercel_status() {
  local status
  status=$(gh api "repos/$GITHUB_REPOSITORY/commits/$1/statuses" \
    --jq '[.[] | select(.context == "Vercel")][0] | "\(.state // "none")\t\(.description // "")"') \
    || die "Could not read Vercel's status on $1 from GitHub, so there is no preview to test"
  state=${status%%$'\t'*}; description=${status#*$'\t'}
}

state=none; description=""
for _ in $(seq 1 60); do   # up to 10 minutes
  vercel_status "$sha"
  case "$state" in
    success) break ;;
    failure|error) die "Vercel deployment failed for $sha" ;;
  esac
  sleep 10
done
[ "$state" = success ] || die "Timed out waiting for Vercel to deploy $sha (last state: $state)"

# The address is sent a secret, so a comment counts only by the app that writes it, which the REST list names in full (decisions U563l).
comments=$(gh api "repos/$GITHUB_REPOSITORY/issues/$pr/comments?per_page=100" --paginate \
    --jq '.[] | select(.user.login == "vercel[bot]" or .user.login == "github-actions[bot]") | {login: .user.login, body: (.body // "")}') \
  || die "Could not read the comments of pull request #$pr from GitHub, so there is no preview URL"
# Two lines, either empty: the URL in Vercel's newest comment, and the URL the end-to-end job last tested.
found=$(jq -rs '
  def url: [scan("https://[a-z0-9-]+\\.vercel\\.app")][0] // "";
  ([.[] | select(.login == "vercel[bot]") | .body] | last // "" | url),
  ([.[] | select(.login == "github-actions[bot]") | .body
    | select(startswith("End-to-end tests ran against https://"))] | last // "" | url)' <<<"$comments") \
  || die "The comments of pull request #$pr could not be read as GitHub returned them, so there is no preview URL"
{ read -r deployed; read -r tested; } <<<"$found" || true
earlier=$(gh pr view "$pr" --json commits --jq '.commits | map(.oid) | .[:(index("'"$sha"'") // 0)] | reverse | join(" ")') \
  || die "Could not read pull request #$pr from GitHub, so there is no preview URL"

# Vercel calls a commit it did not build "Skipped", with the state still `success` (decisions M33).
shopt -s nocasematch
if [[ "$description" == skipped* ]]; then
  skipped="skipped: Vercel did not deploy $sha (\"$description\")"
  # The branch's preview holds this commit's code only if the last build Vercel tried before it worked (decisions M92c).
  built=""
  for commit in $earlier; do
    for _ in $(seq 1 60); do   # up to 10 minutes, for a build still running
      vercel_status "$commit"
      [ "$state" = pending ] || break
      sleep 10
    done
    case "$state" in
      # A commit with no status was pushed along with a later one.
      none) ;;
      success) [[ "$description" == skipped* ]] || { built=$commit; break; } ;;
      *) die "$skipped, and its deployment of $commit, the last one before it, did not succeed (state: $state), so no preview holds this commit's code" ;;
    esac
  done
  [ -n "$built" ] || die "$skipped, and it deployed no earlier commit of pull request #$pr, so there is no preview to test"
  [ -n "$tested" ] || die "$skipped, and no earlier commit of pull request #$pr was tested on a preview, so there is none to test"
  # A skipped commit has no preview of its own: the one this branch was last tested on is used (decisions M92a, M92b).
  echo "$skipped. Testing $tested, the preview this branch was last tested on: it serves $built, the newest commit Vercel did deploy." >&2
  echo "$tested"
  exit 0
fi
[ -n "$deployed" ] || die "Vercel deployed $sha but its PR comment has no preview URL"
echo "$deployed"
