#!/usr/bin/env bash
# A git repository that stands for GitHub's, in which main can overtake pull request #7's change to a workflow source.
# Usage: . overtaking.sh   (after helpers.sh)
#        two_branches     # makes $T/repo: `first` and `second` each change factory/workflows/ci.yml; sets $second
#        merge_first      # squash-merges `first` into main, as pull request #6
#        a gh stand-in answers from it with: git_as_github "$@"   (it returns 1 for a call it does not know)

# Answers what overtaken.sh asks GitHub, pull request #7 being the branch `second`.
git_as_github() {
  local repo="$T/repo" spec from to
  # A scenario that made no repository is one in which main has not moved.
  if [ ! -d "$repo" ]; then
    case "$*" in
      "api repos/{owner}/{repo}/compare/"*) json "{\"merge_base_commit\":{\"sha\":\"$(printf "a%.0s" $(seq 40))\"},\"base_commit\":{\"sha\":\"$(printf "a%.0s" $(seq 40))\"}}" "$@"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$*" in
    "api repos/{owner}/{repo}/pulls/7/files --paginate "*)
      json "$(git -C "$repo" diff --no-renames --name-only main...second | jq -R '{filename: .}' | jq -s .)" "$@" ;;
    "api repos/{owner}/{repo}/compare/"*)
      spec=${2##*/compare/}; from=${spec%%...*}; to=${spec#*...}
      json "{\"merge_base_commit\":{\"sha\":\"$(git -C "$repo" merge-base "$from" "$to")\"},\"base_commit\":{\"sha\":\"$(git -C "$repo" rev-parse "$from")\"}}" "$@" ;;
    "api --method GET repos/{owner}/{repo}/contents/factory/workflows -f ref="*)
      json "$(git -C "$repo" ls-tree "${6#ref=}" factory/workflows/ | jq -R 'split("\t") | {sha: (.[0] | split(" ")[2]), path: .[1]}' | jq -s .)" "$@" ;;
    "api --method GET repos/{owner}/{repo}/commits -f sha="*" -f path="*)
      json "$(git -C "$repo" log -1 --format='%H%x09%s' "${6#sha=}" -- "${8#path=}" | jq -R 'split("\t") | {sha: .[0], commit: {message: (.[1] + "\n\nIts description.")}}' | jq -s .)" "$@" ;;
    *) return 1 ;;
  esac
}
export -f git_as_github

two_branches() {
  local repo="$T/repo"
  git init --quiet --initial-branch main "$repo"
  mkdir -p "$repo/factory/workflows" "$repo/apps"
  printf 'name: ci\njobs:\n  checks: one\n  e2e: one\n  adam: one\n  ryan: one\n  fits-main: one\n  merge: one\n' > "$repo/factory/workflows/ci.yml"
  echo 'name: fix' > "$repo/factory/workflows/fix.yml"
  echo page > "$repo/apps/page.tsx"
  git -C "$repo" add . && git -C "$repo" commit --quiet -m "chore: begin"
  # Far enough apart in the file that git merges both with no conflict, as it did #270 and #275.
  git -C "$repo" checkout --quiet -b first
  sed -i.bak 's/checks: one/checks: two/' "$repo/factory/workflows/ci.yml" && rm "$repo/factory/workflows/ci.yml.bak"
  git -C "$repo" commit --quiet -am "the first change"
  git -C "$repo" checkout --quiet -b second main
  sed -i.bak 's/merge: one/merge: two/' "$repo/factory/workflows/ci.yml" && rm "$repo/factory/workflows/ci.yml.bak"
  git -C "$repo" commit --quiet -am "the second change"
  git -C "$repo" checkout --quiet main
  second=$(git -C "$repo" rev-parse second)
}
# on_main_commit <title> <command>: a commit on main that the command makes, run in the repository.
on_main_commit() {
  (cd "$T/repo" && git checkout --quiet main && eval "$2" && git add -A && git commit --quiet -m "$1")
}
merge_first() { on_main_commit "ci: change the checks (#6)" "git merge --quiet --squash first >/dev/null"; }
# The engineer's fix: main merged into the branch, which moves the pull request's head.
merge_main_into_second() {
  git -C "$T/repo" checkout --quiet second
  git -C "$T/repo" merge --quiet -m "Merge main" main >/dev/null
  git -C "$T/repo" checkout --quiet main
  second=$(git -C "$T/repo" rev-parse second)
}
