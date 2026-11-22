#!/usr/bin/env bash
# Creates a GitHub token that can only edit the account's project boards, and stores it as the secret BOARD_TOKEN.
# Usage: board-token.sh [name]   (name defaults to the directory name; run after board.sh)
#        Safe to re-run: skips when the secret exists (FORCE=1 replaces it).
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
repo="$owner/$name"
client_id=178c6fc778ccc68e1d6a   # the GitHub CLI's public OAuth app, the same one `gh auth login` uses

number=$(gh project list --owner "$owner" --format json \
  --jq ".projects[] | select(.title==\"$name\") | .number" | head -1)
[ -n "$number" ] || { echo "no board called '$name'; run board.sh first"; exit 1; }

if [ "${FORCE:-}" != 1 ] && gh secret list -R "$repo" --json name --jq '.[].name' | grep -qx BOARD_TOKEN; then
  mark done "board token ok: secret BOARD_TOKEN already set (FORCE=1 to replace it)"
  exit 0
fi

start=$(curl -fsS -X POST https://github.com/login/device/code \
  -H 'Accept: application/json' -d "client_id=$client_id" -d 'scope=project')
code=$(jq -r .user_code <<<"$start")
url=$(jq -r .verification_uri <<<"$start")
device=$(jq -r .device_code <<<"$start")
interval=$(jq -r .interval <<<"$start")

owner_block <<NOTE
Approve the board's token in the browser, signed in as $owner: open the link and enter the one-time code.
$url
$code
The request is for 'project' only: read and write project boards, no repo access.
NOTE
(open "$url" || xdg-open "$url") >/dev/null 2>&1 || true

token=""
deadline=$(( $(date +%s) + $(jq -r .expires_in <<<"$start") ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  perl -e 'select(undef, undef, undef, $ARGV[0])' "$interval"
  answer=$(curl -fsS -X POST https://github.com/login/oauth/access_token \
    -H 'Accept: application/json' -d "client_id=$client_id" -d "device_code=$device" \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code')
  case "$(jq -r '.error // empty' <<<"$answer")" in
    '') token=$(jq -r .access_token <<<"$answer"); scopes=$(jq -r .scope <<<"$answer"); break ;;
    authorization_pending) ;;
    slow_down) interval=$((interval + 5)) ;;
    *) echo "approval failed: $(jq -r .error <<<"$answer")"; exit 1 ;;
  esac
done
[ -n "$token" ] || { echo "nobody approved the code in time"; exit 1; }

# A browser signed in to a different GitHub account would hand back that account's token.
who=$(GH_TOKEN="$token" gh api user --jq .login)
[ "$who" = "$owner" ] || { echo "the code was approved as '$who', not '$owner'; sign in as $owner and re-run"; exit 1; }
# The token must see no repo, so an agent that got hold of it reaches nothing beyond the boards (decisions U2).
[ "$scopes" = project ] || { echo "expected a token with only 'project', got '$scopes'"; exit 1; }
GH_TOKEN="$token" gh api graphql -f owner="$owner" -F number="$number" \
  -f query='query($owner: String!, $number: Int!) { user(login: $owner) { projectV2(number: $number) { id } } }' \
  --jq .data.user.projectV2.id >/dev/null || { echo "the new token cannot read board #$number"; exit 1; }

# apply-setup.sh re-runs board.sh with this token, and start-waiting.sh reads the Backlog's order with it (decisions T335a).
# Piped to gh, so the token is never printed or written to disk.
printf %s "$token" | gh secret set BOARD_TOKEN -R "$repo"
mark done "board token ok: secret BOARD_TOKEN stored (permission: $scopes), board #$number"
