#!/usr/bin/env bash
# Stands in for the repo on GitHub in the tests of the scripts that write the `sessions` branch.
# Usage: . "$(dirname "$0")/sessions-remote.sh"   (after helpers.sh)

# sessions_remote [sessions]: the repo holds `main` and, when asked, a `sessions` branch with one transcript.
sessions_remote() {
  git init --quiet --bare --initial-branch main "$T/remote.git"
  git init --quiet --initial-branch main "$T/seed"
  echo app > "$T/seed/app.txt"
  git -C "$T/seed" add -A && git -C "$T/seed" commit --quiet -m main
  git -C "$T/seed" push --quiet "$T/remote.git" main
  if [ "${1:-}" = sessions ]; then
    git -C "$T/seed" checkout --quiet --orphan sessions
    git -C "$T/seed" rm --quiet -rf .
    mkdir -p "$T/seed/pr-7" && echo '{}' > "$T/seed/pr-7/adam.json"
    git -C "$T/seed" add -A && git -C "$T/seed" commit --quiet -m session
    git -C "$T/seed" push --quiet "$T/remote.git" sessions
  fi
  # git sends the scripts' own GitHub address to this repository, so the address they really push to is what is tested.
  printf '[url "file://%s/remote.git"]\n  insteadOf = https://x-access-token:secret@github.com/owner/repo.git\n' "$T" > "$T/gitconfig"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GH_TOKEN=secret GITHUB_REPOSITORY=owner/repo
  unset GITHUB_SERVER_URL
  stub sleep 'exit 0'
}
on_github() { git --git-dir="$T/remote.git" "$@"; }
pushed_files() { on_github ls-tree -r --name-only sessions 2>/dev/null; }

# refuses_pushes [n]: refuses every push, or only the first n, as when another job's push got there first.
refuses_pushes() {
  printf '#!/usr/bin/env bash\necho push >> "%s/pushes"\n[ "$(wc -l < "%s/pushes")" -gt %s ] && exit 0\nexit 1\n' \
    "$T" "$T" "${1:-999}" > "$T/remote.git/hooks/pre-receive"
  chmod +x "$T/remote.git/hooks/pre-receive"
}
pushes() { wc -l < "$T/pushes" 2>/dev/null | tr -d ' ' || echo 0; }
