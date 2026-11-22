#!/usr/bin/env bash
# Tests for test-factory.sh: each scenario makes a repo with test files of its own, so the runner never runs itself.
. "$(dirname "$0")/helpers.sh"

# repo_with <file> <bash>...: a repo whose factory/tests/ holds these files.
repo_with() {
  git init -q -b main .
  mkdir -p factory/tests factory/scripts
  while [ $# -gt 0 ]; do
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "factory/tests/$1"
    shift 2
  done
  git add .
}

scenario "passes and prints how many tests ran, in how many files"
repo_with one.test.sh 'echo "ok - first"; echo "ok - second"' two.test.sh 'echo "ok - third"'
run "$scripts/test-factory.sh"
expect_status 0
expect_output "factory tests ok: 3 passed in 2 files"

scenario "fails on a failing test, naming its file and the test, and still runs the other files"
repo_with one.test.sh 'echo "ok - first"; echo "not ok - lets TASTE.md through"; echo "    expected exit 1, got 0"; exit 1' \
  two.test.sh 'echo "not ok - another"; exit 1'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/one.test.sh: lets TASTE.md through"
expect_output "    expected exit 1, got 0"
expect_output "FAILED factory/tests/two.test.sh: another"
expect_no_output "factory tests ok"
expect_no_output "ok - first"

scenario "fails on a failing test even when its file exits 0"
repo_with one.test.sh 'echo "not ok - lets TASTE.md through"'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/one.test.sh: lets TASTE.md through"

scenario "fails on a test file that stopped before finishing: its tests did not pass"
repo_with one.test.sh 'echo "ok - first"; echo "no such command" >&2; exit 127'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/one.test.sh: it stopped with exit 127 before finishing"
expect_output "no such command"
expect_no_output "factory tests ok"

scenario "fails on a test file that ran no test"
repo_with one.test.sh 'exit 0'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/one.test.sh: it ran no test"

scenario "does not run a file in the folder that is not a test, such as the helper"
repo_with one.test.sh 'echo "ok - first"' helpers.sh 'echo "not ok - the helper was run as a test"'
run "$scripts/test-factory.sh"
expect_status 0
expect_output "factory tests ok: 1 passed in 1 files"

scenario "does not lint: a script that does not parse fails no test"
repo_with one.test.sh 'echo "ok - first"'
printf '#!/usr/bin/env bash\nif true; then\n' > factory/scripts/broken.sh
git add .
run "$scripts/test-factory.sh"
expect_status 0
expect_output "factory tests ok: 1 passed in 1 files"

scenario "stops with a message outside a git repository: that is not a folder with no test in it"
mkdir -p factory/tests
printf '#!/usr/bin/env bash\necho "ok - first"\n' > factory/tests/one.test.sh
# The ceiling keeps git from finding a repository above the scenario, wherever TMPDIR points.
run env GIT_CEILING_DIRECTORIES="$T" "$scripts/test-factory.sh"
expect_status 1
expect_output "test-factory.sh must be run inside a git repository"
expect_output "no test was run"
expect_no_output "factory tests ok"

scenario "runs the files at the same time: each of two waits for the other to have started"
# shellcheck disable=SC2016
meet='touch "$MEET/$1"; for _ in $(seq 100); do [ -e "$MEET/$2" ] && echo "ok - met" && exit 0; sleep 0.1; done; echo "not ok - the other file never started"'
repo_with one.test.sh "set -- one two; $meet" two.test.sh "set -- two one; $meet"
mkdir "$T/meet"
stub getconf 'echo 2'
MEET="$T/meet" run "$scripts/test-factory.sh"
expect_status 0
expect_output "factory tests ok: 2 passed in 2 files"

scenario "runs as many files at once as the machine has processors: with one, a file never sees another running"
# Marks itself before it looks, so files started together always see each other.
# shellcheck disable=SC2016
alone='touch "$MEET/$$"; sleep 0.3; [ "$(ls "$MEET")" = "$$" ] || echo "not ok - another file was running"; rm "$MEET/$$"; echo "ok - alone"'
repo_with one.test.sh "$alone" two.test.sh "$alone" three.test.sh "$alone"
mkdir "$T/meet"
stub getconf 'echo 1'
MEET="$T/meet" run "$scripts/test-factory.sh"
expect_status 0
expect_call "getconf _NPROCESSORS_ONLN"
expect_output "factory tests ok: 3 passed in 3 files"

scenario "prints each file's output whole, in the order the files are listed, whichever finishes first"
repo_with a.test.sh 'sleep 1; echo "not ok - slow"; echo "    slow detail"' b.test.sh 'echo "not ok - quick"; echo "    quick detail"'
stub getconf 'echo 2'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/a.test.sh: slow
    slow detail
FAILED factory/tests/b.test.sh: quick
    quick detail"

scenario "leaves nothing behind, passing or failing"
repo_with one.test.sh 'echo "ok - first"' two.test.sh 'echo "not ok - second"'
run "$scripts/test-factory.sh"
expect_status 1
[ -z "$(ls -A "$TMPDIR")" ] || fail "expected an empty temporary folder, found: $(ls -A "$TMPDIR")"

scenario "stops with a message when the processors cannot be counted"
repo_with one.test.sh 'echo "ok - first"'
stub getconf 'exit 1'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "could not read how many processors the machine has"
expect_no_output "factory tests ok"
[ -z "$(ls -A "$TMPDIR")" ] || fail "expected an empty temporary folder, found: $(ls -A "$TMPDIR")"

scenario "stops with a message when it cannot make a folder for the output"
repo_with one.test.sh 'echo "ok - first"'
stub mktemp 'exit 1'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "could not make a folder for the test files' output"
expect_no_output "factory tests ok"

scenario "stops with a message when the files cannot be run, and leaves nothing behind"
repo_with one.test.sh 'echo "ok - first"'
stub xargs 'exit 127'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "could not run the test files with xargs"
expect_no_output "factory tests ok"
[ -z "$(ls -A "$TMPDIR")" ] || fail "expected an empty temporary folder, found: $(ls -A "$TMPDIR")"

scenario "fails a file whose output was never written: its tests did not pass"
repo_with one.test.sh 'echo "ok - first"' two.test.sh 'echo "ok - second"'
# Runs only the first file, as an xargs that lost one would.
stub xargs 'read -r number file; shift 6; bash -c "$1" "$2" "$number" "$file"'
run "$scripts/test-factory.sh"
expect_status 1
expect_output "FAILED factory/tests/two.test.sh: test-factory.sh could not read what it printed"
expect_no_output "factory tests ok"

# changed <path>...: a repo of scripts and their test files, then a commit that changes these paths; $T/ran is
# where each test file that runs leaves its name, and `ran` prints those names on one line.
changed() {
  local script path
  git init -q -b main .
  mkdir -p factory/tests factory/scripts factory/workflows factory/decisions "$T/ran"
  echo "# the stand-ins" > factory/tests/helpers.sh
  echo "on: push" > factory/workflows/ci.yml
  echo "# Retro" > SKILL.md
  echo 'echo shipping' > factory/scripts/shipping.sh
  # shellcheck disable=SC2016
  {
    echo '. "$(dirname "$0")/shipping.sh"' > factory/scripts/ship.sh
    echo '  "$script_dir/ship.sh" "$pr"' > factory/scripts/approve-merge.sh
    echo '# Waits as ship.sh waits.' > factory/scripts/watch.sh
    echo 'echo again' > factory/scripts/re-ship.sh
    echo 'grep -q lesson "$root/SKILL.md"' > factory/scripts/retro-lesson.sh
    echo 'echo each file' > factory/scripts/test-factory.sh
    for script in shipping ship approve-merge watch re-ship retro-lesson test-factory; do
      printf '. "$(dirname "$0")/helpers.sh"\n: "$scripts/%s.sh"\ntouch "$RAN/%s"\necho "ok - %s"\n' "$script" "$script" "$script" \
        > "factory/tests/$script.test.sh"
    done
  }
  git add .
  git commit -q -m "main"
  for path in "$@"; do
    mkdir -p "$(dirname "$path")"
    echo "# changed" >> "$path"
  done
  git add .
  git commit -q --allow-empty -m "the change"
}
ran() { ls "$T/ran" | paste -sd ' ' -; }
expect_ran() {
  expect_status 0
  [ "$(ran)" = "$1" ] || fail "expected the test files of \"$1\" to run, and these ran: \"$(ran)\""
}

scenario "given main's commit, a change to a script nothing else runs starts its own test file alone"
changed factory/scripts/watch.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "watch"
expect_output "The change since HEAD^ can affect 1 of the 7 test files, and only those run."
expect_output "factory tests ok: 1 passed in 1 files"

scenario "a change to shipping.sh starts the test files of the script that sources it and of the script that runs that one"
changed factory/scripts/shipping.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge ship shipping"

scenario "a script is found by its whole name, outside comments: ship.sh is not re-ship.sh, and watch.sh only writes of it"
changed factory/scripts/ship.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge ship"

scenario "a changed script starts the test file named after it, also when that file does not name the script"
changed
printf 'touch "$RAN/watch"\necho "ok - watch"\n' > factory/tests/watch.test.sh
git commit -q -a -m "a test that names nothing"
echo "# changed" >> factory/scripts/watch.sh
git commit -q -a -m "the change"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "watch"

scenario "a change to helpers.sh starts every test file, since each sources it"
changed factory/tests/helpers.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "factory tests ok: 7 passed in 7 files"

scenario "a change to test-factory.sh starts every test file"
changed factory/scripts/test-factory.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"

scenario "a change to a workflow starts every test file"
changed factory/workflows/ci.yml
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"

scenario "a change to one of the root's package files, or under .github/, starts every test file"
changed pnpm-workspace.yaml
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
rm "$T/ran"/*
echo "# changed" > .github-file && mkdir -p .github/actions/setup && mv .github-file .github/actions/setup/action.yml
git add . && git commit -q -m "a shared action"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"

scenario "a change to pnpm-lock.yaml starts no test file: no shell test installs a package"
changed pnpm-lock.yaml
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran ""

scenario "a changed test file runs, and so does one more for each other changed script"
changed factory/tests/re-ship.test.sh factory/scripts/watch.sh
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "re-ship watch"

scenario "a changed document starts the test file of the script that reads it"
changed SKILL.md
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "retro-lesson"

scenario "a change no shell file names starts no test file, and passes"
changed factory/decisions/429.md apps/web/page.tsx
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran ""
expect_output "The change since HEAD^ can affect 0 of the 7 test files, and only those run."
expect_output "factory tests ok: 0 passed in 0 files"

scenario "a changed script with a letter outside ASCII in its name is read as it is, and starts its test file"
changed
echo 'echo deployed' > "factory/scripts/déploy.sh"
printf 'touch "$RAN/déploy"\necho "ok - déploy"\n' > "factory/tests/déploy.test.sh"
git add .
git commit -q -m "a script"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "déploy"

scenario "a script with a letter outside ASCII in its name that sources the changed file starts its test file"
changed
# shellcheck disable=SC2016
{
  echo '. "$(dirname "$0")/shipping.sh"' > "factory/scripts/déploy.sh"
  printf ': "$scripts/déploy.sh"\ntouch "$RAN/déploy"\necho "ok - déploy"\n' > "factory/tests/déploy.test.sh"
}
git add .
git commit -q -m "a script"
echo "# changed" >> factory/scripts/shipping.sh
git commit -q -a -m "the change"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge déploy ship shipping"

scenario "with no commit, only the test files that the commits since the branch left origin/main can affect run"
changed factory/scripts/watch.sh
git update-ref refs/remotes/origin/main HEAD^
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "watch"
expect_output "can affect 1 of the 7 test files, and only those run."

scenario "with no commit, the commit compared with is where the branch left origin/main, not where origin/main is now"
changed factory/scripts/watch.sh
git branch -q later HEAD^
git checkout -q later
echo "# changed on main" >> factory/scripts/re-ship.sh
git commit -q -a -m "main moved on"
git update-ref refs/remotes/origin/main HEAD
git checkout -q main
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "watch"

scenario "with no commit, a file changed in the working tree counts, staged or not, beside the committed ones"
changed factory/scripts/watch.sh
git update-ref refs/remotes/origin/main HEAD^
echo "# changed" >> factory/scripts/re-ship.sh
echo "# changed" >> SKILL.md
git add SKILL.md
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "re-ship retro-lesson watch"

scenario "with no commit, a new file that git does not yet track counts"
changed
# shellcheck disable=SC2016
echo 'cat "$root/notes.md"' >> factory/scripts/watch.sh
git commit -q -a -m "a script that reads a file"
git update-ref refs/remotes/origin/main HEAD
echo "# Notes" > notes.md
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "watch"

scenario "with no commit and nothing changed since origin/main, every test file runs, and it says so: that is a test of main"
changed factory/scripts/watch.sh
git update-ref refs/remotes/origin/main HEAD
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "Nothing has changed since origin/main, so every test file runs."

scenario "with no commit and no origin/main, every test file runs, and it says so"
changed factory/scripts/watch.sh
RAN="$T/ran" run "$scripts/test-factory.sh"
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "found no commit that this branch shares with origin/main, so every test file runs."
expect_no_output "can affect"

scenario "runs every test file, and says so, when the files git does not track cannot be listed"
changed factory/scripts/watch.sh
git=$(command -v git)
stub git "case \" \$* \" in *' --others '*) exit 2 ;; *) exec \"$git\" \"\$@\" ;; esac"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "so every test file runs."

scenario "runs every test file, and says so, when the changed files cannot be read"
changed factory/scripts/watch.sh
RAN="$T/ran" run "$scripts/test-factory.sh" 0000000000000000000000000000000000000000
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "could not work out which test files the change since 0000000000000000000000000000000000000000 can affect, so every test file runs."

scenario "runs every test file, and says so, when the shell files cannot be searched"
changed factory/scripts/watch.sh
git=$(command -v git)
stub git "case \" \$* \" in *' grep '*) exit 2 ;; *) exec \"$git\" \"\$@\" ;; esac"
RAN="$T/ran" run "$scripts/test-factory.sh" HEAD^
expect_ran "approve-merge re-ship retro-lesson ship shipping test-factory watch"
expect_output "so every test file runs."
