#!/usr/bin/env bash
# Checks every tool and login the bootstrap needs. Changes nothing.
# Exits non-zero and lists the fix for each failure, so a human does them all in one pass.
set -uo pipefail

fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; echo "      fix: $2"; fail=1; }

command -v node >/dev/null && ok "node $(node -v)" || bad "node not found" "install Node.js 20+"
command -v pnpm >/dev/null && ok "pnpm $(pnpm -v)" || bad "pnpm not found" "npm install -g pnpm"
command -v git  >/dev/null && ok "git"             || bad "git not found" "install git"
command -v gh   >/dev/null && ok "gh"              || bad "gh not found" "https://cli.github.com"
command -v jq   >/dev/null && ok "jq"              || bad "jq not found" "brew install jq"
# The factory's scripts and their tests need bash 4.4: an empty array is an error under `set -u` before it.
# macOS ships 3.2, and scaffold.sh ends by running those tests.
if bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }'; then
  ok "bash $(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')"
else
  bad "bash $(bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"') is older than 4.4, which the factory's scripts need" "brew install bash (macOS ships 3.2), and open a new terminal"
fi

if command -v gh >/dev/null; then
  if owner=$(gh api user --jq .login 2>/dev/null); then
    ok "GitHub login: $owner"
    scopes=$(gh auth status --active 2>&1 | grep -i "token scopes" || true)
    for scope in repo workflow project; do
      echo "$scopes" | grep -q "'$scope'" && ok "gh scope: $scope" \
        || bad "gh scope missing: $scope" "gh auth refresh -s $scope"
    done
    ssh_user=$(ssh -T git@github.com 2>&1 | sed -n 's/^Hi \([^!]*\)!.*/\1/p')
    [ "$ssh_user" = "$owner" ] && ok "SSH identity: $ssh_user" \
      || bad "SSH identity is '${ssh_user:-none}', gh login is '$owner'" "add an SSH key for $owner, or run: gh auth setup-git"
  else
    bad "gh not logged in" "gh auth login -s repo,workflow,project"
  fi
fi

# A signing key that needs a passphrase makes `git commit` wait forever at a prompt nobody can see.
if command -v git >/dev/null && [ "$(git config --get commit.gpgsign)" = "true" ]; then
  probe=$(git rev-parse --git-dir >/dev/null 2>&1 && pwd || { d=$(mktemp -d); git init -q "$d"; echo "$d"; })
  tree=$(git -C "$probe" hash-object -t tree -w --stdin </dev/null)
  if perl -e 'alarm 10; exec @ARGV' git -C "$probe" commit-tree "$tree" -m "signing probe" </dev/null >/dev/null 2>&1; then
    ok "commit signing works without a prompt"
  else
    bad "commit signing needs a passphrase or fails (key: $(git config --get user.signingkey))" \
        "git config --local user.signingkey <a key loaded in ssh-agent>, or: git config --local commit.gpgsign false"
  fi
fi

if vercel_user=$(npx --yes vercel@latest whoami 2>/dev/null | tail -1) && [ -n "$vercel_user" ]; then
  ok "Vercel login: $vercel_user"
else
  bad "Vercel not logged in" "npx vercel@latest login"
fi

[ "$fail" -eq 0 ] && echo "preflight passed" || echo "preflight failed"
exit "$fail"
