#!/usr/bin/env bash
# Tests for allow-skill-write.sh: a session may write only a skill file its ticket names or its pull request changes.
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

# A build's new branch, which changes no file, and the text of its ticket as thread.sh printed it.
a_build() {
  a_fix_round
  git checkout -q -b docs/14-name-the-read origin/main
  cat > "$T/ticket-text.txt" <<'TEXT'
# Ticket #14: Name the read in the review skill

Opened by github-actions[bot], 2026-11-20T15:43:17Z. State: open. Labels: factory.

Apply each note. Leave `.claude/settings.json` and .claude/skills/implement/../../settings.json alone.

===== comment by github-actions[bot], 2026-11-20T16:00:00Z =====
1. `.claude/skills/implement/SKILL.md:33`: This line names a read that fails.
   Fix: Name the other read, and say so in .claude/skills/operate/SKILL.md.
TEXT
}

# asked_in_build <tool> <path>: the script answers the request, given the ticket's text as implement.yml gives it.
asked_in_build() {
  jq -nc --arg tool "$1" --arg path "$2" '{hook_event_name: "PermissionRequest", tool_name: $tool, tool_input: {file_path: $path}}' > "$T/request"
  run "$scripts/allow-skill-write.sh" "$T/ticket-text.txt" < "$T/request"
}

scenario "in a build, allows an edit to a skill file the ticket names, on a branch that changes nothing"
a_build
asked_in_build Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 0
[ "$out" = "$allow" ] || fail "expected the decision that allows the write"

scenario "in a build, allows writing a skill file the ticket names at the end of a sentence, which does not exist yet"
a_build
asked_in_build Write "$PWD/.claude/skills/operate/SKILL.md"
expect_status 0
[ "$out" = "$allow" ] || fail "expected the decision that allows the write"

scenario "in a build, leaves refused a skill file the ticket does not name"
a_build
asked_in_build Edit "$PWD/.claude/skills/retro/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, leaves refused a file whose path only begins a path the ticket names"
a_build
asked_in_build Write "$PWD/.claude/skills/implement/SKILL"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, leaves refused a file under .claude that is no skill, though the ticket names it"
a_build
asked_in_build Edit "$PWD/.claude/settings.json"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, leaves refused a path the ticket names that climbs out of the skills"
a_build
asked_in_build Write "$PWD/.claude/skills/implement/../../settings.json"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, leaves refused a skill file of the same name in another checkout"
a_build
asked_in_build Edit "$T/elsewhere/.claude/skills/implement/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, allows nothing when the ticket names no skill file"
a_build
echo "# Ticket #14: Fix the scripts" > "$T/ticket-text.txt"
asked_in_build Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"

scenario "in a build, stops with a message, allowing nothing, when the ticket's text was not kept"
a_build
rm "$T/ticket-text.txt"
asked_in_build Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 1
grep -q "Could not read the ticket's text" <<<"$out" || fail "expected it to say what it could not read"
! grep -q '"allow"' <<<"$out" || fail "expected no decision"

scenario "in a build, leaves refused a skill file the branch already changes and the ticket does not name"
a_build
git checkout -q docs/12-merge-main-once
echo "# Ticket #12: Fix the scripts" > "$T/ticket-text.txt"
asked_in_build Edit "$PWD/.claude/skills/implement/SKILL.md"
expect_status 0
[ -z "$out" ] || fail "expected no decision"
