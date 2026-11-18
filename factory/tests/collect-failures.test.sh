#!/usr/bin/env bash
# Tests for factory/scripts/collect-failures.sh, which writes what failed on a pull request to a file.
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fix-round-github.sh"

collect() { run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp "$scripts/collect-failures.sh" "$T/failed.txt" "$@"; }
expect_in_file() { grep -qF -- "$1" "$T/failed.txt" 2>/dev/null || fail "expected the file to hold: $1"; }
expect_not_in_file() { ! grep -qF -- "$1" "$T/failed.txt" 2>/dev/null || fail "expected the file not to hold: $1"; }

scenario "writes the tail of each failed job's log in the latest ci run for the pull request's head, and of no other job"
checks_failed
collect 7
expect_status 0
expect_in_file "===== failed job: checks ====="
expect_in_file "src/page.tsx: unused variable"
expect_not_in_file "the end-to-end log"
expect_not_in_file "conflict"
expect_no_call "jobs/31/logs"
expect_call "gh run list --workflow ci.yml --commit $head --limit 20"

scenario "strips the timestamps and the group lines, and keeps the last 150 lines of a log"
checks_failed
{ echo "2026-11-16T08:00:00.1000000Z ##[group]Run pnpm test"; for n in $(seq 1 200); do echo "2026-11-16T08:00:01.0000000Z line $n"; done; } > "$T/log-30"
collect 7
expect_in_file "line 200"
expect_in_file "line 51"
expect_not_in_file "line 50"
expect_not_in_file "2026-11-16T"
expect_not_in_file "##[group]"

scenario "reads a log that holds terminal escape sequences, which gh refuses unless asked, and strips them (A284)"
checks_failed
printf '2026-11-17T14:36:21.3610161Z \033[36;1mpnpm lint\033[0m\n2026-11-17T14:36:22.0000000Z \033[31msrc/page.tsx: unused variable\033[0m\n' > "$T/log-30"
collect 7
expect_status 0
expect_in_file "===== failed job: checks ====="
[ "$(sed -n 2,3p "$T/failed.txt")" = "pnpm lint"$'\n'"src/page.tsx: unused variable" ] || fail "expected the log's two lines with no escape sequence, got: $(sed -n 2,3p "$T/failed.txt" | cat -v)"
expect_not_in_file "log not available"
[ "$(grep -c 'jobs/30/logs' "$T/calls")" = 1 ] || fail "expected one asking for the log"

scenario "says a pull request conflicts when GitHub reports it, beside what failed"
checks_failed; in_conflict
collect 7
expect_status 0
expect_in_file "===== conflict with main ====="
expect_in_file "git fetch origin main && git merge origin/main"
expect_in_file "===== failed job: checks ====="

scenario "needs no ci run: a head pushed in conflict has none, and the conflict is still written"
checks_failed; in_conflict; no_ci_run
collect 7
expect_status 0
expect_in_file "===== conflict with main ====="
expect_not_in_file "failed job"
expect_no_call "actions/runs"

scenario "leaves the file empty when no job failed and GitHub reports no conflict"
checks_failed; nothing_failed
collect 7
expect_status 0
[ -f "$T/failed.txt" ] && [ ! -s "$T/failed.txt" ] || fail "expected an empty file"
expect_output "wrote 0 lines"

scenario "asks again while GitHub is still working out whether the pull request conflicts"
checks_failed; nothing_failed
printf 'UNKNOWN\nUNKNOWN\nCONFLICTING\n' > "$T/mergeable"
collect 7
expect_in_file "===== conflict with main ====="
[ "$(grep -c '^gh pr view 7' "$T/calls")" = 3 ] || fail "expected three askings, got $(grep -c '^gh pr view 7' "$T/calls")"

scenario "says which workflow source main has overtaken and who did, with no job failed and no conflict, and how to fix it"
checks_failed; nothing_failed; overtaken_by_main
collect 7
expect_status 0
expect_in_file "===== overtaken by main ====="
expect_in_file "\`factory/workflows/ci.yml\` on \`main\` was changed by pull request #6 after this pull request's diff of it was made."
expect_in_file "Merge main into the branch (git fetch origin main && git merge origin/main), keep both changes and push; the new commit is then checked and merged like any other."
[ "$(grep -c '^===== ' "$T/failed.txt")" = 1 ] || fail "expected one heading: the scripts that read the file count them"

scenario "writes nothing about a workflow change main has not overtaken"
checks_failed; nothing_failed; overtaken_by_main; merge_main_into_second; head=$second
collect 7
expect_status 0
[ -f "$T/failed.txt" ] && [ ! -s "$T/failed.txt" ] || fail "expected an empty file"

scenario "stops, and leaves no file, when what main did to an overtaken source cannot be read"
checks_failed; overtaken_by_main
echo "api --method GET repos/{owner}/{repo}/contents/factory/workflows" > "$T/fail"
collect 7
expect_status 1
expect_output "Could not read whether main has overtaken a workflow change in pull request #7"
[ ! -e "$T/failed.txt" ] || fail "expected no file to be left: a failed read is not \"nothing failed\""

scenario "asks only six times, and writes no conflict GitHub never reported"
checks_failed; nothing_failed
echo UNKNOWN > "$T/mergeable"
collect 7
expect_status 0
[ "$(grep -c '^gh pr view 7' "$T/calls")" = 6 ] || fail "expected six askings, got $(grep -c '^gh pr view 7' "$T/calls")"
expect_not_in_file "conflict"

scenario "waits for a log GitHub serves late"
checks_failed
mv "$T/log-30" "$T/log-30.later"
collect 7
expect_status 0
expect_in_file "src/page.tsx: unused variable"
[ "$(grep -c 'jobs/30/logs' "$T/calls")" = 3 ] || fail "expected three askings for the log"

scenario "says in the file that a log never came, with gh's last error and the job's failed steps"
checks_failed
rm "$T/log-30"
echo '{"jobs":[{"id":30,"name":"checks","conclusion":"failure","steps":[{"name":"Set up job","conclusion":"success"},{"name":"Run pnpm lint","conclusion":"failure"},{"name":"Run pnpm test","conclusion":"failure"},{"name":"Run pnpm build","conclusion":"skipped"}]},{"id":31,"name":"e2e","conclusion":"success","steps":[{"name":"Run pnpm test:e2e","conclusion":"failure"}]}]}' > "$T/jobs"
collect 7
expect_status 0
expect_in_file "===== failed job: checks ====="
expect_in_file "(log not available after a minute; read the failed job on the pull request's Checks tab)"
expect_in_file "failed steps: Run pnpm lint; Run pnpm test"
expect_not_in_file "Set up job"
expect_not_in_file "Run pnpm build"
expect_not_in_file "test:e2e"
expect_in_file "gh's last error:"
expect_in_file "  gh: Not Found (HTTP 404)"
[ "$(grep -c 'jobs/30/logs' "$T/calls")" = 6 ] || fail "expected six askings for the log"
[ "$(grep -c '^===== ' "$T/failed.txt")" = 1 ] || fail "expected one heading: the scripts that read the file count them"

scenario "keeps only the last error, and says so when GitHub lists no failed step"
checks_failed
rm "$T/log-30"
stub gh '
  case "$*" in
    *"/jobs/30/logs "*) echo "gh: error $(grep -c "jobs/30/logs" "$T/calls")" >&2; exit 1 ;;
    *"/runs/900/jobs "*) json "$(cat "$T/jobs")" "$@" ;;
    "pr view 7 "*) json "{\"headRefOid\":\"$head\",\"baseRefName\":\"main\",\"mergeable\":\"MERGEABLE\"}" "$@" ;;
    "run list "*) json "$(cat "$T/runs")" "$@" ;;
    *"/pulls/7/files "*) json "[]" "$@" ;;
    *) exit 1 ;;
  esac'
collect 7
expect_status 0
expect_in_file "  gh: error 6"
expect_not_in_file "gh: error 5"
expect_in_file "failed steps: none that GitHub lists"

scenario "says GitHub gave an empty log and no error, when that is why no log came"
checks_failed
: > "$T/log-30"
collect 7
expect_status 0
expect_in_file "(log not available after a minute"
expect_in_file "gh's last answer: an empty log, with no error"
expect_not_in_file "gh's last error"

scenario "shows no error and no step list beside a log that came, even one served late"
checks_failed
mv "$T/log-30" "$T/log-30.later"
collect 7
expect_in_file "src/page.tsx: unused variable"
expect_not_in_file "Not Found"
expect_not_in_file "failed steps"

while IFS='|' read -r words message; do
  scenario "stops with a message, and leaves no file, when this fails: gh $words"
  checks_failed; in_conflict
  echo "$words" > "$T/fail"
  collect 7
  expect_status 1
  expect_output "$message"
  [ ! -e "$T/failed.txt" ] || fail "expected no file to be left: a failed read is not \"nothing failed\""
  [ -z "$(find "$T/tmp" -mindepth 1)" ] || fail "expected no temporary file to be left"
done <<'CALLS'
pr view 7|Could not read pull request #7 from GitHub, so what failed on it is not known.
run list|Could not list the ci runs for 5555555, the head of pull request #7
api repos/owner/myapp/actions/runs/900/jobs|Could not list the jobs of workflow run 900, so which of them failed is not known.
api repos/{owner}/{repo}/pulls/7/files|Could not read whether main has overtaken a workflow change in pull request #7, so what there is to fix on it is not known.
CALLS

scenario "without a pull request number, is refused with its usage, and asks GitHub nothing"
checks_failed
run env GH_TOKEN=workflow-token GITHUB_REPOSITORY=owner/myapp GITHUB_RUN_ID=900 "$scripts/collect-failures.sh" "$T/failed.txt"
expect_status 1
expect_output "Usage: collect-failures.sh <output-file> <pr-number>"
expect_no_call "gh "
[ ! -e "$T/failed.txt" ] || fail "expected no file to be left"

scenario "leaves nothing behind but the file it was asked for"
checks_failed
collect 7
[ -z "$(find "$T/work" "$T/tmp" -mindepth 1)" ] || fail "expected no file left in the working or temporary directory"
