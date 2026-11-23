#!/usr/bin/env bash
# Tests for ci.yml's steps that reset a preview's database branch (M665a) and delete the people it copied (M660a).
. "$(dirname "$0")/helpers.sh"

name="Reset this preview's database branch from production's when it has had a migration this commit lacks"
job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
# The step's lines, read from the source, so a change there fails here.
step() { job checks | awk -v first="      - name: $name" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
commands() { sed -n '/^        run: |$/,$p' <<<"$(step)" | sed -e 1d -e 's/^          //'; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# The SQL that deletes the people, as the workflow sets it for every step.
delete_people=$(awk '/^  DELETE_PEOPLE: \|$/ { on = 1; next } on && !/^    / { exit } on { sub(/^    /, ""); print }' \
  "$root/factory/workflows/ci.yml")
deleted_on() { echo "psql postgres://$1 -X -q -v ON_ERROR_STOP=1 -c do \$\$"; }
# line_of <text>: the line of $T/calls on which the first call holding it starts.
line_of() { grep -n -F -- "$1" "$T/calls" | head -n 1 | cut -d: -f1; }

races='CREATE TABLE "races" ("id" uuid);'
usage='CREATE TABLE "usage_events" ("id" uuid);'
race='ALTER TABLE "runs" ADD COLUMN "race" text;'

# neon: production has had 0000_races; the head of feat/598-race-label holds it, main's 0006_usage-events, and
# its own migration generated again as 0007_race-label. Each branch's rows are in $T/db/<branch id>.
neon() {
  mkdir -p "$T/db" "$T/repo/meta"
  echo '{"branches":[{"id":"br-production","name":"main","default":true},{"id":"br-preview","name":"preview/feat/598-race-label","default":false},{"id":"br-other","name":"preview/feat/1-other","default":false}]}' > "$T/branches"
  echo "1795025367564 $(sha "$races")" > "$T/db/br-production"
  printf '%s' "$races" > "$T/repo/0000_races.sql"
  printf '%s' "$usage" > "$T/repo/0006_usage-events.sql"
  printf '%s' "$race" > "$T/repo/0007_race-label.sql"
  echo '{"entries":[{"when":1795025367564,"tag":"0000_races"},{"when":1795344545180,"tag":"0006_usage-events"},{"when":1795353999203,"tag":"0007_race-label"}]}' > "$T/repo/meta/_journal.json"
  stub curl 'case "$*" in
    *"-X POST"*"/projects/proj/branches/br-preview/restore") ;;
    *"/projects/proj/branches/"*"/databases") echo "{\"databases\":[{\"name\":\"neondb\",\"owner_name\":\"owner\"}]}" ;;
    *"/projects/proj/connection_uri?branch_id="*) all="$*"; id=${all#*branch_id=}; echo "{\"uri\":\"postgres://${id%%&*}\"}" ;;
    *"/projects/proj/branches") cat "$T/branches" ;;
    *) exit 1 ;;
  esac'
  stub psql 'branch=${1#postgres://}
  case "$*" in
    *to_regclass*) if [ -e "$T/db/$branch" ]; then echo t; else echo f; fi ;;
    *"from drizzle.__drizzle_migrations"*) cat "$T/db/$branch" ;;
    *"-c do \$\$"*) ;;
    *) exit 1 ;;
  esac'
  stub gh 'all="$*"; path=${all##*/contents/apps/web/src/db/migrations/}
  [ "${path##*\?ref=}" = head123 ] || exit 1
  cat "$T/repo/${path%%\?ref=*}"'
}
# preview_had <line>...: the preview's branch has had production's migrations and these.
preview_had() { { cat "$T/db/br-production"; printf '%s\n' "$@"; } > "$T/db/br-preview"; }
# As GitHub runs a step that names no shell: bash -e, without pipefail.
step_runs() {
  run env NEON_API_KEY=key NEON_PROJECT_ID=proj GH_TOKEN=token GITHUB_REPOSITORY=owner/myapp DELETE_PEOPLE="$delete_people" \
    BRANCH=feat/598-race-label HEAD_SHA=head123 bash --noprofile --norc -e -c "$(commands)"
}
reset="curl -fsS -X POST -H Authorization: Bearer key -H Content-Type: application/json -d {\"source_branch_id\": \"br-production\"} https://console.neon.tech/api/v2/projects/proj/branches/br-preview/restore"

scenario "a push renaming the pull request's migration resets that pull request's preview database branch from production's"
neon
preview_had "1795349776660 $(sha "$race")"
step_runs
expect_status 0
expect_calls 1 "$reset"
expect_output "reset preview/feat/598-race-label from production's branch, without its people: it had the migration dated 1795349776660, which this commit no longer holds"
expect_output "A preview of head123 built before the reset fails or lacks the migration; the next build of the app applies it."

scenario "a reset deletes the people it copied back from production, and only on the preview's branch"
neon
preview_had "1795349776660 $(sha "$race")"
step_runs
expect_status 0
expect_calls 1 "$(deleted_on br-preview)"
expect_no_call "$(deleted_on br-production)"
[ "$(line_of "/restore")" -lt "$(line_of "$(deleted_on br-preview)")" ] 2>/dev/null \
  || fail "expected the people deleted after the reset, which copies them"

scenario "a reset whose people cannot be deleted fails the step"
neon
preview_had "1795349776660 $(sha "$race")"
mv "$T/bin/psql" "$T/bin/psql.real"
stub psql 'case "$*" in *"-c do"*) echo "permission denied" >&2; exit 3 ;; esac; exec "$T/bin/psql.real" "$@"'
step_runs
expect_failure
expect_output "permission denied"

scenario "a push changing no migration resets nothing"
neon
preview_had "1795353999203 $(sha "$race")"
step_runs
expect_status 0
expect_no_call "restore"
expect_output "preview/feat/598-race-label has had no migration this commit lacks"

scenario "a push changing the pull request's migration under the same name resets the preview's branch"
neon
preview_had "1795353999203 $(sha 'ALTER TABLE "runs" ADD COLUMN "race" integer;')"
step_runs
expect_status 0
expect_calls 1 "$reset"
expect_output "it had 0007_race-label as it was before it changed"

scenario "a migration the preview's branch had from production is not the pull request's, though the head lacks it"
neon
echo "1795344545180 $(sha "$usage")" >> "$T/db/br-production"
echo '{"entries":[{"when":1795025367564,"tag":"0000_races"}]}' > "$T/repo/meta/_journal.json"
preview_had
step_runs
expect_status 0
expect_no_call "restore"
expect_no_call "gh api"

scenario "a preview's branch on which no migration has run resets nothing"
neon
step_runs
expect_status 0
expect_no_call "restore"
expect_output "preview/feat/598-race-label has had no migration this commit lacks"

scenario "a pull request with no preview branch yet resets nothing and reads no database"
neon
echo '{"branches":[{"id":"br-production","name":"main","default":true}]}' > "$T/branches"
step_runs
expect_status 0
expect_output "preview/feat/598-race-label does not exist yet"
expect_no_call "psql"

for broken in "curl:*/projects/proj/branches" "curl:*/databases" "curl:*connection_uri*" "psql:*to_regclass*" \
  "psql:*from drizzle.__drizzle_migrations*" "gh:*_journal.json*" "gh:*0007_race-label.sql*"; do
  scenario "a failed ${broken%%:*} call (${broken#*:}) stops the step with nothing reset"
  neon
  preview_had "1795353999203 $(sha 'ALTER TABLE "runs" ADD COLUMN "race" integer;')"
  # The stand-in fails the one call and answers the rest as before.
  command=${broken%%:*}
  mv "$T/bin/$command" "$T/bin/$command.real"
  # The pattern sits in a variable, so its spaces and parentheses are matched as a pattern, not parsed as code.
  stub "$command" "pattern='${broken#*:}'; case \"\$*\" in \$pattern) echo refused >&2; exit 22 ;; esac; exec \"\$T/bin/$command.real\" \"\$@\""
  step_runs
  expect_failure
  expect_no_call "restore"
done

scenario "ci.yml runs the step in checks before any checkout, and before the step that sets the sign-in link"
line() { job checks | grep -n -F -- "$1" | head -n 1 | cut -d: -f1; }
[ -n "$(step)" ] || fail "expected the step in the checks job"
[ "$(line "      - name: $name")" -lt "$(line "uses: actions/checkout@v4")" ] || fail "expected the step before any checkout: it holds the Neon key"
[ "$(line "      - name: $name")" -lt "$(line "      - name: Switch the emailed sign-in link on")" ] \
  || fail "expected the step before the one that sets the sign-in link, which a reset replaces"
! grep -q 'factory/scripts' <<<"$(step)" || fail "expected the step to hand the Neon key to no script"
grep -qxF '        continue-on-error: true' <<<"$(step)" || fail "expected the step to fail no check"

# The step of `e2e` that deletes the people a preview's branch copied from production (decisions M660a to M660c).
deleting="Delete the people production holds from this preview's database branch"
e2e_step() { job e2e | awk -v first="      - name: $deleting" '$0 == first { on = 1; print; next } /^      (- |#)/ { on = 0 } on'; }
e2e_commands() { sed -n '/^        run: |$/,$p' <<<"$(e2e_step)" | sed -e 1d -e 's/^          //'; }
# preview_built <state>...: Vercel's newest status on the head, one answer for each time it is asked; the last repeats.
# The preview's branch exists and has Neon Auth, which then holds no account.
preview_built() {
  printf '%s\n' "$@" > "$T/states"
  echo '{"branches":[{"id":"br-production","name":"main","default":true},{"id":"br-preview","name":"preview/feat/598-race-label","default":false}]}' > "$T/branches"
  echo t > "$T/auth"
  stub gh 'case "$*" in
    "api repos/owner/myapp/commits/head123/statuses --jq "*) head -n 1 "$T/states"; [ "$(wc -l < "$T/states")" -le 1 ] || sed -i 1d "$T/states" ;;
    *) exit 1 ;;
  esac'
  stub sleep 'exit 0'
  stub curl 'case "$*" in
    *"/projects/proj/branches/br-preview/databases") echo "{\"databases\":[{\"name\":\"neondb\",\"owner_name\":\"owner\"}]}" ;;
    *"/projects/proj/connection_uri?branch_id=br-preview&database_name=neondb&role_name=owner") echo "{\"uri\":\"postgres://br-preview\"}" ;;
    *"/projects/proj/branches") cat "$T/branches" ;;
    *) exit 1 ;;
  esac'
  stub psql 'case "$*" in
    "postgres://br-preview -X -q -v ON_ERROR_STOP=1 -c do \$\$"*) ;;
    *"to_regclass('"'"'neon_auth.\"user\"'"'"')"*) cat "$T/auth" ;;
    *"select count(*) from neon_auth.\"user\""*) echo 0 ;;
    *) exit 1 ;;
  esac'
}
e2e_step_runs() {
  run env NEON_API_KEY=key NEON_PROJECT_ID=proj GH_TOKEN=token GITHUB_REPOSITORY=owner/myapp DELETE_PEOPLE="$delete_people" \
    BRANCH=feat/598-race-label HEAD_SHA=head123 bash --noprofile --norc -e -c "$(e2e_commands)"
}

scenario "once Vercel has built the commit, the people are deleted from the preview's branch, and from no other"
preview_built none pending pending success
e2e_step_runs
expect_status 0
expect_calls 4 "gh api repos/owner/myapp/commits/head123/statuses"
expect_calls 1 "$(deleted_on br-preview)"
expect_no_call "br-production"
[ "$(line_of "$(deleted_on br-preview)")" -gt "$(grep -n -F statuses "$T/calls" | tail -n 1 | cut -d: -f1)" ] \
  || fail "expected the people deleted only after Vercel finished, once the build's migrations have run"
expect_output "emptied the app's tables of preview/feat/598-race-label, which now holds 0 accounts"

for state in failure error; do
  scenario "a build that ended in $state still has the people deleted from the branch it made"
  preview_built "$state"
  e2e_step_runs
  expect_status 0
  expect_calls 1 "$(deleted_on br-preview)"
done

scenario "a product with no Neon Auth has the app's tables emptied, and says so"
preview_built success
echo f > "$T/auth"
e2e_step_runs
expect_status 0
expect_calls 1 "$(deleted_on br-preview)"
expect_no_call "count(*)"
expect_output "emptied the app's tables of preview/feat/598-race-label, which has no Neon Auth"

scenario "a pull request with no preview branch deletes nothing and reads no database"
preview_built success
echo '{"branches":[{"id":"br-production","name":"main","default":true}]}' > "$T/branches"
e2e_step_runs
expect_status 0
expect_output "preview/feat/598-race-label does not exist, so it holds nobody"
expect_no_call "psql"

scenario "Vercel unfinished after 10 minutes fails the step before it reads Neon"
preview_built none pending
e2e_step_runs
expect_failure
expect_calls 60 "gh api repos/owner/myapp/commits/head123/statuses"
expect_output "Vercel has not finished with head123 after 10 minutes (state: pending)"
expect_no_call "curl"

for broken in "gh:*statuses*" "curl:*/projects/proj/branches" "curl:*/databases" "curl:*connection_uri*" \
  "psql:*-c do*" "psql:*to_regclass*" "psql:*count(*)*"; do
  scenario "a failed ${broken%%:*} call (${broken#*:}) fails the step and says nothing was emptied"
  preview_built success
  command=${broken%%:*}
  mv "$T/bin/$command" "$T/bin/$command.real"
  # The pattern sits in a variable, so its spaces and parentheses are matched as a pattern, not parsed as code.
  stub "$command" "pattern='${broken#*:}'; case \"\$*\" in \$pattern) echo refused >&2; exit 22 ;; esac; exec \"\$T/bin/$command.real\" \"\$@\""
  e2e_step_runs
  expect_failure
  [[ "$out" != *"emptied"* ]] || fail "expected no word that the branch was emptied, got: $out"
done

scenario "ci.yml runs the step in e2e before any checkout, with no script, and lets a failure fail the job"
e2e_line() { job e2e | grep -n -F -- "$1" | head -n 1 | cut -d: -f1; }
[ -n "$(e2e_step)" ] || fail "expected the step in the e2e job"
[ "$(e2e_line "      - name: $deleting")" -lt "$(e2e_line "uses: actions/checkout@v4")" ] \
  || fail "expected the step before any checkout: it holds the Neon key, and the tests come after the checkout"
! grep -q 'factory/scripts' <<<"$(e2e_step)" || fail "expected the step to hand the Neon key to no script"
! grep -q 'continue-on-error' <<<"$(e2e_step)" || fail "expected a failed step to fail the job, so no test runs on a copy of people"

# The SQL itself, on a PostgreSQL server of its own, with tables as Neon Auth and the app make them.
# Debian and Ubuntu keep it off the PATH, one folder for each version.
server=$(command -v initdb || true)
for found in /usr/lib/postgresql/*/bin/initdb; do [ -n "$server" ] || [ ! -x "$found" ] || server=$found; done
if [ -z "$server" ]; then
  echo "skipped - the SQL that deletes the people: no PostgreSQL server is installed here (GitHub's runner has one)"
else
  scenario "the SQL deletes every row of the app's tables and every person in Neon Auth, keeps its keys, and runs twice"
  bin=$(dirname "$server")
  "$bin/initdb" -D "$T/pg" -U test --auth=trust >/dev/null 2>&1 || fail "expected initdb to make a database cluster"
  "$bin/pg_ctl" -D "$T/pg" -l "$T/pg.log" -w -o "-k $T -c listen_addresses=''" start >/dev/null 2>&1 \
    || fail "expected the database server to start: $(cat "$T/pg.log" 2>/dev/null)"
  sql() { psql "host=$T dbname=postgres user=test" -X -At -v ON_ERROR_STOP=1 -c "$1"; }
  sql 'create schema neon_auth; create schema drizzle;
    create table drizzle.__drizzle_migrations (hash text); insert into drizzle.__drizzle_migrations values ($$0000$$);
    create table neon_auth."user" (id text primary key, email text);
    create table neon_auth.session (id text, "userId" text references neon_auth."user" (id));
    create table neon_auth.account (id text, "userId" text references neon_auth."user" (id));
    create table neon_auth.verification (id text, identifier text);
    create table neon_auth.jwks (id text); insert into neon_auth.jwks values ($$key$$);
    create table races (id uuid primary key default gen_random_uuid(), account_id text);
    create table runs (race uuid references races (id), account_id text);
    insert into neon_auth."user" values ($$u1$$, $$runner@example.com$$);
    insert into neon_auth.session values ($$s1$$, $$u1$$); insert into neon_auth.account values ($$a1$$, $$u1$$);
    insert into neon_auth.verification values ($$v1$$, $$runner@example.com$$);
    insert into races (account_id) values ($$u1$$); insert into runs select id, $$u1$$ from races;' >/dev/null \
    || fail "expected the tables to be made"
  sql "$delete_people" >/dev/null || fail "expected the SQL to run"
  sql "$delete_people" >/dev/null || fail "expected the SQL to run again on a branch with nobody in it"
  left=$(sql 'select concat_ws($$ $$, (select count(*) from neon_auth."user"), (select count(*) from neon_auth.session),
    (select count(*) from neon_auth.account), (select count(*) from neon_auth.verification), (select count(*) from races),
    (select count(*) from runs), (select count(*) from neon_auth.jwks), (select count(*) from drizzle.__drizzle_migrations))')
  [ "$left" = "0 0 0 0 0 0 1 1" ] \
    || fail "expected no user, session, account, verification, race or run, and the key and migration kept, got: $left"
  sql 'create database no_accounts' >/dev/null
  psql "host=$T dbname=no_accounts user=test" -X -q -v ON_ERROR_STOP=1 -c "$delete_people" \
    || fail "expected the SQL to run on a database with no Neon Auth and no tables"
  "$bin/pg_ctl" -D "$T/pg" -m immediate stop >/dev/null 2>&1
fi
