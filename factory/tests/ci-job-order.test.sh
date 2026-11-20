#!/usr/bin/env bash
# Tests for the order of ci.yml's jobs: which job each waits for, what each runs or skips on, and what e2e checks out.
. "$(dirname "$0")/helpers.sh"

job() { awk -v job="  $1:" '$0 == job { on = 1; next } /^  [a-z0-9-]+:$/ { on = 0 } on' "$root/factory/workflows/ci.yml"; }
needs() { job "$1" | sed -n 's/^    needs: //p'; }
draft="github.event.pull_request.draft == false"

# A change to the order must fail here: a review that waits for `checks` again costs every run its length (decisions A2).
scenario "ci.yml starts the reviews when e2e has passed, without waiting for checks"
[ "$(needs review)" = e2e ] || fail "expected the review job to need e2e alone, got: $(needs review)"
# With a status function in its condition it would have to name e2e's result, or run after a failed e2e.
! job review | grep '^    if:' | grep -qE 'always\(|cancelled\(|failure\(|success\(' \
  || fail "expected the review job to carry no status function, so that a failed or skipped e2e skips it"

scenario "ci.yml posts the verdicts after the sessions, also when their job failed, and never when it was skipped"
[ "$(needs verdicts)" = "[e2e, review]" ] || fail "expected verdicts to need the review job, and e2e for whether screenshots were taken, got: $(needs verdicts)"
[ "$(job verdicts | grep '^    if:')" = "    if: \${{ !cancelled() && needs.review.result != 'skipped' }}" ] \
  || fail "expected verdicts to run after a failed review job and to be skipped with a skipped one"

scenario "ci.yml lets a pull request merge only when every job passed, and starts a fix round when any failed"
for last in merge start-fix; do
  [ "$(needs "$last")" = "[checks, e2e, review, verdicts]" ] || fail "expected $last to need every other job, got: $(needs "$last")"
done
# With a status function it would have to name each job's result, or run after one that failed or was skipped (decisions M75c).
! job merge | grep '^    if:' | grep -qE 'always\(|cancelled\(|failure\(|success\(' \
  || fail "expected merge to carry no status function, so that a job that failed or was skipped skips it"
fix=$(job start-fix | sed -n '/^    if: >-$/,/^    runs-on:/p')
for failed in checks e2e verdicts; do
  grep -qF "needs.$failed.result == 'failure'" <<<"$fix" || fail "expected start-fix to run when $failed failed"
done

scenario "ci.yml runs nothing on a draft: each job that needs no other carries the condition"
for first in checks e2e; do
  [ -z "$(needs "$first")" ] || fail "expected $first to need no job, got: $(needs "$first")"
  job "$first" | grep -q "^    if: $draft" || fail "expected $first to be skipped for a draft"
done

# Tests of GitHub's merge with main fail against a preview that lacks main's newer features (decisions M442).
scenario "ci.yml runs the end-to-end tests of the commit whose preview it waits for"
tested=$(job e2e | sed -n '/^      - uses: actions\/checkout@/,/^      - /s/^          ref: //p')
deployed=$(job e2e | sed -n '/^      - name: Wait for the Vercel preview$/,/^      - name: /s/^          HEAD_SHA: //p')
[ -n "$deployed" ] || fail "expected the step that waits for the preview to name the commit it waits for"
[ "$tested" = "$deployed" ] || fail "expected e2e to check out the commit whose preview it waits for ($deployed), got: ${tested:-no ref, which is the merge with main}"
