#!/usr/bin/env bash
# Commits and pushes what an engineer had when the session ended without handing it over (decisions A69d).
# Usage: keep-work.sh <what-was-being-built> [default-branch]   e.g. keep-work.sh "issue #12"
#        Prints the branch that holds the work on GitHub, or nothing when there is none to keep.
#        Needs GH_TOKEN (contents: write) and GITHUB_REPOSITORY.
set -euo pipefail

what="$1"; default="${2:-main}"

branch=$(git symbolic-ref --quiet --short HEAD) || branch=""
# Work with no branch is not kept: a branch named here would be one no convention knows and nothing deletes.
if [ -z "$branch" ] || [ "$branch" = "$default" ]; then
  echo "nothing kept: the engineer had not started a branch" >&2
  exit 0
fi

changes=$(git status --porcelain) || { echo "could not read the state of the checkout, so nothing was kept" >&2; exit 1; }
committed=no
if [ -n "$changes" ]; then
  git add -A >&2 || { echo "could not stage the unfinished work, so nothing was kept" >&2; exit 1; }
  # The commit says it is the workflow's. --no-verify: a hook for finished work must not refuse unfinished work.
  name="github-actions[bot]"; email="41898282+github-actions[bot]@users.noreply.github.com"
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
    git commit --quiet --no-verify -m "chore: keep the unfinished work on $what" \
    -m "The session that built this ended before the work was handed over. Nothing here has been verified." >&2 \
    || { git reset --quiet >&2; echo "could not commit the unfinished work, so nothing was kept" >&2; exit 1; }
  committed=yes
fi

# The engineer may have pushed everything and been cut short before opening the pull request: unfinished all the same.
if git merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" 2>/dev/null; then
  echo "everything the engineer had is already on GitHub, on $branch" >&2
  echo "$branch"
  exit 0
fi
if [ -n "$(git branch --remotes --contains HEAD)" ]; then
  echo "nothing kept: the branch holds nothing that is not already on GitHub" >&2
  exit 0
fi

# The workflow's own token starts no workflow: checks do not run again on work nobody finished.
remote="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
# The checkout's stored credential is emptied: sent together with the token in the address, GitHub refuses the pair.
if ! git -c "http.https://github.com/.extraheader=" push --quiet "$remote" "HEAD:refs/heads/$branch" >&2; then
  [ "$committed" = no ] || git reset --quiet HEAD~1
  echo "could not push $branch, so the unfinished work was not kept" >&2
  exit 1
fi
echo "$branch"
