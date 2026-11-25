#!/usr/bin/env bash
# Tests for factory/scripts/check-acceptance.sh: every acceptance criterion of a ticket has a test.
. "$(dirname "$0")/helpers.sh"

dir="apps/web/e2e/acceptance"

ticket() {
  jq -n --arg body "$1" '{body: $body}' > "$T/issue.json"
  stub gh 'case "$*" in
    "issue view 12 --json body --jq"*) json "$(cat "$T/issue.json")" "$@" ;;
    *) echo "unexpected call: gh $*" >&2; exit 1 ;;
  esac'
}

two_criteria='## Change
Export the forecast.

## Acceptance criteria
- **AC1:** Given a forecast, when I press Export, then a CSV downloads.
- **AC2:** Given no forecast, then Export is disabled.

## Docs to update
None. AC9 is mentioned here and is not a criterion.'

spec() {
  local file="$dir/$1" from="$2" title
  shift 2
  mkdir -p "$dir"
  printf 'import { expect, test } from "%s";\n' "$from" > "$file"
  for title in "$@"; do
    printf 'test("%s", async ({ page }) => { await page.goto("/"); });\n' "$title" >> "$file"
  done
}

scenario "passes when every criterion has a test"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads" "AC2: Export is disabled"
run "$scripts/check-acceptance.sh" 12
expect_status 0
expect_output "All acceptance criteria of #12 have a test in $dir/12-export-forecast-csv.spec.ts."

scenario "names the criterion that has no test"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output 'No test titled "AC2: …"'
expect_no_output 'No test titled "AC1: …"'
expect_no_output "AC9"

scenario "does not take a test for AC10 as the test for AC1"
ticket '## Acceptance criteria
- **AC1:** One.
- **AC10:** Ten.'
spec 12-export-forecast-csv.spec.ts ../test "AC10: ten"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output 'No test titled "AC1: …"'
expect_no_output 'No test titled "AC10: …"'

scenario "does not take a criterion named in a comment for a test"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads"
echo '// AC2: Export is disabled, still to write' >> "$dir/12-export-forecast-csv.spec.ts"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output 'No test titled "AC2: …"'

# A test declared any other way than plain test(...) is no proof of its criterion (decisions T12).
for modifier in skip fixme only fail describe; do
  scenario "names the criterion whose only test is test.$modifier"
  ticket "$two_criteria"
  spec 12-export-forecast-csv.spec.ts ../test "AC2: Export is disabled"
  printf 'test.%s("AC1: a CSV downloads", async ({ page }) => { await page.goto("/"); });\n' "$modifier" \
    >> "$dir/12-export-forecast-csv.spec.ts"
  run "$scripts/check-acceptance.sh" 12
  expect_status 1
  expect_output "AC1 has no test that counts"
  expect_output "test.$modifier("
  expect_no_output "AC2"
  expect_no_output "All acceptance criteria"
done

scenario "passes a criterion that has a plain test beside a test.fail of the same title"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads" "AC2: Export is disabled"
echo 'test.fail("AC1: a CSV downloads", async () => {});' >> "$dir/12-export-forecast-csv.spec.ts"
run "$scripts/check-acceptance.sh" 12
expect_status 0

# Nothing in an acceptance file is skipped, whatever its title (decisions T13).
scenario "fails a file whose tests sit inside a skipped group, naming the line"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads" "AC2: Export is disabled"
echo 'test.describe.skip("export", () => {});' >> "$dir/12-export-forecast-csv.spec.ts"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output "4:test.describe.skip("
expect_output "must not skip anything"
expect_no_output "has no test that counts"
expect_no_output "All acceptance criteria"

scenario "fails a file with a test that skips itself from inside"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads"
cat >> "$dir/12-export-forecast-csv.spec.ts" <<'SPEC'
test("AC2: Export is disabled", async ({ page }) => {
  test.fixme(true, "not built yet");
});
SPEC
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output '4:  test.fixme(true'
expect_output "must not skip anything"

scenario "fails when the ticket has criteria and no acceptance file"
ticket "$two_criteria"
mkdir -p "$dir"
spec 13-other-ticket.spec.ts ../test "AC1: something else"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output "Missing $dir/12-<slug>.spec.ts"

scenario "finds a criterion's test in either of a ticket's two files, and names both when one has none"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads"
spec 12-export-disabled.spec.ts ../test "AC2: Export is disabled"
run "$scripts/check-acceptance.sh" 12
expect_status 0
expect_output "have a test in $dir/12-export-disabled.spec.ts, $dir/12-export-forecast-csv.spec.ts."
ticket '## Acceptance criteria
- **AC1:** One.
- **AC2:** Two.
- **AC3:** Three.'
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output 'No test titled "AC3: …" in '"$dir/12-export-disabled.spec.ts, $dir/12-export-forecast-csv.spec.ts"
expect_no_output 'No test titled "AC1: …"'

scenario "fails a skipped call and a Playwright import in a ticket's second file"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads" "AC2: Export is disabled"
spec 12-second-file.spec.ts @playwright/test "AC1: a CSV downloads"
echo 'test.skip("later", () => {});' >> "$dir/12-second-file.spec.ts"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output "$dir/12-second-file.spec.ts must import test and expect"
expect_output "$dir/12-second-file.spec.ts must not skip anything"

scenario "fails a file that takes test from Playwright, skipping the accessibility scan"
ticket "$two_criteria"
spec 12-export-forecast-csv.spec.ts @playwright/test "AC1: a CSV downloads" "AC2: Export is disabled"
run "$scripts/check-acceptance.sh" 12
expect_status 1
expect_output 'must import test and expect from "../test"'

scenario "passes a ticket with no acceptance criteria, and says so"
ticket '## Change
Rename a module.

## Docs to update
None.'
run "$scripts/check-acceptance.sh" 12
expect_status 0
expect_output "Issue #12 has no acceptance criteria to check."

scenario "stops when GitHub cannot be read: that is not a ticket with no criteria"
stub gh 'echo "gh: could not connect" >&2; exit 1'
spec 12-export-forecast-csv.spec.ts ../test "AC1: a CSV downloads"
run "$scripts/check-acceptance.sh" 12
expect_failure
expect_no_output "has no acceptance criteria to check"
expect_no_output "All acceptance criteria"
