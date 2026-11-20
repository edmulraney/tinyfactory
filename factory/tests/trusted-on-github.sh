#!/usr/bin/env bash
# Stands in for GitHub in the tests of the scripts that ask trusted.sh whether an account may write to the repo.
# Usage: . "$(dirname "$0")/trusted-on-github.sh"   (after helpers.sh)
#        In a gh stand-in: "api repos/{owner}/{repo}/collaborators/"*) permission_on_github "$@" ;;

# permission_on_github "$@": an account listed in $T/writers may write, any other may only read, as on a public repo.
# With $T/permission-fails present, GitHub does not answer.
permission_on_github() {
  local login="${2#*/collaborators/}"
  login="${login%/permission}"
  if [ -e "$T/permission-fails" ]; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
  if grep -qxF -- "$login" "$T/writers" 2>/dev/null; then echo '{"permission":"write","role_name":"write"}'
  else echo '{"permission":"read","role_name":"read"}'
  fi
}
export -f permission_on_github
