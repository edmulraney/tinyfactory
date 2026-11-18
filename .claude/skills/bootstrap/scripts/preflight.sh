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
# The later steps call these: the purpose interview and the agents' token (claude), the sign-in
# secret (openssl), and the scripts that read what GitHub, Vercel and Neon answer (python3, curl).
command -v claude  >/dev/null && ok "claude"  || bad "claude not found" "install Claude Code: https://claude.com/claude-code"
command -v python3 >/dev/null && ok "python3" || bad "python3 not found" "install Python 3"
command -v openssl >/dev/null && ok "openssl" || bad "openssl not found" "install OpenSSL"
command -v curl    >/dev/null && ok "curl"    || bad "curl not found" "install curl"

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
# commit-tree signs only when told to (-S). With SSH_ASKPASS forced to a program that fails,
# ssh-keygen fails at once where it would have asked for the passphrase.
if command -v git >/dev/null && [ "$(git config --get commit.gpgsign)" = "true" ]; then
  probe=$(git rev-parse --git-dir >/dev/null 2>&1 && pwd || { d=$(mktemp -d); git init -q "$d"; echo "$d"; })
  tree=$(git -C "$probe" hash-object -t tree -w --stdin </dev/null)
  if SSH_ASKPASS=/usr/bin/false SSH_ASKPASS_REQUIRE=force perl -e 'alarm 10; exec @ARGV' \
    git -C "$probe" commit-tree -S "$tree" -m "signing probe" </dev/null >/dev/null 2>&1; then
    ok "commit signing works without a prompt"
  else
    bad "commit signing needs a passphrase or fails (key: $(git config --get user.signingkey))" \
        "sign with a key ssh-agent holds (ssh-add -l lists them): git config --global user.signingkey <its .pub file>, or: git config --global commit.gpgsign false"
  fi
fi

if vercel_user=$(npx --yes vercel@latest whoami 2>/dev/null | tail -1) && [ -n "$vercel_user" ]; then
  ok "Vercel login: $vercel_user"
else
  bad "Vercel not logged in" "npx vercel@latest login"
fi

[ "$fail" -eq 0 ] && echo "preflight passed" || echo "preflight failed"
exit "$fail"
