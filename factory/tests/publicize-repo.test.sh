#!/usr/bin/env bash
# Tests for factory/scripts/publicize-repo.sh, which makes the repository public with the protections it needs.
. "$(dirname "$0")/helpers.sh"

pin=b906affcce14559ad1aafd4ab0e942779e9f58b1
# A repo that passes: every action pinned or local, and each transcript scrubbed before it is published.
repo() {
  mkdir -p .github/workflows .github/actions/setup factory/scripts
  cp "$scripts/scrub-tokens.sh" factory/scripts/
  printf 'cp "$file" "$clean" && "$(dirname "$0")/scrub-tokens.sh" "$clean"\n' > factory/scripts/save-session.sh
  cat > .github/workflows/ci.yml <<EOF
permissions:
  statuses: read
jobs:
  checks:
    steps:
      - uses: actions/checkout@$pin # v4
      - uses: ./.github/actions/setup
      - run: factory/scripts/scrub-tokens.sh "\$RUNNER_TEMP/reviews"
      - uses: actions/upload-artifact@$pin # v4
        with:
          name: session-review-\${{ github.run_id }}
EOF
  printf 'runs:\n  steps:\n    - uses: "pnpm/action-setup@%s" # v4\n' "$pin" > .github/actions/setup/action.yml
  git init --quiet --bare "$T/remote.git"
  git init --quiet --initial-branch main && git remote add origin "$T/remote.git"
  git add -A && TZ=UTC0 GIT_COMMITTER_DATE=2026-11-22T12:00:00Z git commit --quiet -m scrub
}
token="sk-ant-$(printf 'a%.0s' {1..30})"
# sessions <text>...: the sessions branch on GitHub, a commit for each text, the last one's file left in its tree.
sessions() {
  local text
  git init --quiet --initial-branch sessions "$T/seed"
  for text in "$@"; do
    printf '%s\n' "$text" > "$T/seed/pr-7.json"
    git -C "$T/seed" add -A && git -C "$T/seed" commit --quiet -m session
  done
  git -C "$T/seed" push --quiet "$T/remote.git" sessions
}
# artifact <name> <commit> [expired]: one of the repository's artifacts, as GitHub lists it, made by a run on that commit.
artifact() { echo "{\"name\":\"$1\",\"workflow_run\":{\"head_sha\":\"$2\"},\"expired\":${3:-false}}"; }
# $T/s holds each setting as GitHub has it; $T/fail holds words of the call to fail, $T/ignore those GitHub accepts and drops.
# With $T/reads-fail-after-write, every read after the first change fails.
github() {
  mkdir -p "$T/s"
  echo private > "$T/s/visibility"; echo disabled > "$T/s/scanning"; echo disabled > "$T/s/protection"
  echo first_time_contributors > "$T/s/approval"; echo false > "$T/s/reporting"; echo false > "$T/s/pinning"
  echo selected > "$T/s/allowed"
  echo none > "$T/fail"; echo none > "$T/ignore"; echo '[]' > "$T/artifacts"
  stub gh '
    if grep -qF -- "$(cat "$T/fail")" <<<"$*"; then echo "gh: HTTP 403" >&2; exit 1; fi
    case "$*" in
      *" -X "*) touch "$T/written" ;;
      *) if [ -e "$T/written" ] && [ -e "$T/reads-fail-after-write" ]; then echo "gh: HTTP 502" >&2; exit 1; fi ;;
    esac
    s() { cat "$T/s/$1"; }
    put() { grep -qF -- "$(cat "$T/ignore")" <<<"$*" || echo "$2" > "$T/s/$1"; }
    case "$*" in
      "api repos/{owner}/{repo}/actions/artifacts?per_page=100 --paginate --jq "*)
        json "{\"artifacts\":$(cat "$T/artifacts")}" "$@" ;;
      "api repos/{owner}/{repo}/compare/"*)
        range=${2#repos/\{owner\}/\{repo\}/compare/}
        if [ "${range%...*}" = "${range#*...}" ]; then status=identical
        elif git merge-base --is-ancestor "${range%...*}" "${range#*...}"; then status=ahead
        else status=diverged; fi
        json "{\"status\":\"$status\"}" "$@" ;;
      "api repos/{owner}/{repo} --jq "*)
        json "{\"visibility\":\"$(s visibility)\",\"security_and_analysis\":{\"secret_scanning\":{\"status\":\"$(s scanning)\"},
          \"secret_scanning_push_protection\":{\"status\":\"$(s protection)\"}}}" "$@" ;;
      "api repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval --jq "*)
        json "{\"approval_policy\":\"$(s approval)\"}" "$@" ;;
      "api repos/{owner}/{repo}/private-vulnerability-reporting --jq "*) json "{\"enabled\":$(s reporting)}" "$@" ;;
      "api repos/{owner}/{repo}/actions/permissions --jq "*)
        json "{\"enabled\":true,\"allowed_actions\":\"$(s allowed)\",\"sha_pinning_required\":$(s pinning)}" "$@" ;;
      "api -X PATCH repos/{owner}/{repo} -f visibility=public") put visibility public ;;
      "api -X PATCH repos/{owner}/{repo} --input -")
        input=$(cat); printf "%s\n" "$input" >> "$T/calls"
        case "$input" in
          *secret_scanning_push_protection*enabled*) put protection enabled "$* push" ;;
          *secret_scanning*enabled*) put scanning enabled "$* scanning" ;;
          *) exit 1 ;;
        esac ;;
      "api -X PUT repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors")
        put approval all_external_contributors "$*" ;;
      "api -X PUT repos/{owner}/{repo}/private-vulnerability-reporting") put reporting true "$*" ;;
      "api -X PUT repos/{owner}/{repo}/actions/permissions -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true")
        put pinning true "$*" ;;
      *) echo "unexpected call: gh $*" >&2; exit 1 ;;
    esac'
}

scenario "a repo that passes is made public, and each setting is set, then read back and printed"
repo; github
run "$scripts/publicize-repo.sh"
expect_status 0
expect_call "gh api -X PATCH repos/{owner}/{repo} -f visibility=public"
expect_call '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'
expect_call '{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}'
expect_call "fork-pr-contributor-approval -f approval_policy=all_external_contributors"
expect_call "gh api -X PUT repos/{owner}/{repo}/private-vulnerability-reporting"
expect_call "-F enabled=true -f allowed_actions=selected -F sha_pinning_required=true"
expect_output "visibility: public"
expect_output "secret scanning: enabled"
expect_output "push protection: enabled"
expect_output "approval before an outside contributor's workflow run: all_external_contributors"
expect_output "private vulnerability reporting: true"
expect_output "every action pinned to a commit: true"
expect_output "the repository is public and protected: 6 settings changed"
[ "$(grep -n -m1 'visibility=public' "$T/calls" | cut -d: -f1)" -lt "$(grep -n -m1 '"secret_scanning":{"status"' "$T/calls" | cut -d: -f1)" ] \
  || fail "expected the visibility to be set before secret scanning, which GitHub gives a public repository for free"

scenario "a re-run sets only the settings that differ"
repo; github
echo public > "$T/s/visibility"; echo enabled > "$T/s/scanning"; echo true > "$T/s/reporting"
run "$scripts/publicize-repo.sh"
expect_status 0
expect_no_call "visibility=public"
expect_no_call '"secret_scanning":{'
expect_no_call "-X PUT repos/{owner}/{repo}/private-vulnerability-reporting"
expect_call "secret_scanning_push_protection"
expect_call "approval_policy=all_external_contributors"
expect_call "sha_pinning_required=true"
expect_output "3 settings changed"

scenario "a repo with an unpinned third-party action is refused, and nothing is asked of GitHub"
repo; github
printf '      - uses: anthropics/claude-code-action@v1\n' >> .github/workflows/ci.yml
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "The repository was left as it is."
expect_output ".github/workflows/ci.yml:12: anthropics/claude-code-action@v1"
expect_no_call " -X "

scenario "an action of GitHub's own on a tag is refused too, as GitHub's pinning rule would fail its runs"
repo; github
printf 'runs:\n  steps:\n    - uses: actions/setup-node@v4\n' > .github/actions/setup/action.yml
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output ".github/actions/setup/action.yml:3: actions/setup-node@v4"
expect_output "fails a run of one on a tag"
expect_no_call " -X "

scenario "a workflow that uploads a transcript without the token scrub is refused"
repo; github
printf 'jobs:\n  agent:\n    steps:\n      - uses: actions/upload-artifact@%s\n        with:\n          name: session-claude-1\n' "$pin" \
  > .github/workflows/claude.yml
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output ".github/workflows/claude.yml uploads a transcript without running scrub-tokens.sh"
expect_no_output "ci.yml uploads"
expect_no_call " -X "

scenario "a save-session.sh that pushes a transcript without the token scrub is refused"
repo; github
printf 'git push origin sessions\n' > factory/scripts/save-session.sh
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "save-session.sh pushes a transcript without running scrub-tokens.sh"
expect_no_call " -X "

scenario "a repo without scrub-tokens.sh is refused"
repo; github
rm factory/scripts/scrub-tokens.sh
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "factory/scripts/scrub-tokens.sh is missing"
expect_no_call " -X "

scenario "the settings cannot be read: it stops before changing any"
repo; github
echo "private-vulnerability-reporting --jq" > "$T/fail"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "The repository was left as it is: its settings could not be read from GitHub."
expect_no_call "-X PATCH"
expect_no_call "-X PUT"

scenario "GitHub refuses one setting: it stops there, says which, and sets none after it"
repo; github
echo "fork-pr-contributor-approval -f" > "$T/fail"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "GitHub refused to set approval before an outside contributor's workflow run"
expect_call "visibility=public"
expect_no_call "-X PUT repos/{owner}/{repo}/private-vulnerability-reporting"
expect_no_call "sha_pinning_required=true"
expect_no_output "public and protected"

scenario "GitHub accepts a setting but it reads back otherwise: it says so and fails"
repo; github
echo "push" > "$T/ignore"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "push protection: disabled"
expect_output "expected enabled"
expect_output "a setting above reads back otherwise"
expect_no_output "public and protected"

scenario "the settings cannot be read back: it says what was changed and to run it again"
repo; github
touch "$T/reads-fail-after-write"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "6 settings were changed, but they could not be read back from GitHub: run this again to check them."

scenario "a token in the sessions branch's history is refused, though a later commit removed it"
repo; github
sessions "{\"text\":\"$token\"}" '{"text":"clean"}' '{"text":"later"}'
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "the sessions branch holds a token in its history"
expect_output "revoke each token"
expect_no_call " -X "

scenario "a sessions branch with no token passes"
repo; github
sessions '{"text":"sk-ant- is a prefix"}'
run "$scripts/publicize-repo.sh"
expect_status 0
expect_output "the repository is public and protected"

scenario "a transcript artifact made by a run on a commit before the scrub is refused, whenever it was uploaded"
repo; github
scrub=$(git rev-parse HEAD)
before=$(git commit-tree -m before "$scrub^{tree}")
git commit --quiet --allow-empty -m later
echo "[$(artifact session-esme-1 "$before"),$(artifact session-esme-2 "$scrub"),$(artifact session-esme-3 "$(git rev-parse HEAD)"),\
$(artifact session-esme-4 "$before" true),$(artifact session-esme-5 "$before"),$(artifact tested-with-main-abc "$before")]" > "$T/artifacts"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "artifact session-esme-1 was made by a run of workflows from before they scrubbed tokens"
expect_output "artifact session-esme-5 was made by a run of workflows from before they scrubbed tokens"
expect_no_output "session-esme-2"
expect_no_output "session-esme-3"
expect_no_output "session-esme-4"
expect_no_output "tested-with-main"
expect_no_call " -X "

scenario "whether an artifact's run scrubbed tokens cannot be read: it stops before changing anything"
repo; github
echo "[$(artifact session-esme-1 "$(git rev-parse HEAD)")]" > "$T/artifacts"
echo "/compare/" > "$T/fail"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "whether the run that made artifact session-esme-1 scrubbed tokens could not be read"
expect_no_call " -X "

scenario "the artifacts cannot be read: it stops before changing anything"
repo; github
echo "actions/artifacts" > "$T/fail"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "its artifacts could not be read from GitHub"
expect_no_call " -X "

scenario "whether there is a sessions branch cannot be read: it stops before changing anything"
repo; github
git remote set-url origin "$T/nowhere.git"
run "$scripts/publicize-repo.sh"
expect_status 1
expect_output "whether it has a sessions branch could not be read"
expect_no_call "gh api"
