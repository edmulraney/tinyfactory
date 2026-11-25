#!/usr/bin/env bash
# Tests for post-designs.sh: Dara's designs rendered at two widths, kept on the sessions branch and shown on the idea.
. "$(dirname "$0")/helpers.sh"

. "$(dirname "$0")/sessions-remote.sh"

# browser <bash>: stands in for the browser. post-designs.sh hands it no variable, so the stand-in is told $T here,
# and writes the variables it was given to $T/browser-env.
browser() {
  stub pnpm "$1"
  sed -i.bak "2i\\
T='$T'; env > \"\$T/browser-env\"
" "$T/bin/pnpm" && rm "$T/bin/pnpm.bak"
}
# github [sessions]: the repo on GitHub, a browser that writes "<design> at <width>" as each picture, and an idea to comment on.
github() {
  sessions_remote "$@"
  browser 'case "$*" in
    "--dir '"$root"' --filter web exec node --input-type=module - "*"/.design/"*".html "*" "*".png")
      printf "%s at %s" "${9##*/}" "${10}" > "${11}" ;;
    *) echo "unexpected call: pnpm $*" >&2; exit 1 ;;
  esac'
  stub gh 'case "$*" in
    "issue comment 12 --body-file "*) cp "$5" "$T/comment.md" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}
picture() { on_github show "sessions:$(folder_of)/$1-$2.png" | git hash-object --stdin; }
design() { mkdir -p .design && printf '%s\n' "$2" > ".design/$1.html"; }
plain='<!doctype html><html><head><title>Race card</title><style>/* a card */ a { color: inherit }</style></head>
<body><a href="#">Add a race</a><img alt="" src="data:image/png;base64,iVBORw0KGgo="><p>5 km and/or 10 km</p></body></html>'
post() { run "$scripts/post-designs.sh" "${1:-12}"; }
folder_of() { pushed_files | sed -n 's|^\(issue-12/designs/[0-9a-f]\{12\}\)/.*|\1|p' | sort -u; }
expect_comment() { grep -qF -- "$1" "$T/comment.md" 2>/dev/null || fail "expected the comment to hold: $1"; }
expect_nothing_posted() {
  [ ! -e .design/posted ] || fail "expected no .design/posted: refine.yml would take the designs for shown"
  expect_no_call "gh issue comment"
  [ -z "$(pushed_files | grep designs)" ] || fail "expected no design on the sessions branch, found: $(pushed_files)"
  [ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"
}

scenario "shows each design at 375px and at 1280px wide in one comment on the idea, and keeps the file and both pictures"
github sessions
design 2-race-card "$plain"
design 3-fitness-chart "$plain<!-- chart -->"
post
expect_status 0
expect_output "Posted 2 design(s) on idea #12."
folder=$(folder_of)
[ "$(wc -l <<<"$folder" | tr -d ' ')" = 1 ] && [ -n "$folder" ] || fail "expected one folder of designs, found: $folder"
expect_comment "Dara's designs for the screens"
expect_comment "**2-race-card**: [2-race-card.html](https://github.com/owner/repo/blob/sessions/$folder/2-race-card.html)"
expect_comment "![2-race-card at 375px wide](https://github.com/owner/repo/blob/sessions/$folder/2-race-card-375.png?raw=true)"
expect_comment "![2-race-card at 1280px wide](https://github.com/owner/repo/blob/sessions/$folder/2-race-card-1280.png?raw=true)"
expect_comment "![3-fitness-chart at 375px wide](https://github.com/owner/repo/blob/sessions/$folder/3-fitness-chart-375.png?raw=true)"
[ "$(grep -c '^!\[' "$T/comment.md")" = 4 ] || fail "expected exactly four pictures in the comment"
[ "$(on_github show "sessions:$folder/2-race-card-375.png")" = "2-race-card.html at 375" ] || fail "expected the picture at 375px"
[ "$(on_github show "sessions:$folder/2-race-card-1280.png")" = "2-race-card.html at 1280" ] || fail "expected the picture at 1280px"
[ "$(on_github show "sessions:$folder/3-fitness-chart.html")" = "$plain<!-- chart -->" ] || fail "expected the design's own file"
[ "$(pushed_files | grep -c designs)" = 6 ] || fail "expected two files and four pictures pushed, found: $(pushed_files)"
expect_calls 1 "gh "
[ -e .design/posted ] || fail "expected .design/posted, which tells refine.yml that the designs were shown"
[ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"

scenario "adds to the sessions branch and touches nothing else: the transcripts stay, and main is as it was"
github sessions
before=$(on_github rev-parse main)
design 2-race-card "$plain"
post
expect_status 0
pushed_files | grep -qx "pr-7/adam.json" || fail "expected the transcript to still be on the branch"
[ "$(on_github rev-parse main)" = "$before" ] || fail "expected main not to move"

scenario "with no design there is no comment: an empty folder, or none"
github sessions
post
expect_status 1
expect_output "There is no design to show"
expect_nothing_posted
mkdir .design && echo notes > .design/notes.md
post
expect_status 1
expect_nothing_posted
expect_no_call "pnpm"

scenario "refuses a design that loads a script, a style sheet, a font or a picture from another site, and says where"
for load in '<script src="https://cdn.tailwindcss.com"></script>' \
    '<link rel="stylesheet" href="//fonts.googleapis.com/css2?family=Inter">' \
    '<style>body { background: url(http://example.com/a.png) }</style>' \
    '<img src="HTTPS://example.com/a.png">' \
    "<style>@import 'https://example.com/a.css';</style>"; do
  github sessions
  design 2-race-card "$plain"
  design 3-fitness-chart "<!doctype html>
$load"
  post
  expect_status 1
  expect_output "Not posted, because a design holds the address of another site."
  expect_output ".design/3-fitness-chart.html:2:$load"
  expect_no_output "2-race-card"
  expect_nothing_posted
  expect_no_call "pnpm"
  rm -rf "$T/remote.git" "$T/seed" .design
done

scenario "names each line of each design that holds an address, a line to itself"
github sessions
design 2-race-card '<img src="https://example.com/a.png">'
design 3-fitness-chart '<img src="https://example.com/b.png">'
post
expect_status 1
[ "$(grep -c -x '.design/2-race-card.html:1:<img src="https://example.com/a.png">' <<<"$out")" = 1 ] \
  || fail "expected the first design's line to itself, got: $out"
[ "$(grep -c -x '.design/3-fitness-chart.html:1:<img src="https://example.com/b.png">' <<<"$out")" = 1 ] \
  || fail "expected the second design's line to itself, got: $out"
expect_nothing_posted

scenario "the browser is given no token and no secret: only where to find itself"
github sessions
export CLAUDE_CODE_OAUTH_TOKEN=a-session-token ANY_OTHER_SECRET=a-secret
design 2-race-card "$plain"
post
unset CLAUDE_CODE_OAUTH_TOKEN ANY_OTHER_SECRET
expect_status 0
given=$(sed -E 's/=.*//' "$T/browser-env" | grep -v -x -E 'PWD|SHLVL|_|T' | sort | tr '\n' ' ')
[ "$given" = "HOME PATH " ] || fail "expected the browser to be given only PATH and HOME, got: $given"

# Chrome itself draws these: each frame names a file of the machine, by each kind of path a design can hold.
# real_browser: the machine's own pnpm and node, and the session's token where actions/checkout leaves it, beside .design/.
real_browser() {
  real pnpm node
  # Playwright keeps its browser under the HOME of whoever installed it (decisions H698b).
  export HOME="$_home"
  mkdir -p .git && printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic %s\n' "$1" > .git/config
}
# framed <path>: a design whose frame shows the file at that path, if the browser reads it. No path leaves the frame empty.
framed() { echo "<!doctype html><html><body><p>Race card</p><iframe ${1:+src=\"$1\"} style=\"width:100%;height:300px\"></iframe></body></html>"; }

# The next two need the app's Playwright, which a repository with no app does not hold. A project the
# factory sets up holds the app, and runs them.
if [ -d "$root/apps/web" ]; then
scenario "a design that names /proc/self/environ or ../.git/config shows neither file: the frame is as empty as one that names nothing"
github sessions
real_browser a-session-token
design 2-names-environ "$(framed /proc/self/environ)"
design 3-names-git-config "$(framed ../.git/config)"
design 4-names-git-config-whole "$(framed "$PWD/.git/config")"
design 5-names-nothing "$(framed)"
design 6-other-words "$(framed | sed 's/Race card/Fitness chart/')"
post
expect_status 0
for width in 375 1280; do
  empty=$(picture 5-names-nothing "$width")
  for name in 2-names-environ 3-names-git-config 4-names-git-config-whole; do
    [ "$(picture "$name" "$width")" = "$empty" ] || fail "expected $name at ${width}px to be the picture of an empty frame"
  done
  # Equal pictures prove nothing if every picture is the same one.
  [ "$(picture 6-other-words "$width")" != "$empty" ] || fail "expected a design with other words to give another picture at ${width}px"
done

scenario "the picture of a design that names ../.git/config is the same whatever that file holds"
github sessions
real_browser a-session-token
design 3-names-git-config "$(framed ../.git/config)"
post
expect_status 0
first=$(picture 3-names-git-config 1280)
real_browser another-token-of-another-length
post
expect_status 0
[ "$(picture 3-names-git-config 1280)" = "$first" ] || fail "expected the same picture once .git/config holds another token"
fi

scenario "refuses a design whose name would not go into an address as written"
github sessions
design "2 Race_card" "$plain"
post
expect_status 1
expect_output "name a design in lower-case letters, digits and hyphens"
expect_nothing_posted

scenario "refuses an idea's number that is not one"
github sessions
design 2-race-card "$plain"
post "12 --repo other/repo"
expect_status 1
expect_output "is not an idea's number"
expect_nothing_posted

scenario "stops when a design cannot be rendered, or the browser leaves no picture, and posts nothing"
github sessions
design 2-race-card "$plain"
browser 'exit 1'
post
expect_status 1
expect_output "Could not render .design/2-race-card.html at 375px wide, so nothing was posted."
expect_nothing_posted
browser 'exit 0'
post
expect_status 1
expect_output "Could not render .design/2-race-card.html at 375px wide, so nothing was posted."
expect_nothing_posted

scenario "stops when the sessions branch refuses the push, and posts no comment of broken pictures"
github sessions
refuses_pushes
design 2-race-card "$plain"
post
expect_status 1
expect_output "Could not push the designs to the sessions branch (six tries), so no comment was posted."
expect_nothing_posted

scenario "stops when the comment cannot be posted, and says where the designs are"
github sessions
stub gh 'exit 1'
design 2-race-card "$plain"
post
expect_status 1
expect_output "but the comment showing them could not be posted on idea #12."
[ ! -e .design/posted ] || fail "expected no .design/posted: refine.yml would take the designs for shown"
[ -z "$(ls -A "$T/tmp")" ] || fail "expected nothing left in the temporary directory, found: $(ls -A "$T/tmp")"

scenario "a later set of designs replaces none: the design a ticket links is still there"
github sessions
design 2-race-card "$plain"
post
first=$(folder_of)
design 2-race-card "$plain<!-- changed -->"
post
expect_status 0
[ "$(folder_of | wc -l | tr -d ' ')" = 2 ] || fail "expected two folders of designs, found: $(folder_of)"
[ "$(on_github show "sessions:$first/2-race-card.html")" = "$plain" ] || fail "expected the first design as it was posted"
second=$(folder_of | grep -v -x "$first")
expect_comment "sessions/$second/2-race-card-375.png"

scenario "the same designs posted twice leave one copy on the branch"
github sessions
design 2-race-card "$plain"
post
tip=$(on_github rev-parse sessions)
post
expect_status 0
[ "$(on_github rev-parse sessions)" = "$tip" ] || fail "expected no new commit on the sessions branch"
