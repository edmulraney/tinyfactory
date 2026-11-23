#!/usr/bin/env bash
# Tests for scrub-tokens.sh, and that each workflow scrubs a transcript before it uploads it as an artifact.
. "$(dirname "$0")/helpers.sh"

# Each token pattern, in a transcript as Claude Code writes it: JSON, a key's lines joined by escaped newlines.
tokens=(
  sk-ant-oat01-Abc_def-0123456789abcdefghij
  ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  ghs_eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJnaXRodWIifQ.c2lnbmF0dXJlLXBhcnQ
  github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz0123456789
  x-access-token:hiddenvalue
  'MIIEowIBAAKCAQEAsecretkeybody'
)
transcript() {
  printf '{"type":"user","text":"env: %s %s\\n%s and %s, %s %s; https://%s@github.com/o/r -----BEGIN RSA PRIVATE KEY-----\\n%s\\n-----END RSA PRIVATE KEY----- the sk-ant- prefix"}\n' \
    "${tokens[@]}" > "$1"
}
expect_no_tokens() {
  local token
  for token in "${tokens[@]}"; do
    ! grep -rqF -- "$token" "$1" || fail "expected no $token in $1, found: $(grep -rF -- "$token" "$1")"
  done
}

scenario "replaces each token pattern with a placeholder and keeps the rest of the transcript"
transcript "$T/out.json"
run "$scripts/scrub-tokens.sh" "$T/out.json"
expect_status 0
expect_no_tokens "$T/out.json"
jq -e . "$T/out.json" > /dev/null || fail "expected the transcript to stay valid JSON, found: $(cat "$T/out.json")"
for placeholder in 'sk-ant-[REDACTED]' 'ghp_[REDACTED]' 'gho_[REDACTED]' 'ghs_[REDACTED]' 'github_pat_[REDACTED]' \
  'https://x-access-token:[REDACTED]@github.com/o/r' '[REDACTED RSA PRIVATE KEY] the sk-ant- prefix'; do
  grep -qF -- "$placeholder" "$T/out.json" || fail "expected $placeholder, found: $(cat "$T/out.json")"
done
grep -qF '"type":"user","text":"env: ' "$T/out.json" || fail "expected the words around the tokens kept"
# A token GitHub issues as a JWT has dots in it, and its signature must go too.
! grep -qF 'c2lnbmF0dXJlLXBhcnQ' "$T/out.json" || fail "expected the whole dotted ghs_ token replaced, found: $(cat "$T/out.json")"

scenario "replaces a private key written on lines of its own"
printf 'before\n-----BEGIN PRIVATE KEY-----\nMIIEsecret\nmore\n-----END PRIVATE KEY-----\nafter\n' > "$T/key.txt"
run "$scripts/scrub-tokens.sh" "$T/key.txt"
expect_status 0
[ "$(cat "$T/key.txt")" = $'before\n[REDACTED PRIVATE KEY]\nafter' ] || fail "expected the key block replaced, found: $(cat "$T/key.txt")"

scenario "scrubs every file in a folder, and skips a path that is not there"
mkdir -p "$T/reviews/cut-short-sessions"
transcript "$T/reviews/adam.json"
transcript "$T/reviews/cut-short-sessions/20261122T000000Z-ryan.json"
run "$scripts/scrub-tokens.sh" "$T/missing" "$T/reviews"
expect_status 0
expect_no_tokens "$T/reviews"

scenario "fails with a message when it cannot rewrite the transcript"
transcript "$T/out.json"
stub perl 'exit 2'
run "$scripts/scrub-tokens.sh" "$T/out.json"
expect_status 1
expect_output "could not scrub the tokens from $T/out.json"

# The step before each transcript's upload scrubs every path it uploads, and the upload needs that step to pass.
scenario "each workflow uploads a transcript only after scrubbing each path it uploads"
uploads=0
for workflow in "$root"/factory/workflows/*.yml; do
  steps=$(awk '/^      - /{ n++ } { print n "\t" $0 }' "$workflow")
  for n in $(grep -E $'^[0-9]+\t +name: session-' <<<"$steps" | cut -f1 | sort -u); do
    uploads=$((uploads + 1))
    upload=$(grep -E "^$n"$'\t' <<<"$steps" | cut -f2-)
    scrub=$(grep -E "^$((n - 1))"$'\t' <<<"$steps" | cut -f2-)
    where="the upload in $(basename "$workflow")"
    grep -q 'uses: actions/upload-artifact@' <<<"$upload" || fail "expected $where to upload an artifact"
    grep -q 'scrub-tokens.sh' <<<"$scrub" || fail "expected the step before $where to run scrub-tokens.sh"
    grep -qF "steps.scrub.outcome == 'success'" <<<"$upload" || fail "expected $where to run only after the scrub passed"
    grep -q '^        id: scrub$' <<<"$scrub" || fail "expected the step before $where to have the id scrub"
    paths=$(sed -n -e 's/^          path: \([^|].*\)/\1/p' -e '/^          path: |$/,/^          [a-z-]*:/s/^            //p' <<<"$upload" | sed 's/\${{ runner.temp }}/$RUNNER_TEMP/')
    while IFS= read -r path; do
      grep -qF -- "\"$path\"" <<<"$scrub" || fail "expected the step before $where to scrub $path, found: $scrub"
    done <<<"$paths"
  done
done
[ "$uploads" -eq 4 ] || fail "expected the four uploads of a transcript (implement, fix, ci, claude), found $uploads"
