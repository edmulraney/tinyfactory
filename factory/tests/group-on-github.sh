#!/usr/bin/env bash
# A repo on GitHub whose pull requests wait to merge, and its checks, for the tests of a group.
# Usage: . group-on-github.sh   (after helpers.sh)
#        github_repo                      $T/origin.git holds main, and $T/work is the checkout the test job makes of it
#        pull <number> <file> [<text>]    a pull request from main as it is, on the branch pr-<number>, whose one commit
#                                         writes the file, or with `--first-line <text>` or `--last-line <text>` changes
#                                         that line of it, or with `--add-after <line> <text>` adds a line after that one
#        merge_on_github <number>         squash-merges it into main there, as `gh pr merge --squash` does: GitHub
#                                         reads no .gitattributes (decisions M485a)
#        factory/list.md holds a table and an ordered list, and main's .gitattributes marks it `merge=list`.
#        test_group <number>...           runs test-group.sh on those pull requests, in that order; $T/result.json holds what it found
#        The checks pass unless $T/lint, which `pnpm lint` runs in the checkout, fails.
#        queue_on_github "$@"             answers a gh stand-in's calls from merge-queue.sh: $T/open.json holds the open
#                                         pull requests and $T/comments-<n> the comments of one, the script's own among them

github_repo() {
  git init --quiet --bare --initial-branch main "$T/origin.git"
  git clone --quiet "$T/origin.git" "$T/scratch" 2>/dev/null
  (
    cd "$T/scratch" || exit 1
    mkdir -p apps/web factory/workflows
    echo "the app" > apps/web/page.txt
    mkdir -p .github/workflows
    printf 'name: ci\n\n\n\njobs:\n\n\n\n  checks: one\n' > .github/workflows/ci.yml
    printf 'name: ci\n\n\n\njobs:\n\n\n\n  checks: one\n' > factory/workflows/ci.yml
    mkdir -p factory/scripts
    printf '#!/usr/bin/env bash\necho "test-factory.sh $*" >> "$T/calls"\n' > factory/scripts/test-factory.sh
    chmod +x factory/scripts/test-factory.sh
    printf 'factory/list.md merge=list\n' > .gitattributes
    printf '# List\n\n| Step | Why |\n|---|---|\n| One | first |\n\n1. one\n1. two\n\nThe end.\n' > factory/list.md
    git add . && git commit --quiet -m "chore: start" && git push --quiet origin HEAD:main
  ) || fail "the repo on GitHub could not be made"
  cd "$T" && rm -rf "$T/work"
  git clone --quiet "$T/origin.git" "$T/work"
  cd "$T/work" || exit 1
  main=$(git rev-parse HEAD)
  echo ':' > "$T/lint"
  # Each check is recorded as a call, and lint alone can fail.
  stub pnpm 'if [ "$1" = lint ]; then . "$T/lint"; fi'
}

head_of() { git --git-dir="$T/origin.git" rev-parse "refs/pull/$1/head"; }

pull() {
  (
    cd "$T/scratch" || exit 1
    git fetch --quiet origin main && git checkout --quiet --detach origin/main
    mkdir -p "$(dirname "$2")"
    if [ "${3:-}" = --first-line ]; then sed -i.old "1s/.*/$4/" "$2" && rm "$2.old"
    elif [ "${3:-}" = --last-line ]; then sed -i.old "\$s/.*/$4/" "$2" && rm "$2.old"
    elif [ "${3:-}" = --add-after ]; then
      awk -v after="$4" -v text="$5" '{ print } $0 == after { print text }' "$2" > "$2.new" && mv "$2.new" "$2"
    else echo "${3:-pull request $1}" > "$2"
    fi
    # GitHub keeps refs/pull/<number>/head at the commit the pull request's branch holds.
    git --git-dir="$T/origin.git" symbolic-ref "refs/pull/$1/head" "refs/heads/pr-$1"
    git add . && git commit --quiet -m "feat: change $1" && git push --quiet origin "+HEAD:refs/heads/pr-$1"
  ) || fail "pull request #$1 could not be made"
}

test_group() {
  local number group=()
  for number in "$@"; do group+=("$number:$(head_of "$number")"); done
  run "$scripts/test-group.sh" "$T/result.json" "${group[@]}"
}

result_of() { jq -r --argjson pr "$1" '.pulls[] | select(.number == $pr) | .result' "$T/result.json"; }
expect_result() {
  [ "$(result_of "$1")" = "$2" ] || fail "expected pull request #$1 to be found $2, got: $(result_of "$1")"
}

merge_on_github() {
  (
    cd "$T/scratch" || exit 1
    git fetch --quiet origin main "refs/pull/$1/head" && git checkout --quiet --detach origin/main
    git --attr-source="$(git hash-object -t tree /dev/null)" merge --squash "$(head_of "$1")" >/dev/null 2>&1 && git commit --quiet --allow-empty -m "feat: change $1 (#$1)" \
      && git push --quiet origin HEAD:main || { git reset --quiet --hard; exit 1; }
  )
}
tree_on_github() { git --git-dir="$T/origin.git" rev-parse 'main^{tree}'; }

queue_on_github() {
  local n last
  case "$*" in
    "pr list --state open --base main --limit 100 --json number,headRefOid,isDraft,reviews "*) json "$(cat "$T/open.json")" "$@" ;;
    "api repos/{owner}/{repo}/issues/"*"/comments?per_page=100 --paginate --jq "*)
      n=${2#*/issues/}; n=${n%/comments*}
      json "$(cat "$T/comments-$n" 2>/dev/null || echo "[]")" "$@" ;;
    "pr comment "*" --body "*)
      last=$(cat "$T/last-id" 2>/dev/null || echo 100); echo $((last + 1)) > "$T/last-id"
      [ -e "$T/comments-$3" ] || echo "[]" > "$T/comments-$3"
      jq --argjson id "$((last + 1))" --arg body "$5" '. + [{id: $id, user: {login: "github-actions[bot]"}, body: $body}]' "$T/comments-$3" > "$T/comments.new"
      mv "$T/comments.new" "$T/comments-$3" ;;
    *) echo "unexpected call: gh $*" >&2; return 1 ;;
  esac
}
export -f queue_on_github
