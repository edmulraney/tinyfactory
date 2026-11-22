#!/usr/bin/env bash
# Tests for stale-documents.sh: the lines of documents that name what a pull request changes or removes.
. "$(dirname "$0")/helpers.sh"

# a_project: main holds two scripts, a label list, a package.json and documents that name them; `change` branches from it.
a_project() {
  git init -q -b main .
  mkdir -p factory/scripts factory/decisions .claude/skills/bootstrap/scripts .claude/skills/ticket .claude/skills/promote docs
  echo "echo checks" > factory/scripts/check-ticket.sh
  echo "echo reviews" > factory/scripts/owner-review.sh
  echo "a skill" > .claude/skills/ticket/SKILL.md
  echo "a skill" > .claude/skills/promote/SKILL.md
  printf '%s\n' 'gh label create ready -R "$repo" --force --color 0E8A16 --description "Approved"' \
    'gh label create proof -R "$repo" --force --color FEF2C0 --description "To confirm"' > .claude/skills/bootstrap/scripts/labels.sh
  echo '{"scripts":{"test":"vitest","test:e2e":"playwright test","lint":"eslint"}}' > package.json
  printf '%s\n' "# Guide" "" "Run \`factory/scripts/check-ticket.sh\` on a ticket." "A ticket that passes check-ticket.sh. is started." \
    "The owner reads \`owner-review.sh\`." "See also not-check-ticket.sh and check-ticket.sh.bak." > docs/guide.md
  printf '%s\n' "The \`proof\` label marks a check." "A proof of work is no label." "Add \`ready\` to start it." \
    "Run \`pnpm test\` first." "Run \`pnpm test:e2e\` last." "Run \`pnpm lint\`." "The ticket skill is \`.claude/skills/ticket/SKILL.md\`." \
    "Every skill is a SKILL.md file." "Its seed is \`templates/.claude/skills/ticket/SKILL.md\`." > README.md
  echo "| H1 | \`check-ticket.sh\` checks a title. | It was wrong once. | Nothing. | #1 |" > factory/decisions/1.md
  echo "The format of a row; \`check-ticket.sh\` reads it." > factory/decisions.md
  git add . && git commit -q -m "start"
  git checkout -q -b change
}
commit() { git add -A . && git commit -q -m "${1:-a change}"; }
list() { run "$scripts/stale-documents.sh" "${1:-main}" "${2:-change}"; }
expect_lines() {
  [ "$out" = "$1" ] || fail "expected exactly these lines:
$1"
}

scenario "a pull request that renames a script yields each document line that names it, by its path or its name alone"
a_project
git mv factory/scripts/check-ticket.sh factory/scripts/check-title.sh
commit
list
expect_status 0
expect_lines "docs/guide.md:3: Run \`factory/scripts/check-ticket.sh\` on a ticket.
docs/guide.md:4: A ticket that passes check-ticket.sh. is started."

scenario "a pull request that changes nothing a document names yields none"
a_project
echo "echo reads" > factory/scripts/thread.sh
echo "A new document that names factory/scripts/thread.sh." > docs/new.md
commit
list
expect_status 0
expect_lines ""

scenario "a changed script is listed as a removed one is, and a line the pull request corrected is listed as it now reads"
a_project
echo "echo checks more" > factory/scripts/check-ticket.sh
sed 's/^A ticket that passes check-ticket.sh. is started.$/A ticket that check-ticket.sh passes waits./' docs/guide.md > guide.new && mv guide.new docs/guide.md
commit
list
expect_status 0
expect_lines "docs/guide.md:3: Run \`factory/scripts/check-ticket.sh\` on a ticket.
docs/guide.md:4: A ticket that check-ticket.sh passes waits."

scenario "a file whose name other files share is named only by its path"
a_project
echo "a changed skill" > .claude/skills/ticket/SKILL.md
commit
list
expect_status 0
expect_lines "README.md:7: The ticket skill is \`.claude/skills/ticket/SKILL.md\`."

scenario "a label taken from the label list yields the lines that name it in backticks, and no other label's"
a_project
grep -v 'label create proof' .claude/skills/bootstrap/scripts/labels.sh > labels.new && mv labels.new .claude/skills/bootstrap/scripts/labels.sh
commit
list
expect_status 0
expect_lines "README.md:1: The \`proof\` label marks a check."

scenario "a changed or removed script of package.json yields the lines that name its pnpm command, and not a longer command's"
a_project
echo '{"scripts":{"test":"vitest run","test:e2e":"playwright test"}}' > package.json
commit
list
expect_status 0
expect_lines "README.md:4: Run \`pnpm test\` first.
README.md:6: Run \`pnpm lint\`."

scenario "a removed package.json yields the lines that name each of its commands"
a_project
git rm -q package.json
commit
list
expect_status 0
expect_lines "README.md:4: Run \`pnpm test\` first.
README.md:5: Run \`pnpm test:e2e\` last.
README.md:6: Run \`pnpm lint\`."

scenario "what main changed after the branch left it is not the pull request's"
a_project
echo "echo reads" > factory/scripts/thread.sh
commit
git checkout -q main
echo "echo checks more" > factory/scripts/check-ticket.sh
commit "main moves on"
list
expect_status 0
expect_lines ""

scenario "a commit the checkout does not hold: fails with a message and no list"
a_project
list main 0123456789012345678901234567890123456789
expect_status 1
expect_lines "stale-documents.sh: the commit 0123456789012345678901234567890123456789 is not in this checkout, so the documents that name what changed are not listed."

scenario "two commits that share no history: fails with a message and no list"
a_project
git checkout -q --orphan other
commit "another start"
list main other
expect_status 1
expect_output "stale-documents.sh: main and "
expect_output "share no commit in this checkout, so the documents that name what changed are not listed."

scenario "a package.json that is not JSON: fails with a message and no list"
a_project
echo "echo checks more" > factory/scripts/check-ticket.sh
echo '{"scripts":' > package.json
commit
list
expect_status 1
[ "$(grep -c 'docs/guide.md' <<<"$out")" = 0 ] || fail "expected no line of a document beside the failure"
expect_output "stale-documents.sh: the scripts of package.json could not be read as JSON, so the documents that name what changed are not listed."

scenario "git cannot search the documents: fails with a message and no list"
a_project
echo "echo checks more" > factory/scripts/check-ticket.sh
commit
real_git=$(command -v git); export real_git
stub git 'case " $* " in *" grep "*) echo "fatal: unable to read tree" >&2; exit 128 ;; esac; exec "$real_git" "$@"'
list
expect_status 1
expect_output "stale-documents.sh: the documents of "
expect_output "could not be searched, so the documents that name what changed are not listed."

scenario "no base or no head: says how it is used"
a_project
run "$scripts/stale-documents.sh" main
[ "$status" != 0 ] || fail "expected it to stop"
expect_output "Usage: stale-documents.sh <base> <head>"
