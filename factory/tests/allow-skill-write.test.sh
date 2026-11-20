#!/usr/bin/env bash
# Tests for allow-skill-write.sh: a fix round's session may write only a skill file its pull request already changes.
. "$(dirname "$0")/helpers.sh"

allow='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# A pull request's branch, checked out, that changes one skill and the session's settings; main holds two skills.
a_fix_round() {
  git init -q --bare -b main "$T/github.git"
  git init -q -b main "$T/seed"
  mkdir -p "$T/seed/.claude/skills/implement" "$T/seed/.claude/skills/retro"
  echo "# Implement" > "$T/seed/.claude/skills/implement/SKILL.md"
  echo "# Retro" > "$T/seed/.claude/skills/retro/SKILL.md"
  echo "{}" > "$T/seed/.claude/settings.json"
  git -C "$T/seed" add -A
  git -C "$T/seed" commit -q -m "chore: start"
  git -C "$T/seed" push -q "$T/github.git" main
  git clone -q "$T/github.git" .
  git checkout -q -b docs/12-merge-main-once
  echo "Merge main once." >> .claude/skills/implement/SKILL.md
  echo '{"env":{}}' > .claude/settings.json
  git commit -q -am "docs: merge main once"
}

# asked <tool> <path>: the script answers the request Claude Code makes before that write.
asked() {
  jq -nc --arg tool "$1" --arg path "$2" '{hook_event_name: "PermissionRequest", tool_name: $tool, tool_input: {file_path: $path}}' > "$T/request"
  run "$scripts/allow-skill-write.sh" < "$T/request"
}

scenario "allows an edit to a skill file the pull request already changes"
a_fix_round
asked Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 0
[ "$out" = "$allow" ] || fail "expected the decision that allows the write"

scenario "still allows it once main has moved on and the round has committed"
a_fix_round
git -C "$T/seed" commit -q --allow-empty -m "chore: main moves"
git -C "$T/seed" push -q "$T/github.git" main
git fetch -q origin
git commit -q --allow-empty -m "fix: a first fix"
asked Write "$PWD/.claude/skills/implement/SKILL.md"
expect_status 0
[ "$out" = "$allow" ] || fail "expected the decision that allows the write"

scenario "allows it when the session has moved into a subdirectory"
a_fix_round
file="$PWD/.claude/skills/implement/SKILL.md"
cd .claude/skills/retro || exit 1
asked Edit "$file"
expect_status 0
[ "$out" = "$allow" ] || fail "expected the decision that allows the write"

scenario "leaves refused a skill file the pull request does not change"
a_fix_round
asked Edit "$PWD/.claude/skills/retro/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "leaves refused a skill file that main changed and the pull request did not"
a_fix_round
echo "Changed on main." >> "$T/seed/.claude/skills/retro/SKILL.md"
git -C "$T/seed" commit -q -am "docs: change the retro"
git -C "$T/seed" push -q "$T/github.git" main
git fetch -q origin
asked Edit "$PWD/.claude/skills/retro/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "leaves refused a file under .claude that is no skill, though the pull request changes it"
a_fix_round
asked Edit "$PWD/.claude/settings.json"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "leaves refused a path that climbs out of a changed skill's folder"
a_fix_round
asked Write "$PWD/.claude/skills/implement/../../settings.json"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "leaves refused a skill file of the same name in another checkout"
a_fix_round
asked Edit "$T/elsewhere/.claude/skills/implement/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "stops with a message, allowing nothing, when git cannot say what the pull request changes"
a_fix_round
git update-ref -d refs/remotes/origin/main
asked Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 1
grep -q "Could not read from git which skill files this pull request changes" <<<"$out" || fail "expected it to say what it could not read"
! grep -q '"allow"' <<<"$out" || fail "expected no decision"

scenario "stops with a message, allowing nothing, when the request is not JSON"
a_fix_round
echo "not json" > "$T/request"
run "$scripts/allow-skill-write.sh" < "$T/request"
expect_status 1
grep -q "Could not read the permission request" <<<"$out" || fail "expected it to say what it could not read"
! grep -q '"allow"' <<<"$out" || fail "expected no decision"
