#!/usr/bin/env bash
# Publishes the current directory as a repo under the logged-in GitHub account, and creates the factory's labels.
# Usage: github.sh [name]   (name defaults to the directory name)
#        Safe to re-run: a repo that exists is not made again.
set -euo pipefail
. "$(dirname "$0")/present.sh"

name="${1:-$(basename "$PWD")}"
owner=$(gh api user --jq .login)
repo="$owner/$name"

git rev-parse --git-dir >/dev/null 2>&1 || git init -b main
# A repo made here is private (decisions S3), and one that exists keeps the visibility it has (decisions S385b).
gh repo view "$repo" >/dev/null 2>&1 || gh repo create "$repo" --private
git remote get-url origin >/dev/null 2>&1 || git remote add origin "git@github.com:$repo.git"

if ! git rev-parse HEAD >/dev/null 2>&1; then
  git add -A
  git commit -m "${COMMIT_MESSAGE:-chore: scaffold monorepo skeleton}"
fi
git push -u origin main

# Squash-only merging: the PR title (a Conventional Commit) becomes the single commit on main.
gh api -X PATCH "repos/$repo" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null

# main is merge-only: changes arrive through pull requests; only the repo's admin may push to it
# directly (that is how factory upgrades land). GitHub offers rulesets on a private repo only on
# a paid plan, so on the free plan this is refused and the factory's own guards stand in:
# factory/scripts/guard-main.sh in agent jobs and the guard-main workflow as the alarm.
ruleset="main is merge-only"
if gh api "repos/$repo/rulesets" --jq '.[].name' 2>/dev/null | grep -qx "$ruleset"; then
  echo "main is locked by a GitHub ruleset already"
elif gh api -X POST "repos/$repo/rulesets" --input - >/dev/null 2>&1 <<JSON
{
  "name": "$ruleset",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [{ "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false } }
  ]
}
JSON
then
  echo "main is locked by a GitHub ruleset: pull requests only, admin may bypass"
else
  echo "GitHub will not lock main on this plan (private repo, free plan); the factory's own guards apply"
fi

# The labels have their own script because they are a setup step the factory can re-apply by
# itself after a merge (factory/scripts/apply-setup.sh), with nothing but the workflow's own token.
"$(cd "$(dirname "$0")" && pwd)/labels.sh" "$repo"

mark done "github ok: https://github.com/$repo"
