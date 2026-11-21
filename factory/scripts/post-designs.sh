#!/usr/bin/env bash
# Shows on an idea, in one comment, each design in .design/ as a picture at 375px and at 1280px wide (decisions D571a).
# Usage: post-designs.sh <idea-number>   (from the repo root, with the workspace's packages and Chrome installed)
#        A design is .design/<name>.html, its name in lower-case letters, digits and hyphens.
#        A design that holds the address of another site is printed with the line, and nothing is posted.
#        A picture shows only what the design's own text draws: no file of the machine and no other site.
#        Needs GH_TOKEN (contents and issues: write) and GITHUB_REPOSITORY.
#        A failure stops it with a message and exit 1. Once the comment is posted it leaves the empty file .design/posted.
set -euo pipefail

usage="Usage: post-designs.sh <idea-number>"
idea="${1:?$usage}"
script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/../.." && pwd)
die() { echo "$1" >&2; exit 1; }

[[ "$idea" =~ ^[0-9]+$ ]] || die "\"$idea\" is not an idea's number."

names=()
for file in .design/*.html; do
  [ -f "$file" ] || continue
  name=${file#.design/}; name=${name%.html}
  # A name goes into a path, an address and the comment as it is written.
  [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
    || die "$file: name a design in lower-case letters, digits and hyphens, as 2-race-card.html. Nothing was posted."
  names+=("$name")
done
[ "${#names[@]}" -gt 0 ] || die "There is no design to show: .design/ holds no .html file."

# Any address, not only one in an attribute that loads: a design links to "#", and inline SVG needs no xmlns (decisions D571b).
found=""
for name in "${names[@]}"; do
  matches=$(grep -n -i -E '[a-z][a-z0-9+.-]*://|(^|[^:/a-z0-9])//[a-z0-9]' ".design/$name.html" | sed "s|^|.design/$name.html:|") || true
  [ -z "$matches" ] || found+="$matches"$'\n'
done
if [ -n "$found" ]; then
  echo "Not posted, because a design holds the address of another site. A design carries its own styles, draws an icon as inline SVG with no xmlns, and links to \"#\":"
  printf '%s' "$found" | cut -c1-200
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/designs"

# render <name> <width>: the whole page at that width, drawn from the design's text alone (decisions D571d).
# The browser is given no variable but where to find itself, so no token is in the process that draws.
render() {
  env -i PATH="$PATH" HOME="$HOME" pnpm --dir "$root" --filter web exec node --input-type=module - \
    "$PWD/.design/$1.html" "$2" "$tmp/designs/$1-$2.png" >/dev/null <<'JS' \
    && [ -s "$tmp/designs/$1-$2.png" ]
import { readFile } from "node:fs/promises";
import { chromium } from "@playwright/test";

const [design, width, picture] = process.argv.slice(2);
// A request that gets past the page's refusal goes to a port nothing listens on.
const browser = await chromium.launch({ channel: "chrome", proxy: { server: "http://127.0.0.1:9" } });
try {
  const page = await browser.newPage({ viewport: { width: Number(width), height: 800 }, javaScriptEnabled: false });
  await page.route("**/*", (route) => route.abort());
  // A blank page has no address, so a path a design names leads to no file.
  await page.setContent(await readFile(design, "utf8"));
  await page.screenshot({ path: picture, fullPage: true });
} finally {
  await browser.close();
}
JS
}
for name in "${names[@]}"; do
  cp ".design/$name.html" "$tmp/designs/$name.html"
  for width in 375 1280; do
    render "$name" "$width" || die "Could not render .design/$name.html at ${width}px wide, so nothing was posted."
  done
done

# A folder for each set of designs, named by what they hold: a ticket links its design, which a later set never replaces (decisions D571c).
id=$(for name in "${names[@]}"; do echo "$name"; cat ".design/$name.html"; done | git hash-object --stdin) \
  || die "Could not name this set of designs, so nothing was posted."
folder="issue-$idea/designs/${id:0:12}"
address="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/blob/sessions/$folder"

# Peta's next run reads this comment, so it names its writer and says what answers it (decisions A571c).
echo "Dara's designs for the screens the proposal above adds or changes, each at 375px and at 1280px wide. Answering the proposal with \"go\" accepts them; say what to change and they are designed again." > "$tmp/comment.md"
for name in "${names[@]}"; do
  {
    echo
    echo "**$name**: [$name.html]($address/$name.html)"
    for width in 375 1280; do
      echo
      # The address that renders for a reader of a private repo (decisions P23).
      echo "![$name at ${width}px wide]($address/$name-$width.png?raw=true)"
    done
  } >> "$tmp/comment.md"
done

. "$script_dir/sessions-branch.sh"

# keep_designs <clone>: replaced, not added to, so the same designs posted twice leave one copy.
keep_designs() {
  rm -rf "${1:?}/$folder" && mkdir -p "$1/$folder" && cp "$tmp/designs/"* "$1/$folder/"
}

# No comment without the pictures: it would show broken ones.
push_to_sessions "designs: issue-$idea ${id:0:12}" keep_designs \
  || die "Could not push the designs to the sessions branch (six tries), so no comment was posted."

gh issue comment "$idea" --body-file "$tmp/comment.md" >/dev/null \
  || die "The designs are on the sessions branch under $folder, but the comment showing them could not be posted on idea #$idea."
# refine.yml fails a run of Dara's that left no such file, so the idea is told (decisions A571d).
: > .design/posted
echo "Posted ${#names[@]} design(s) on idea #$idea. Do not run this again."
