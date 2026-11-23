#!/usr/bin/env bash
# Tests for factory/scripts/redact-secret.sh, which takes a secret out of the files under a folder.
. "$(dirname "$0")/helpers.sh"

secret='s3cr3t.+*[x]'
# results: a folder of test results, one file holding the secret twice and one not holding it.
results() {
  mkdir -p results/deep
  printf '{"error":"x-vercel-protection-bypass: %s and %s"}\n' "$secret" "$secret" > results/deep/results.json
  printf 'nothing secret\n' > results/error-context.md
}

scenario "replaces every copy of the secret, its characters taken as they are, and leaves other text alone"
results
SECRET="$secret" run "$scripts/redact-secret.sh" results
expect_status 0
[ "$(cat results/deep/results.json)" = '{"error":"x-vercel-protection-bypass: [redacted] and [redacted]"}' ] \
  || fail "expected both copies replaced, got: $(cat results/deep/results.json)"
[ "$(cat results/error-context.md)" = "nothing secret" ] || fail "expected the other file unchanged"

scenario "does nothing, and succeeds, with no secret or no folder"
results
SECRET="" run "$scripts/redact-secret.sh" results
expect_status 0
grep -qF -- "$secret" results/deep/results.json || fail "expected the file unchanged with no secret"
SECRET="$secret" run "$scripts/redact-secret.sh" missing
expect_status 0

scenario "succeeds, changing nothing, when no file holds the secret"
mkdir -p results
printf 'nothing secret\n' > results/error-context.md
SECRET="$secret" run "$scripts/redact-secret.sh" results
expect_status 0
[ "$(cat results/error-context.md)" = "nothing secret" ] || fail "expected the file unchanged"

scenario "fails, naming the file, when a file it cannot change still holds the secret"
results
chmod a-w results/deep
SECRET="$secret" run "$scripts/redact-secret.sh" results
chmod u+w results/deep
expect_failure
expect_output "results/deep/results.json"
