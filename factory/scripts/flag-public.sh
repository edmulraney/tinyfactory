#!/usr/bin/env bash
# Files one ticket that tells the owner what a repository made public shows, and what is left to them.
# Usage: flag-public.sh   (by flag-public.yml, when the repository becomes public)
#        Run from the repo root: a SECURITY.md there is not asked for again. Needs GH_TOKEN (issues: write).
#        A call to GitHub that fails stops it with a message and exit 1.
set -euo pipefail

title="Protect the repository now that it is public"
die() { echo "$1" >&2; exit 1; }

# Only one the workflows' own token opened: on a public repository anyone can open a ticket with this title (decisions T567a).
open=$(gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --paginate \
  --jq ".[] | select(.pull_request == null and .user.login == \"github-actions[bot]\" and .user.type == \"Bot\"
      and .title == \"$title\") | .number") \
  || die "The owner was not told that the repository is public: the open tickets could not be read from GitHub."
if [ -n "$open" ]; then
  echo "issue #$(sed -n 1p <<<"$open") already tells the owner that the repository is public: no ticket was filed"
  exit 0
fi

add="**Add a \`SECURITY.md\`** at the root of the repository. It tells a stranger whom the factory acts for and how to report a vulnerability. File a Factory ticket for it: its pull request waits for your approval."
report="**Switch on private vulnerability reporting,** in the repository's settings, under Security. A report then reaches you without showing the fault to everyone."
if [ -f SECURITY.md ]; then
  first="Switch on private vulnerability reporting, then close this ticket: the factory cannot."
  steps="1. $report"
else
  first="Add a \`SECURITY.md\` and switch on private vulnerability reporting, then close this ticket: the factory does neither."
  steps="1. $add
2. $report"
fi
# The first line says what a person must do (decisions A371a).
body="$first

This repository became public.

## What anyone can now read

- Every ticket and pull request, with every comment on it.
- Every file with its whole history, the decision record included.
- Every agent's transcript, on the \`sessions\` branch, and the log of every workflow run.

Anyone with a GitHub account can also open an issue or a pull request, and comment on one.

## What the factory still refuses

The factory acts only for an account with write access to this repository, and for its own two bots (decisions U563a). An issue, a comment or a review from any other account starts no build, no agent and no merge, and no agent reads its text. GitHub gives a pull request from a fork no secret, so no agent runs on it.

## What is left to you

$steps"
url=$(gh issue create --title "$title" --label needs-human --body "$body") \
  || die "The owner was not told that the repository is public: the ticket that says so could not be filed."
echo "told the owner that the repository is public: $url"
