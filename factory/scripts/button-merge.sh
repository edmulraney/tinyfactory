#!/usr/bin/env bash
# After a merge with GitHub's merge button: finishes shipping when main passes, and takes back a merge that broke it.
# Usage: button-merge.sh tested <pr-number>   prints `tested=true` when the pull request's checks passed with main as
#                                             it was before the merge, else `tested=false`, as after a failed read
#        button-merge.sh finish <pr-number> <main> <before>   approve-merge.yml runs it once main is tested: <main> is
#                                             how the test ended on main as the merge left it, <before> on main as it
#                                             was before, each `success` or `failure`; FAILED holds what the test printed
#        Needs GH_TOKEN (tested: pull-requests and actions: read) and, for finish, what ship.sh needs.
set -euo pipefail

usage="Usage: button-merge.sh tested <pr-number> | button-merge.sh finish <pr-number> <main> <before>"
pr="${2:?$usage}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/shipping.sh"

case "$1" in
  tested)
    # Not knowing runs the test, which decides either way (decisions M439a).
    untested() { echo "$1, so \`main\` is tested." >&2; echo "tested=false"; exit 0; }
    # Each answer is read on a line of its own (decisions H7).
    view=$(retry gh pr view "$pr" --json headRefOid,mergeCommit) || untested "GitHub did not return pull request #$pr"
    head=$(jq -r .headRefOid <<<"$view"); commit=$(jq -r '.mergeCommit.oid // ""' <<<"$view")
    [ -n "$commit" ] || untested "GitHub named no merge commit for pull request #$pr"
    before=$(retry gh api "repos/{owner}/{repo}/commits/$commit" --jq '.parents[0].sha') \
      || untested "GitHub did not say which commit \`main\` was at before ${commit:0:7}"
    run=$(retry "$script_dir/ci-run.sh" "$head" databaseId) || untested "GitHub did not return the ci run for ${head:0:7}"
    [ -n "$run" ] || untested "There is no ci run for ${head:0:7}"
    # Decisions M19.
    passed_with=$(retry gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts" --paginate --jq '.artifacts[].name') \
      || untested "GitHub did not return the record of which \`main\` the ci run for ${head:0:7} passed with"
    grep -qxF "tested-with-main-$before" <<<"$passed_with" || untested "The checks of pull request #$pr did not pass with \`main\` as it was before the merge, ${before:0:7}"
    echo "the checks of pull request #$pr passed with \`main\` as it was before the merge, ${before:0:7}, so it is not tested again" >&2
    echo "tested=true"
    ;;

  finish)
    main="${3:-}"; before="${4:-}"
    printed="${FAILED:-It printed nothing.}"; fence='```'; printed="${printed//$fence/}"
    # stop <why>: stops the script as failed, having said why on the pull request.
    stop() {
      local body="Run the failed \`approve-merge\` run for this pull request again: \`main\` is tested and what follows a merge is done then.

Merged with GitHub's merge button, and nothing that follows a merge was done: $1.$(run_log)"
      echo "$body" >&2
      retry gh pr comment "$pr" --body "$body" >/dev/null || echo "and the pull request could not be told so" >&2
      exit 1
    }
    view=$(retry gh pr view "$pr" --json state,author,mergedBy,comments) \
      || stop "GitHub did not return this pull request, so whether the factory opened it is not known"
    # Only the factory's own are tested and taken back (decisions M439a). `app/claude` is how gh writes the app that
    # opens them, and `app/github-actions` the workflows' own token, whose merge ship.sh finished.
    if [ "$(jq -r .state <<<"$view")" != MERGED ] || [ "$(jq -r .author.login <<<"$view")" != app/claude ] \
        || [ "$(jq -r '.mergedBy.login // ""' <<<"$view")" = app/github-actions ]; then
      exec "$script_dir/ship.sh" --merged "$pr"
    fi

    case "$main $before" in
      "success "*)
        status=0
        # Each reviewer's latest verdict counts (decisions A55b). The button overrides them, and says so once (decisions M439b).
        said="Merged with GitHub's merge button before both reviews had passed"
        unpassed=$(jq -r --arg said "$said" '
          if any(.comments[].body; startswith($said)) then "said"
          else reduce (.comments[].body | capture("^\\*\\*(?<who>[^*\n]+): (?<verdict>PASS|FAIL)\\*\\*")) as $last ({}; .[$last.who] = $last.verdict)
            | if ([.[] | select(. == "PASS")] | length) < 2 then "yes" else "no" end
          end' <<<"$view") || stop "the reviewers' verdicts could not be read from this pull request's comments"
        if [ "$unpassed" = yes ]; then
          retry gh pr comment "$pr" --body "$said. The button counts as the owner's approval, so it ships like any other." >/dev/null \
            || { echo "Pull request #$pr could not be told that it merged before both reviews had passed." >&2; status=1; }
        fi
        "$script_dir/ship.sh" --merged "$pr" || status=$?
        exit "$status" ;;

      "failure success")
        # Nothing that follows a merge is done for a merge that is taken back (decisions M439c).
        message=$(FAILED="$printed" "$script_dir/revert.sh" button "$pr") \
          || stop "\`main\` failed once this pull request was merged, having passed before, and the ticket that takes it back could not be filed or its build started"
        echo "$message"
        retry gh pr comment "$pr" --body "Taken back, with nothing for a person to do: \`main\` failed once this pull request was merged with GitHub's merge button, having passed before the merge, and $message. Nothing that follows a merge was done. The ticket this pull request closes is built again once the take-back has merged.

The test of \`main\` ended:

\`\`\`
$printed
\`\`\`" >/dev/null || { echo "Pull request #$pr could not be told that it is being taken back." >&2; exit 1; } ;;

      "failure failure")
        status=0
        "$script_dir/ship.sh" --merged "$pr" || status=$?
        # The first line says what a person must do (decisions A371a).
        retry gh pr comment "$pr" --body "Read below what the test of \`main\` printed, and file a ticket for what fails: the factory builds it.

\`main\` failed once this pull request was merged with GitHub's merge button, and it already failed before the merge, so this pull request is not what broke it and nothing was taken back.

\`\`\`
$printed
\`\`\`" >/dev/null || { echo "Pull request #$pr could not be told that \`main\` fails." >&2; status=1; }
        # The pull request is merged and its ticket closed, so the label goes on the ticket when there is one, as the installer's does.
        issue=$(retry "$script_dir/linked-issue.sh" "$pr") || issue=""
        if [ -n "$issue" ]; then retry gh issue edit "$issue" --add-label needs-human >/dev/null
        else retry gh pr edit "$pr" --add-label needs-human >/dev/null
        fi || { echo "\`needs-human\` could not be added for pull request #$pr, though \`main\` fails." >&2; status=1; }
        exit "$status" ;;

      *) stop "the test of \`main\` ended with no result (\"$main\" as the merge left it, \"$before\" before the merge)" ;;
    esac
    ;;

  *) echo "$usage" >&2; exit 1 ;;
esac
