#!/usr/bin/env bash
# Tests for .claude/skills/bootstrap/scripts/board-token.sh: what it asks the owner to approve, and what it stores.
. "$(dirname "$0")/helpers.sh"

board_token="$root/.claude/skills/bootstrap/scripts/board-token.sh"

# github_holds: the board is #4 and no secret is set; GitHub hands out the code ABCD-1234, approved at the first ask.
github_holds() {
  stub open 'exit 0'
  stub xdg-open 'exit 0'
  stub curl '
    case "$*" in
      *"/login/device/code"*) echo "{\"user_code\":\"ABCD-1234\",\"verification_uri\":\"https://github.com/login/device\",\"device_code\":\"d\",\"interval\":0,\"expires_in\":900}" ;;
      *"/login/oauth/access_token"*) echo "{\"access_token\":\"token-1\",\"scope\":\"project\"}" ;;
      *) echo "unexpected call: curl $*" >&2; exit 1 ;;
    esac'
  stub gh '
    case "$*" in
      "api user "*) json "{\"login\":\"owner\"}" "$@" ;;
      "project list "*) json "{\"projects\":[{\"title\":\"myapp\",\"number\":4}]}" "$@" ;;
      "secret list "*) [ ! -f "$T/stored" ] || echo BOARD_TOKEN ;;
      "api graphql "*) echo PVT_1 ;;
      "secret set BOARD_TOKEN -R owner/myapp") cat > "$T/secret" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "asks the owner to approve in one block: the action first, then the link and the one-time code on lines of their own"
github_holds
run "$board_token" myapp
expect_status 0
expect_output "$(printf '\n  Approve the board%ss token in the browser, signed in as owner: open the link and enter the one-time code.\n  https://github.com/login/device\n  ABCD-1234\n  The request' "'")"
[ "$(cat "$T/secret" 2>/dev/null)" = token-1 ] || fail "expected the token stored as the secret, got: $(cat "$T/secret" 2>/dev/null)"
expect_no_output "token-1"
expect_output "✓ board token ok: secret BOARD_TOKEN stored"

scenario "asks for nothing when the secret is already set"
github_holds
touch "$T/stored"
run "$board_token" myapp
expect_status 0
expect_output "✓ board token ok: secret BOARD_TOKEN already set"
expect_no_output "ABCD-1234"
expect_no_call "curl"
