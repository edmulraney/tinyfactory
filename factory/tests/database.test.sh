#!/usr/bin/env bash
# Tests for bootstrap's database.sh: Neon's terms are shown and agreed to at a terminal before Vercel accepts them.
. "$(dirname "$0")/helpers.sh"

database="$root/.claude/skills/bootstrap/scripts/database.sh"

# vercel_holds: Vercel has the project shop, with previews kept one day, and the links to Neon's terms. It has the
# database, connected with a branch per preview, once $T/created is there; $T/fail holds a word of the call to fail.
vercel_holds() {
  echo none > "$T/fail"
  stub npx '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "Error: could not reach Vercel" >&2; exit 1; fi
    shift 2
    case "$*" in
      "link "*) ;;
      "integration resource inspect shop --json")
        [ -e "$T/created" ] || exit 1
        echo "{\"resource\":{\"id\":\"store_1\",\"dashboard\":\"https://vercel.com/team/shop\"}}" ;;
      "api /v2/integrations/integration/neon --raw")
        echo "{\"eulaDocUri\":\"https://neon.example/terms\",\"privacyDocUri\":\"https://neon.example/privacy\"}" ;;
      "integration accept-terms neon --yes") ;;
      "integration add neon "*) touch "$T/created" ;;
      "api /v9/projects/shop/env --raw") echo "{\"envs\":[{\"key\":\"DATABASE_URL\"}]}" ;;
      "api /v1/storage/stores/store_1 --raw")
        echo "{\"store\":{\"projectsMetadata\":[{\"id\":\"connection_1\",\"name\":\"shop\",\"deployments\":{\"required\":true,\"actions\":[{\"slug\":\"Neon\",\"environments\":[\"preview\"]}]}}]}}" ;;
      "api /v9/projects/shop --raw") echo "{\"deploymentExpiration\":{\"expirationDays\":1,\"expirationDaysCanceled\":1,\"expirationDaysErrored\":1}}" ;;
      *) echo "unexpected call: vercel $*" >&2; exit 1 ;;
    esac'
}
# at_terminal <answer> <command>...: runs the command with a terminal as its input, at which a person types the answer.
at_terminal() {
  python3 -c '
import os, pty, subprocess, sys
terminal, keyboard = pty.openpty()
os.write(terminal, (sys.argv[1] + "\n").encode())
sys.exit(subprocess.run(sys.argv[2:], stdin=keyboard).returncode)' "$@"
}
expect_the_links() {
  expect_output "Vercel marketplace addendum: https://vercel.com/legal/integration-marketplace-end-users-addendum"
  expect_output "Neon terms of service: https://neon.example/terms"
  expect_output "Neon privacy policy: https://neon.example/privacy"
}
expect_nothing_accepted() {
  expect_no_call "accept-terms"
  expect_no_call "integration add"
}

scenario "shows the links, and creates the database once the person at the terminal agrees"
vercel_holds
run at_terminal y "$database" shop
expect_status 0
expect_the_links
expect_calls 1 "integration accept-terms neon --yes"
expect_calls 1 "integration add neon --name shop"
expect_output "created database 'shop'"

scenario "shows the links, and accepts nothing for a person who answers no"
vercel_holds
run at_terminal no "$database" shop
expect_status 1
expect_the_links
expect_nothing_accepted
expect_output "database not created: the terms were not agreed to"

scenario "accepts nothing for a person who only presses Enter"
vercel_holds
run at_terminal "" "$database" shop
expect_status 1
expect_nothing_accepted

scenario "shows the links and stops, saying why, where nobody is at a terminal"
vercel_holds
run "$database" shop </dev/null
expect_status 1
expect_the_links
expect_nothing_accepted
expect_output "database not created: nobody is at a terminal to agree to these terms"
expect_output "   cd $PWD && $database shop"

scenario "asks nothing where the database already exists, so a run with no terminal confirms it"
vercel_holds
touch "$T/created"
run "$database" shop </dev/null
expect_status 0
expect_no_output "accepts these terms"
expect_nothing_accepted
expect_output "database ok"

scenario "stops, accepting nothing, when Vercel does not answer with the links"
vercel_holds
echo "integrations/integration/neon" > "$T/fail"
run at_terminal y "$database" shop
expect_status 1
expect_nothing_accepted
expect_output "could not read the links to Neon's terms from Vercel"

scenario "stops, accepting nothing, when Vercel answers with no link"
vercel_holds
replace_first "$(cat "$T/bin/npx")" '{\"eulaDocUri\":\"https://neon.example/terms\",\"privacyDocUri\":\"https://neon.example/privacy\"}' '{\"error\":{\"code\":\"forbidden\"}}'
printf '%s\n' "$replaced" > "$T/bin/npx"
run at_terminal y "$database" shop
expect_status 1
expect_nothing_accepted
expect_output "could not read the links to Neon's terms from Vercel"

scenario "creates no database when Vercel refuses to accept the terms"
vercel_holds
echo "accept-terms" > "$T/fail"
run at_terminal y "$database" shop
expect_status 1
expect_no_call "integration add"
expect_output "Vercel did not accept Neon's terms, so no database was created"
