#!/usr/bin/env bash
# Fails on a document nobody owns, a copied app file that names this project, and a workflow unlike its source.
# Usage: check-inventory.sh   (from the repo root)
set -euo pipefail

bootstrap=".claude/skills/bootstrap"
owned=$(grep -vE '^\s*(#|$)' "$bootstrap/manifest.txt")
seeds=$(cd "$bootstrap/templates" && find . -maxdepth 1 -name '*.md' | sed 's|^\./||')

# Listed on a line of its own, so that a failed listing stops the check (decisions H106).
unlisted() {
  echo "check-inventory.sh must be run inside a git repository: it could not list the $1 with git ls-files, so nothing was checked."
  exit 1
}
factory_files=$(git ls-files factory) || unlisted "files in factory/"
documents=$(git ls-files '*.md') || unlisted "Markdown files"

strays=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # A case names this repo's own pull requests, so no new project is handed one (decisions H345).
  case "$file" in factory/benchmark/*.json) continue ;; esac
  covered=no
  while IFS= read -r path; do
    case "$file" in "$path" | "$path"/*) covered=yes; break ;; esac
  done <<<"$owned"
  [ "$covered" = yes ] || strays+="$file"$'\n'
done <<<"$factory_files"

while IFS= read -r file; do
  case "$file" in "" | */*) continue ;; esac
  # README.md is the front door each repo writes for itself, so it is neither a seed nor in the manifest.
  # LEARNINGS.md is this repo's own record, as README.md is (decisions H322).
  # SECURITY.md is what a repo strangers can see tells them; a project set up is private and has none (decisions U563r).
  [ "$file" = PURPOSE.md ] || [ "$file" = README.md ] || [ "$file" = LEARNINGS.md ] || [ "$file" = SECURITY.md ] \
    || grep -qxF "$file" <<<"$seeds" || strays+="$file"$'\n'
done <<<"$documents"

if [ -n "$strays" ]; then
  printf 'These files have no owner. Delete them, or list them in %s/manifest.txt:\n%s' "$bootstrap" "$strays"
  exit 1
fi

# A file copied into every project names no project and cites no record that starts empty (decisions H614).
app_paths=()
while IFS= read -r path; do
  case "$path" in apps/*) app_paths+=("$path") ;; esac
done <<<"$owned"
copied=()
if [ "${#app_paths[@]}" -gt 0 ]; then
  app_files=$(git ls-files -- "${app_paths[@]}") || unlisted "files the manifest lists under apps/"
  while IFS= read -r file; do
    [ ! -f "$file" ] || copied+=("$file")
  done <<<"$app_files"
fi
if [ "${#copied[@]}" -gt 0 ]; then
  if ! project=$(jq -er '.name | strings | select(. != "")' package.json 2>&1); then
    echo "check-inventory.sh could not read the project's name from the root package.json, so the files copied into every project were not checked: $project"
    exit 1
  fi
  unread() {
    echo "check-inventory.sh could not search the files the manifest lists under apps/, so they were not checked."
    exit 1
  }
  named=$(grep -H -n -o -i -w -F -e "$project" -- "${copied[@]}") || [ $? -eq 1 ] || unread
  cited=$(grep -H -n -o -E '(product|architecture)/decisions(\.md|/)' -- "${copied[@]}") || [ $? -eq 1 ] || unread
  if [ -n "$named$cited" ]; then
    echo "These files are copied into every new project, which has another name and no product or architecture decision. Reword each line, shown as file:line:word:"
    [ -z "$named" ] || printf '%s\n' "$named"
    [ -z "$cited" ] || printf '%s\n' "$cited"
    exit 1
  fi
fi

# A source edited while its installed copy is left alone is a change waiting for the owner (decisions W7).
sources="factory/workflows"
installed=".github/workflows"
differing=$({ [ ! -d "$sources" ] || (cd "$sources" && find . -type f); [ ! -d "$installed" ] || (cd "$installed" && find . -type f); } \
  | sed 's|^\./||' | sort -u | while IFS= read -r name; do
      cmp -s "$sources/$name" "$installed/$name" || echo "$name"
    done)

if [ -n "$differing" ]; then
  # main is fetched where the checkout holds none, and --depth would cut a full clone's history short.
  branch="${GITHUB_BASE_REF:-main}"
  depth=""
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != true ] || depth="--depth=1"
  if ! tip=$(git rev-parse --quiet --verify "origin/$branch^{commit}" 2>/dev/null); then
    # shellcheck disable=SC2086
    git fetch --quiet $depth origin "$branch" 2>/dev/null && tip=$(git rev-parse FETCH_HEAD) || tip=""
  fi
  if [ -z "$tip" ]; then
    printf '%s and %s differ, and %s could not be read to tell whether the change waits to be installed:\n%s\n' \
      "$installed" "$sources" "$branch" "$differing"
    exit 1
  fi
  # A checkout with no history has no merge base to find, and is compared with main as it is now.
  history=yes
  base=$(git merge-base HEAD "$tip" 2>/dev/null) || { history=no; base="$tip"; }
  here_id() { if [ -f "$1" ]; then git hash-object "$1"; else echo absent; fi; }
  base_id() { git rev-parse --quiet --verify "$base:$1" 2>/dev/null || echo absent; }

  late_problem() {
    if [ "$(here_id "$sources/$1")" = "$(base_id "$sources/$1")" ]; then
      echo "$installed/$1 is not what $sources/$1 says, on $branch as well as here: a merged change was not installed. Start the install-workflows workflow for the pull request that made it; if it refused the change, put $sources/$1 back to what $installed/$1 holds, in a ticket of its own."
    else
      # The installer would refuse it once merged: the diff that was reviewed would start from a source that never ran.
      echo "$sources/$1 on $branch already differs from $installed/$1, so a change on top of it could not be installed. First put $sources/$1 back to what $installed/$1 holds, in a ticket of its own; then make this change from there."
    fi
  }

  # The first parent of GitHub's merge commit is the commit of main the checkout was made with (decisions W134a).
  recent=20
  made_with=""
  one_install_behind() {
    [ "$history" = no ] && [ -n "$depth" ] || return 1
    [ "$(base_id "$sources/$1")" = "$(base_id "$installed/$1")" ] || return 1
    if [ -z "$made_with" ]; then
      made_with=$(git cat-file -p HEAD 2>/dev/null | sed -n 's/^parent //p' | head -n 1)
      [ -n "$made_with" ] || { made_with=none; return 1; }
      if ! git fetch --quiet --depth="$recent" origin "$branch" 2>/dev/null; then
        printf '%s differs from what %s holds, and the last %s commits of %s could not be read to tell an install that landed after this checkout was made from an edit.\n' \
          "$installed/$1" "$branch" "$recent" "$branch"
        exit 1
      fi
      # Asked of git, not searched for in a list of main's commits (decisions W187).
      git merge-base --is-ancestor "$made_with" "$tip" 2>/dev/null || made_with=none
    fi
    [ "$made_with" != none ] || return 1
    [ "$(here_id "$installed/$1")" = "$(git rev-parse --quiet --verify "$made_with:$installed/$1" 2>/dev/null || echo absent)" ]
  }

  # GitHub names the running workflow as owner/repo/.github/workflows/ci.yml@refs/pull/7/merge (decisions W134b).
  running="${GITHUB_WORKFLOW_REF:-}"
  running="${running%@*}"
  running="${running#*/"$installed"/}"
  stale_run() {
    echo "$installed/$1 is an install behind $branch, where it now matches its source. Nothing was edited, but this run uses the workflow from before the install. Merge $branch into the branch and push, which starts a run with the workflow $branch holds: git fetch origin $branch && git merge origin/$branch"
  }

  problems=""
  late=""
  while IFS= read -r name; do
    if [ "$(here_id "$installed/$name")" != "$(base_id "$installed/$name")" ] && one_install_behind "$name"; then
      if [ "$name" = "$running" ]; then problems+="$(stale_run "$name")"$'\n'; continue; fi
      echo "this checkout is one install behind $branch, where $installed/$name now matches its source: nothing was edited"
      [ "$(here_id "$sources/$name")" = "$(base_id "$sources/$name")" ] || echo "installed once this change merges: $sources/$name"
    elif [ "$(here_id "$installed/$name")" != "$(base_id "$installed/$name")" ]; then
      problems+="$installed/$name was edited directly. Undo that and change $sources/$name: the installer copies it in once that merges."$'\n'
    elif [ "$(here_id "$sources/$name")" = "$(base_id "$sources/$name")" ]; then
      late+="$name"$'\n'
    elif [ "$(base_id "$sources/$name")" != absent ] && [ "$(base_id "$sources/$name")" != "$(base_id "$installed/$name")" ]; then
      # (A source new to the branch is let through; that is how the sources first arrived.)
      late+="$name"$'\n'
    else
      echo "installed once this change merges: $sources/$name"
    fi
  done <<<"$differing"

  # An install lands some twenty seconds after its merge, so the branch is read again (decisions W102a, W102b).
  interval=10
  limit=120
  waited=0
  [ -z "$late" ] || echo "a workflow source and its installed copy differ on $branch; reading $branch again for up to $limit seconds, in case the install is on its way"
  while [ -n "$late" ] && [ "$waited" -lt "$limit" ]; do
    sleep "$interval"
    waited=$((waited + interval))
    # shellcheck disable=SC2086
    if ! git fetch --quiet $depth origin "$branch" 2>/dev/null; then
      printf '%s and %s differ on %s, and after %s seconds %s could not be read again to tell whether the install had arrived:\n%s' \
        "$installed" "$sources" "$branch" "$waited" "$branch" "$late"
      exit 1
    fi
    tip=$(git rev-parse FETCH_HEAD)
    tip_id() { git rev-parse --quiet --verify "$tip:$1" 2>/dev/null || echo absent; }
    still=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [ "$(tip_id "$sources/$name")" != "$(tip_id "$installed/$name")" ]; then
        still+="$name"$'\n'
      elif [ "$name" = "$running" ] && [ "$(here_id "$installed/$name")" != "$(tip_id "$installed/$name")" ]; then
        problems+="$(stale_run "$name")"$'\n'
      elif [ "$(here_id "$sources/$name")" = "$(base_id "$sources/$name")" ]; then
        echo "installed on $branch since this checkout was made: $sources/$name"
      else
        echo "installed once this change merges: $sources/$name"
      fi
    done <<<"$late"
    late="$still"
  done
  if [ -n "$late" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] || problems+="$(late_problem "$name")"$'\n'
    done <<<"$late"
    problems+="This check read $branch again every $interval seconds for $waited seconds, in case an install was on its way, and they still differ."$'\n'
  fi
  if [ -n "$problems" ]; then
    printf '%s' "$problems"
    exit 1
  fi
fi
echo "inventory ok: every factory file and root document is accounted for, no copied app file names this project, and every installed workflow matches its source or waits to be installed"
