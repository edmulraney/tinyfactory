#!/usr/bin/env bash
# Creates or updates the labels the factory uses, and deletes the ones GitHub gives every new
# repo, which nothing uses. Safe to re-run: --force updates a label that exists, and a default
# label that is gone is not looked for again. Which labels, and why: decisions T85a to T85e, T33a, T218, T19a, T353a, M443b.
# It is its own script, called by github.sh during setup, because it is a setup step the
# factory can re-apply by itself: factory/scripts/apply-setup.sh runs it after a merged change,
# with the workflow's own token. So it must need nothing but `issues: write` on the repo (which
# is enough to delete a label too), and it takes the repo as an argument because a workflow's token cannot ask who the logged-in user is.
# Usage: labels.sh <owner/name>
set -euo pipefail

repo="$1"

gh label create ready       -R "$repo" --force --color 0E8A16 --description "Approved for an agent to build"
gh label create needs-human -R "$repo" --force --color D93F0B --description "Agents stopped; a human must decide"
gh label create factory     -R "$repo" --force --color 5319E7 --description "A change to the factory itself; Fred builds it"
gh label create initiative  -R "$repo" --force --color 1D76DB --description "A feature or experiment with a hypothesis"
gh label create tweak       -R "$repo" --force --color C5DEF5 --description "A small, low-risk change"
gh label create bug         -R "$repo" --force --color D73A4A --description "Behaviour differs from what was intended"
gh label create chore       -R "$repo" --force --color EDEDED --description "No behaviour change: refactor, clean-up, docs, tests"
gh label create research    -R "$repo" --force --color 006B75 --description "A question answered from public sources; Rosa builds it"
gh label create in-progress -R "$repo" --force --color FBCA04 --description "An agent is building this"
gh label create deployed    -R "$repo" --force --color 0E8A16 --description "Merged and confirmed live in production"
gh label create reverted    -R "$repo" --force --color B60205 --description "Shipped, then taken back; add ready to build it again"
gh label create revert      -R "$repo" --force --color B60205 --description "Add to a shipped ticket to take it back; the factory takes it off"
gh label create proposal    -R "$repo" --force --color BFD4F2 --description "A change the factory suggests; add ready to accept it, or close it"
gh label create retro       -R "$repo" --force --color D4C5F9 --description "Filed by a retro; it stays once the proposal is accepted"
gh label create waits-for-main -R "$repo" --force --color C2E0C6 --description "What failed lies outside this pull request; the next merge tests it again"
gh label create proof       -R "$repo" --force --color FEF2C0 --description "Something to confirm once a merged change has run; nothing to build"
gh label create idea        -R "$repo" --force --color F9D0C4 --description "A rough idea; Peta turns it into tickets with the owner"

# GitHub's default labels sit beside the real ones in every picker (decisions T85e). One that an
# open ticket or pull request carries is left, and said, because deleting a label takes it off
# everything that has it.
have=$(gh label list -R "$repo" --limit 1000 --json name --jq '.[].name') \
  || { echo "Could not list the labels of $repo, so no default label was deleted." >&2; exit 1; }
for label in documentation duplicate enhancement "good first issue" "help wanted" invalid question wontfix; do
  grep -qxF -- "$label" <<<"$have" || continue
  # The issues list holds pull requests too. One is enough to know the label is in use.
  carried=$(gh api --method GET "repos/$repo/issues" -f labels="$label" -f state=open -f per_page=1 --jq length) \
    || { echo "Could not ask whether an open ticket carries \"$label\", so it was not deleted." >&2; exit 1; }
  if [ "$carried" = 0 ]; then
    gh label delete "$label" -R "$repo" --yes \
      || { echo "Could not delete the default label \"$label\"." >&2; exit 1; }
    echo "deleted the default label \"$label\""
  else
    echo "left the default label \"$label\": an open ticket carries it"
  fi
done

echo "labels ok: $repo"
