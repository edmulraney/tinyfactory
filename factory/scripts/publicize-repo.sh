#!/usr/bin/env bash
# Makes this repository public with the protections a public one needs, or refuses and says why (decisions S385a).
# Usage: publicize-repo.sh   (from the repo root, with a `gh` login that has admin rights on the repository)
#        Sets only what differs, then reads each setting back and prints it. A call that fails stops it with exit 1.
set -euo pipefail
shopt -s nullglob

die() { echo "$1" >&2; exit 1; }

# GitHub's pinning rule fails a run of any action on a tag, its own included (decisions S682a).
files=(.github/workflows/*.yml .github/workflows/*.yaml .github/actions/*/action.yml)
unpinned=""
if [ ${#files[@]} -gt 0 ]; then
  unpinned=$(grep -H -n -E '^[[:space:]]*(-[[:space:]]+)?uses:' "${files[@]}" \
    | sed -E "s/^([^:]*:[0-9]+):[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?([^[:space:]\"']+).*/\\1: \\3/" \
    | grep -v -E ': \./' | grep -v -E '@[0-9a-f]{40}$' || true)
fi
# A transcript reaches the public on the sessions branch and in artifacts named session-* (decisions A667a, S682b).
unscrubbed=""
if [ ! -f factory/scripts/scrub-tokens.sh ]; then
  unscrubbed="  factory/scripts/scrub-tokens.sh is missing"$'\n'
elif [ -f factory/scripts/save-session.sh ] && ! grep -q 'scrub-tokens\.sh' factory/scripts/save-session.sh; then
  unscrubbed="  factory/scripts/save-session.sh pushes a transcript without running scrub-tokens.sh"$'\n'
fi
for file in "${files[@]}"; do
  if grep -q -E '^[[:space:]]*name:[[:space:]]*session-' "$file" && ! grep -q 'scrub-tokens\.sh' "$file"; then
    unscrubbed+="  $file uploads a transcript without running scrub-tokens.sh"$'\n'
  fi
done
# What was published before the scrub ran becomes readable too, the sessions branch's history included (decisions S682c).
published=""
if [ -f factory/scripts/scrub-tokens.sh ]; then
  heads=$(git ls-remote --heads origin sessions) \
    || die "The repository was left as it is: whether it has a sessions branch could not be read from GitHub."
  if [ -n "$heads" ]; then
    history=$(mktemp)
    trap 'rm -f "$history" "$history.scrubbed"' EXIT
    git fetch --quiet origin sessions && git log -p --text --format= FETCH_HEAD > "$history" \
      && cp "$history" "$history.scrubbed" && factory/scripts/scrub-tokens.sh "$history.scrubbed" \
      || die "The repository was left as it is: the sessions branch's history could not be read and checked for tokens."
    cmp -s "$history" "$history.scrubbed" || published+="  the sessions branch holds a token in its history"$'\n'
  fi
  # A run, and each re-run of it, uses the workflows of the commit it ran on, whenever it uploads.
  install=$(git log --format=%H -S scrub-tokens.sh -- .github/workflows | tail -n 1)
  artifacts=$(gh api 'repos/{owner}/{repo}/actions/artifacts?per_page=100' --paginate --jq '.artifacts[]
      | select((.expired | not) and (.name | startswith("session-"))) | "\(.workflow_run.head_sha) \(.name)"') \
    || die "The repository was left as it is: its artifacts could not be read from GitHub."
  # Each commit is compared once, listed as "<sha> yes|no" lines (decisions H632a).
  judged=""
  while read -r sha name; do
    [ -n "$name" ] || continue
    verdict=$(grep -m 1 "^$sha " <<<"$judged" || true)
    if [ -z "$verdict" ]; then
      status=none
      [ -z "$install" ] || status=$(gh api "repos/{owner}/{repo}/compare/$install...$sha" --jq .status) \
        || die "The repository was left as it is: whether the run that made artifact $name scrubbed tokens could not be read from GitHub."
      case "$status" in identical | ahead) verdict="$sha yes" ;; *) verdict="$sha no" ;; esac
      judged+="$verdict"$'\n'
    fi
    [ "$verdict" = "$sha yes" ] || published+="  artifact $name was made by a run of workflows from before they scrubbed tokens"$'\n'
  done <<<"$artifacts"
fi
if [ -n "$unpinned" ] || [ -n "$unscrubbed" ] || [ -n "$published" ]; then
  echo "The repository was left as it is. Fix what is listed, then run this again." >&2
  if [ -n "$unpinned" ]; then
    echo "Each action must be pinned by its 40-character commit id: GitHub's pinning rule, set here, fails a run of one on a tag:" >&2
    sed 's/^/  /' <<<"$unpinned" >&2
  fi
  if [ -n "$unscrubbed" ]; then
    echo "Each transcript must be scrubbed of tokens before it is published (decisions A667a):" >&2
    printf '%s' "$unscrubbed" >&2
  fi
  if [ -n "$published" ]; then
    echo "What would be published holds tokens from before the scrub: revoke each token, then delete what is listed:" >&2
    printf '%s' "$published" >&2
  fi
  exit 1
fi

read_settings() {
  local repo
  repo=$(gh api 'repos/{owner}/{repo}' --jq '[.visibility,
      (.security_and_analysis.secret_scanning.status // "disabled"),
      (.security_and_analysis.secret_scanning_push_protection.status // "disabled")] | @tsv') \
    && IFS=$'\t' read -r visibility scanning protection <<<"$repo" \
    && approval=$(gh api 'repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval' --jq .approval_policy) \
    && reporting=$(gh api 'repos/{owner}/{repo}/private-vulnerability-reporting' --jq .enabled) \
    && actions=$(gh api 'repos/{owner}/{repo}/actions/permissions' --jq '[.allowed_actions, .sha_pinning_required] | @tsv') \
    && IFS=$'\t' read -r allowed pinning <<<"$actions"
}

read_settings || die "The repository was left as it is: its settings could not be read from GitHub."
changed=0
# set_if <now> <wanted> <what> <command>...
set_if() {
  local now="$1" wanted="$2" what="$3"
  shift 3
  [ "$now" != "$wanted" ] || return 0
  "$@" >/dev/null || die "GitHub refused to set $what, so it and every setting after it were left as they were."
  changed=$((changed + 1))
}
# Visibility first: GitHub's free secret scanning is for a public repository.
set_if "$visibility" public "the visibility to public" gh api -X PATCH 'repos/{owner}/{repo}' -f visibility=public
set_if "$scanning" enabled "secret scanning" gh api -X PATCH 'repos/{owner}/{repo}' --input - \
  <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'
set_if "$protection" enabled "push protection" gh api -X PATCH 'repos/{owner}/{repo}' --input - \
  <<<'{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}'
set_if "$approval" all_external_contributors "approval before an outside contributor's workflow run" \
  gh api -X PUT 'repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval' -f approval_policy=all_external_contributors
set_if "$reporting" true "private vulnerability reporting" gh api -X PUT 'repos/{owner}/{repo}/private-vulnerability-reporting'
set_if "$pinning" true "the rule that every action is pinned to a commit" \
  gh api -X PUT 'repos/{owner}/{repo}/actions/permissions' -F enabled=true -f allowed_actions="$allowed" -F sha_pinning_required=true

read_settings || die "$changed settings were changed, but they could not be read back from GitHub: run this again to check them."
wrong=0
report() {
  echo "$1: $2"
  [ "$2" = "$3" ] || { echo "  expected $3" >&2; wrong=1; }
}
report visibility "$visibility" public
report "secret scanning" "$scanning" enabled
report "push protection" "$protection" enabled
report "approval before an outside contributor's workflow run" "$approval" all_external_contributors
report "private vulnerability reporting" "$reporting" true
report "every action pinned to a commit" "$pinning" true
[ "$wrong" -eq 0 ] || die "GitHub accepted every change, but a setting above reads back otherwise: it is not protected."
echo "the repository is public and protected: $changed settings changed"
