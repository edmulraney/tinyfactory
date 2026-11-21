#!/usr/bin/env bash
# Tests for factory/scripts/check-citations.sh: a citation in a Markdown file is a link to its file (decisions H531a).
. "$(dirname "$0")/helpers.sh"

# repo: a git repo holding two decision records and a free-tier log, with nothing committed.
repo() {
  git init --quiet --initial-branch=main .
  mkdir -p factory/decisions factory/free-tier product/decisions .claude/skills/ticket
  printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
    '| M9 | The factory stores no token. | It could leak. | Storing one: it could leak. | setup |' > factory/decisions/setup.md
  printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
    '| A62a | An agent asks nothing. | Nobody is watching. | Asking: nobody answers. | #62 |' > factory/decisions/62.md
  printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
    '| D7 | The forecast is one number. | A range reads as doubt. | A range: as above. | #7 |' > product/decisions/7.md
  printf '### 8. Free the branch\n\n- **Automated:** yes.\n' > factory/free-tier/entry-8.md
  printf '### #62a. Skip the job\n\n- **Automated:** yes.\n' > factory/free-tier/62.md
}
check() { run "$scripts/check-citations.sh" "$@"; }

scenario "passes citations that are links whose paths work from the file that cites them"
repo
echo 'No token (decisions [M9](factory/decisions/setup.md)); see [entry 8](factory/free-tier/entry-8.md).' > README.md
echo 'Ask nothing ([A62a](../../../factory/decisions/62.md), [D7](../../../product/decisions/7.md)).' > .claude/skills/ticket/SKILL.md
echo 'It is skipped ([entry #62a](62.md)).' > factory/free-tier/entry-9.md
check
expect_status 0
expect_output "citations ok: 5 links in 8 Markdown files"

scenario "fails a cited decision that is no link, naming the file, the line and the link to write"
repo
printf 'A title.\n\nNo token (decisions M9).\n' > README.md
check
expect_status 1
expect_output 'README.md:3: "M9" is not a link: write [M9](factory/decisions/setup.md)'
expect_output "check-citations.sh --fix"
expect_output "goes in a code span"
expect_no_output "citations ok"

scenario "fails a cited free-tier entry that is no link, numbered in order or named after its ticket"
repo
mkdir -p factory/README
printf 'One slot (entry 8).\nSkipped (free-tier entry #62a). Entry 8 frees it.\n' > factory/README/gaps.md
check
expect_status 1
expect_output 'factory/README/gaps.md:1: "entry 8" is not a link: write [entry 8](../free-tier/entry-8.md)'
expect_output 'factory/README/gaps.md:2: "entry #62a" is not a link: write [entry #62a](../free-tier/62.md)'
expect_output 'factory/README/gaps.md:2: "Entry 8" is not a link: write [Entry 8](../free-tier/entry-8.md)'

scenario "fails a link that names another file than the one that holds the row or entry"
repo
echo 'No token ([M9](factory/decisions/62.md)); see [entry 8](free-tier/entry-8.md).' > README.md
check
expect_status 1
expect_output 'README.md:1: the link of "M9" names factory/decisions/62.md, and from this file the file that holds it is factory/decisions/setup.md'
expect_output 'README.md:1: the link of "entry 8" names free-tier/entry-8.md, and from this file the file that holds it is factory/free-tier/entry-8.md'

scenario "with --fix, writes each missing link and corrects each wrong one, and the check then passes"
repo
echo 'No token (decisions M9, A62a; entry 8), nor [M9](wrong.md).' > README.md
echo 'Ask nothing (A62a to D7), as entry #62 has it.' > .claude/skills/ticket/SKILL.md
check --fix
expect_status 0
expect_output "check-citations.sh linked 7 citations in 2 files"
[ "$(cat README.md)" = 'No token (decisions [M9](factory/decisions/setup.md), [A62a](factory/decisions/62.md); [entry 8](factory/free-tier/entry-8.md)), nor [M9](factory/decisions/setup.md).' ] \
  || fail "README.md was left as: $(cat README.md)"
[ "$(cat .claude/skills/ticket/SKILL.md)" = 'Ask nothing ([A62a](../../../factory/decisions/62.md) to [D7](../../../product/decisions/7.md)), as [entry #62](../../../factory/free-tier/62.md) has it.' ] \
  || fail "the skill was left as: $(cat .claude/skills/ticket/SKILL.md)"
check
expect_status 0
expect_output "citations ok: 7 links in 7 Markdown files"

scenario "links a row's citation of another row, and leaves the ID a row defines"
repo
printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
  '| M70 | A token is read when needed. | M9 stores none. | Storing one: M9. | #70 |' > factory/decisions/70.md
check --fix
expect_status 0
[ "$(sed -n 3p factory/decisions/70.md)" = '| M70 | A token is read when needed. | [M9](setup.md) stores none. | Storing one: [M9](setup.md). | #70 |' ] \
  || fail "the row was left as: $(sed -n 3p factory/decisions/70.md)"
[ "$(sed -n 3p factory/decisions/setup.md)" = '| M9 | The factory stores no token. | It could leak. | Storing one: it could leak. | setup |' ] \
  || fail "the row that defines M9 was changed: $(sed -n 3p factory/decisions/setup.md)"

scenario "leaves code, other links, and words that only look like a citation"
repo
cat > README.md <<'EOF'
An ID is written `M9`, or ``a `M9` in two``, and `entry 8` is an entry.
```
decisions M9, entry 8
```
~~~
M9
~~~
Stored in S3, on an M1, at entry 3 or entry #5; see XM9, M9x, a/M9, M9-b and re-entry 8.
A [guide to M9](guide.md), a [D7 chart](https://example.com/M9), and [S3](s3.md).
A picture ![M9](shot.png), a reference [M9][ref], an address https://example.com/?id=M9, and the chip `M9`.
EOF
cp README.md before.txt
check
expect_status 0
check --fix
expect_status 0
expect_no_output "linked"
cmp -s README.md before.txt || fail "README.md was changed: $(cat README.md)"

scenario "links a seed from the place scaffold.sh copies it to"
repo
mkdir -p .claude/skills/bootstrap/templates/product
echo 'Sign-in (A62a).' > .claude/skills/bootstrap/templates/ARCHITECTURE.md
echo 'One number (D7).' > .claude/skills/bootstrap/templates/product/README.md
check --fix
expect_status 0
[ "$(cat .claude/skills/bootstrap/templates/ARCHITECTURE.md)" = 'Sign-in ([A62a](factory/decisions/62.md)).' ] \
  || fail "the seed was left as: $(cat .claude/skills/bootstrap/templates/ARCHITECTURE.md)"
[ "$(cat .claude/skills/bootstrap/templates/product/README.md)" = 'One number ([D7](decisions/7.md)).' ] \
  || fail "the product seed was left as: $(cat .claude/skills/bootstrap/templates/product/README.md)"

scenario "refuses an ID that both records hold, which a citation could not tell apart"
repo
printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
  '| M9 | The product stores no token. | It could leak. | Storing one: it could leak. | #9 |' > product/decisions/9.md
check
expect_status 1
expect_output "product/decisions/9.md:3: M9 is also a row in factory/decisions/setup.md"
expect_no_output "citations ok"

scenario "links a row of the architecture record, and refuses its ID in the product record too"
repo
mkdir -p architecture/decisions
printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
  '| D8 | The forecast is not stored. | It serves D7. | Storing it: nothing reads it. | #8 |' > architecture/decisions/8.md
echo 'Nothing is stored (D8).' > README.md
check --fix
expect_status 0
[ "$(cat README.md)" = 'Nothing is stored ([D8](architecture/decisions/8.md)).' ] || fail "README.md was left as: $(cat README.md)"
[ "$(sed -n 3p architecture/decisions/8.md)" = '| D8 | The forecast is not stored. | It serves [D7](../../product/decisions/7.md). | Storing it: nothing reads it. | #8 |' ] \
  || fail "the row was left as: $(sed -n 3p architecture/decisions/8.md)"
printf '%s\n' '| ID | Decision | Why | Rejected | Source |' '|---|---|---|---|---|' \
  '| D8 | The forecast is a table. | It reads well. | A chart: none exists. | #8 |' > product/decisions/8.md
check
expect_status 1
expect_output "product/decisions/8.md:3: D8 is also a row in architecture/decisions/8.md"
expect_no_output "citations ok"

scenario "keeps Windows line endings, and reads a file with them"
repo
printf 'No token (M9).\r\nNothing here.\r\n' > README.md
check
expect_status 1
expect_output 'README.md:1: "M9" is not a link'
check --fix
expect_status 0
[ "$(od -c README.md | tr -s ' ' | tr -d '\n')" = "$(printf 'No token ([M9](factory/decisions/setup.md)).\r\nNothing here.\r\n' | od -c | tr -s ' ' | tr -d '\n')" ] \
  || fail "README.md was left as: $(od -c README.md)"

scenario "checks a file not yet added, passes over one deleted, and a project with no record"
repo
git add . && git commit --quiet -m rows
echo 'No token (M9).' > NEW.md
check
expect_status 1
expect_output 'NEW.md:1: "M9" is not a link'
rm NEW.md
echo 'No token (M9).' > OLD.md
git add OLD.md && git commit --quiet -m old
rm OLD.md
check
expect_status 0
expect_output "citations ok: 0 links in 5 Markdown files"
git rm --quiet -r factory product
echo 'An M1 and entry 8.' > README.md
check
expect_status 0
expect_output "citations ok: 0 links in 1 Markdown files"

scenario "fails with a message outside a git repository, and when a file cannot be written"
echo 'No token (M9).' > README.md
stub git 'exit 128'
check
expect_status 1
expect_output "must be run inside a git repository"
expect_no_output "citations ok"
rm "$T/bin/git"
repo
echo 'No token (M9).' > README.md
chmod a-w README.md
if [ -w README.md ]; then
  # Root writes any file, so the failed write cannot be staged.
  :
else
  check --fix
  expect_failure
  expect_no_output "citations ok"
fi
chmod u+w README.md

scenario "passes a repo that holds no Markdown file"
git init --quiet --initial-branch=main .
check
expect_status 0
expect_output "citations ok: 0 links in 0 Markdown files"

scenario "with --fix, writes a file in conflict once, which git lists three times"
repo
echo 'First.' > README.md
git add . && git commit --quiet -m first
git checkout --quiet -b other
echo 'Theirs.' > README.md
git commit --quiet -am theirs
git checkout --quiet main
echo 'Ours.' > README.md
git commit --quiet -am ours
git merge --quiet other > /dev/null 2>&1
printf 'No token (M9), as the far longer line this file held before it was settled never said.\nNor A62a.\n' > README.md
check --fix
expect_status 0
expect_output "check-citations.sh linked 2 citations in 1 files"
expect_output "citations ok: 2 links in 6 Markdown files"
[ "$(cat README.md)" = 'No token ([M9](factory/decisions/setup.md)), as the far longer line this file held before it was settled never said.
Nor [A62a](factory/decisions/62.md).' ] || fail "README.md was left as: $(cat README.md)"
