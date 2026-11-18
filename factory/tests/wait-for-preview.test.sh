#!/usr/bin/env bash
# Tests for wait-for-preview.sh: prints the preview URL to test, or for a skipped commit the last one that worked.
. "$(dirname "$0")/helpers.sh"

sha=abcdef0123456789abcdef0123456789abcdef01
preview=https://myapp-git-feat-7-export-csv-team.vercel.app
# Cut down from pull request #87: Vercel's comment on a skipped commit links its own pages and holds no preview URL.
ready="[vc]: #abc=:eyJ\nThe latest updates. Learn more about [Vercel for GitHub](https://vercel.link/github-learn-more).\n| [myapp](https://vercel.com/team/myapp) | [Ready](https://vercel.com/team/myapp/5NQ) | [Preview]($preview) |"
skipped="[vc]: #abc=:eyJ\nThe latest updates. Learn more about [Vercel for GitHub](https://vercel.link/github-learn-more).\n<details><summary>1 Skipped Deployment</summary>\n| [myapp](https://vercel.com/team/myapp) | [Skipped](https://vercel.com/team/myapp/C4Z) |  |</details>"

older=1111111111111111111111111111111111111111
oldest=2222222222222222222222222222222222222222

# github <head's statuses, newest first> <comments, oldest first>; an earlier commit has those given to `earlier`.
github() {
  export GITHUB_REPOSITORY=owner/repo
  echo "$1" > "$T/statuses.json"
  echo "{\"comments\":$2,\"commits\":[{\"oid\":\"$oldest\"},{\"oid\":\"$older\"},{\"oid\":\"$sha\"}]}" > "$T/comments.json"
  stub gh 'case "$*" in
    "api repos/owner/repo/commits/'"$sha"'/statuses "*) json "$(cat "$T/statuses.json")" "$@" ;;
    "api repos/owner/repo/commits/"*"/statuses "*)
      commit=${2#repos/owner/repo/commits/}; commit=${commit%/statuses}
      json "$(cat "$T/statuses-$commit.json" 2>/dev/null || echo "[]")" "$@" ;;
    "pr view 7 --json comments,commits "*) json "$(cat "$T/comments.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
  stub sleep ':'
}
earlier() { echo "$2" > "$T/statuses-$1.json"; }
vercel() { printf '[{"context":"Vercel","state":"%s","description":"%s"}]' "$1" "$2"; }
comment() { printf '{"author":{"login":"%s"},"body":"%s"}' "$1" "$2"; }
# stdout alone is what the workflow hands to Playwright as the URL.
wait_for() {
  run "$scripts/wait-for-preview.sh" 7 "$sha"
  url=$("$scripts/wait-for-preview.sh" 7 "$sha" 2>/dev/null) || true
}
expect_url() { [ "$url" = "$1" ] || fail "expected stdout to be exactly \"$1\", got \"$url\""; }

scenario "prints the URL in Vercel's comment for a deployed commit"
github "$(vercel success "Deployment has completed")" "[$(comment vercel "$ready")]"
wait_for
expect_status 0
expect_url "$preview"
expect_no_output "skipped"
expect_no_call "sleep"

scenario "waits while Vercel is still building, and reads its newest status"
github "$(vercel pending "Vercel is deploying your app")" "[$(comment vercel "$ready")]"
stub sleep 'echo "[{\"context\":\"Vercel\",\"state\":\"success\",\"description\":\"Deployment has completed\"},{\"context\":\"Vercel\",\"state\":\"pending\",\"description\":\"Skipped\"}]" > "$T/statuses.json"'
wait_for
expect_status 0
expect_url "$preview"
expect_call "sleep 10"

scenario "takes Vercel's newest comment, and no URL from anyone else's"
github "$(vercel success "Deployment has completed")" \
  "[$(comment vercel "[Preview](https://old-one.vercel.app)"),$(comment someone "Try https://mine.vercel.app"),$(comment vercel "$ready")]"
wait_for
expect_status 0
expect_url "$preview"

scenario "for a skipped commit, says skipped and prints the preview the branch was last tested on"
github "$(vercel success "Skipped - Not affected")" \
  "[$(comment github-actions "End-to-end tests ran against https://older.vercel.app. Screenshots and report - https://github.com/owner/repo/actions/runs/1/artifacts/2"),$(comment github-actions "End-to-end tests ran against $preview. Screenshots and report - https://github.com/owner/repo/actions/runs/3/artifacts/4"),$(comment vercel "$skipped")]"
earlier "$older" "$(vercel success "Deployment has completed")"
wait_for
expect_status 0
expect_url "$preview"
expect_output "skipped: Vercel did not deploy $sha (\"Skipped - Not affected\")"
expect_output "Testing $preview"
expect_output "it serves $older"
expect_no_call "commits/$oldest/"

tested="$(comment github-actions "End-to-end tests ran against $preview. Screenshots and report - x")"

scenario "for a skipped commit after a failed deployment, exits 1 naming it and prints no URL"
github "$(vercel success "Skipped - Not affected")" "[$tested,$(comment vercel "$skipped")]"
earlier "$oldest" "$(vercel success "Deployment has completed")"
earlier "$older" "$(vercel failure "Deployment has failed")"
wait_for
expect_status 1
expect_url ""
expect_output "skipped: Vercel did not deploy $sha"
expect_output "its deployment of $older, the last one before it, did not succeed (state: failure)"

scenario "for a skipped commit, looks past earlier commits Vercel skipped or never built"
github "$(vercel success "Skipped - Not affected")" "[$tested,$(comment vercel "$skipped")]"
earlier "$oldest" "$(vercel success "Deployment has completed")"
wait_for
expect_status 0
expect_url "$preview"
expect_output "it serves $oldest"
earlier "$older" "$(vercel success "Skipped - Not affected")"
wait_for
expect_status 0
expect_url "$preview"
expect_output "it serves $oldest"

scenario "for a skipped commit, waits for an earlier commit Vercel is still building"
github "$(vercel success "Skipped - Not affected")" "[$tested,$(comment vercel "$skipped")]"
earlier "$older" "$(vercel pending "Vercel is deploying your app")"
stub sleep 'echo "[{\"context\":\"Vercel\",\"state\":\"error\",\"description\":\"Deployment has failed\"}]" > "$T/statuses-'"$older"'.json"'
wait_for
expect_status 1
expect_url ""
expect_call "sleep 10"
expect_output "its deployment of $older, the last one before it, did not succeed (state: error)"

scenario "for a skipped commit with no earlier deployed commit, exits 1 and prints no URL"
github "$(vercel success "Skipped - Not affected")" "[$tested,$(comment vercel "$skipped")]"
wait_for
expect_status 1
expect_url ""
expect_output "it deployed no earlier commit of pull request #7"

scenario "for a skipped commit, trusts only the end-to-end job's own comment for the URL"
github "$(vercel success "skipped")" \
  "[$(comment someone "End-to-end tests ran against https://mine.vercel.app."),$(comment github-actions "I quote: End-to-end tests ran against https://quoted.vercel.app."),$(comment github-actions "End-to-end tests ran against . Screenshots and report - https://x.vercel.app"),$(comment vercel "$skipped")]"
earlier "$older" "$(vercel success "Deployment has completed")"
wait_for
expect_status 1
expect_url ""
expect_output "skipped: Vercel did not deploy $sha"
expect_output "no earlier commit of pull request #7 was tested on a preview"

scenario "for a skipped commit with no earlier tested preview, exits 1 saying skipped and prints no URL"
github "$(vercel success "Skipped - Not affected")" "[$(comment vercel "$skipped")]"
earlier "$older" "$(vercel success "Deployment has completed")"
wait_for
expect_status 1
expect_url ""
expect_output "skipped: Vercel did not deploy $sha (\"Skipped - Not affected\")"
expect_output "no earlier commit of pull request #7 was tested on a preview"

scenario "tells a deployed commit whose comment has no URL apart from a skipped one"
github "$(vercel success "Deployment has completed")" \
  "[$(comment github-actions "End-to-end tests ran against $preview. Screenshots and report - x"),$(comment vercel "$skipped")]"
wait_for
expect_status 1
expect_url ""
expect_output "Vercel deployed $sha but its PR comment has no preview URL"
expect_no_output "skipped:"

scenario "exits 1 at once when the deployment failed"
github "$(vercel failure "Deployment has failed")" "[$(comment vercel "$ready")]"
wait_for
expect_status 1
expect_url ""
expect_output "Vercel deployment failed for $sha"
expect_no_call "sleep"
expect_no_call "gh pr view"

scenario "exits 1 when Vercel never reports, saying the last state"
github "[]" "[]"
wait_for
expect_status 1
expect_url ""
expect_output "Timed out waiting for Vercel to deploy $sha (last state: none)"
[ "$(grep -c '^sleep ' "$T/calls")" = 120 ] || fail "expected 60 waits in each of the two runs, got $(grep -c '^sleep ' "$T/calls")"

scenario "exits 1 with a message and no URL when the statuses cannot be read"
github "[]" "[$(comment vercel "$ready")]"
stub gh 'echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1'
wait_for
expect_status 1
expect_url ""
expect_output "Could not read Vercel's status on $sha from GitHub"
expect_no_call "sleep"

scenario "exits 1 with a message and no URL when an earlier commit's statuses cannot be read"
github "$(vercel success "Skipped - Not affected")" "[$tested,$(comment vercel "$skipped")]"
stub gh 'case "$*" in
  "api repos/owner/repo/commits/'"$older"'/statuses "*) echo "gh: HTTP 502" >&2; exit 1 ;;
  "api "*) json "$(cat "$T/statuses.json")" "$@" ;;
  *) json "$(cat "$T/comments.json")" "$@" ;;
esac'
wait_for
expect_status 1
expect_url ""
expect_output "Could not read Vercel's status on $older from GitHub"

scenario "exits 1 with a message and no URL when the pull request cannot be read"
github "$(vercel success "Skipped - Not affected")" "[]"
stub gh 'case "$*" in
  "api "*) json "$(cat "$T/statuses.json")" "$@" ;;
  *) echo "gh: HTTP 502" >&2; exit 1 ;;
esac'
wait_for
expect_status 1
expect_url ""
expect_output "Could not read pull request #7 from GitHub"
