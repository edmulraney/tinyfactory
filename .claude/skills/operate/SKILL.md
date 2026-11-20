---
name: operate
description: Drive the factory through a backlog - start each ticket in turn, watch builds and reviews, diagnose what fails, and tell the owner what needs them. Use when asked to clear, work through, drive or pick up a backlog of tickets.
---

# Operate

You are the driver, in a session with the owner's `gh` login: you start tickets, read, diagnose and file tickets. You never approve a pull request, push to `main`, or edit a protected file (`CLAUDE.md`, "Off limits"), which takes a ticket; the one exception is the hand merge below.

## The state issue

Everything you know while driving is in one issue, for the owner and for a session that lost its context. First find it (`gh issue list --search "Driving the backlog in:title"`) or open it: title `Driving the backlog from <date>`, no label. Rewrite its body when something changes. It holds, in order:

1. **The goal and the owner's rules,** in their words: what must merge, by when, what you may start without asking.
2. **The state,** with the time: the commit `main` is at and whether production reports it; each open pull request and what it waits for; what is building; what waits for the owner.
3. **The queue:** the tickets not started, in starting order.
4. **Hand steps taken,** each with the ticket that removes the need for it.
5. **Lessons:** what surprised you, a line each, with the ticket it became.

Comment only for what happened at one moment and stays true: a permission the owner gave, with their words and when it ends, or an outage. Close the issue when the backlog is done.

## Starting tickets

1. **Start each ticket in the queue** with the `promote` skill as soon as the points below allow it, without waiting for a place. Five are built or checked at once, and none starts while five pull requests wait for the owner (`factory/scripts/in-flight.sh` lists both); the rest wait with `ready`, and the factory starts the one highest in the board's Backlog column when a place frees (`factory/decisions.md` [T335a](../../../factory/decisions/335.md)). One that misses its bar is a question for the owner, in the state issue.
2. **Choose tickets that share no file:** read each for the scripts, skills and documents it names, and start the second of two that share one when the first has merged.
3. **Start alone** a ticket that rewrites what every merge goes through (the merge scripts, the workflow that runs the checks).
4. **A fix for something in "What breaks" goes first.**

## Watching

Run `factory/scripts/watch.sh` in the background. It exits, saying what changed, when one of these does: the pull requests waiting for the owner, the commit `main` is at, the tickets labelled `needs-human`, the runs that failed, timed out or never started. Act on it, update the state issue, and **start the watch again**, also when it stopped because GitHub could not be read.

Between events, read what the watch prints as "to read when convenient" and never reports as a change: the open tickets labelled `proposal` and `proof`.

- **A retro proposal:** if a ticket already owns its subject, add what is new as a comment there and close the proposal as a duplicate. Otherwise, if the owner wants it, put it in the queue.
- **A proof ticket:** when you see what it asks about happen, comment with the evidence (the run, the pull request) and tell the owner, who closes it.

**A pull request waits for the owner.** Tell them its number and title, in a sentence what it changes, that both reviews passed, and what it assumes that the reviewers could not check (the comment that flagged it starts with that list).

**A merge.** Check that:

1. production reports the commit: the ticket is closed and labelled `deployed`, or `curl -s "$(gh variable get PRODUCTION_URL)/api/health"` shows the commit `main` is at;
2. a change to `factory/workflows/` was installed: within two minutes `main` gets a commit `ci: install the workflow changes approved in #<n>`, or the pull request a comment saying why not;
3. a fix round started for each open pull request that now conflicts (`gh pr view <n> --json mergeable`, never a merge on your own machine), unless it waits to merge.

Then start the next ticket, and file a proof ticket, as the `ticket` skill says, for any line of the merged ticket's "How we will know it works" that only a later run can show. File none for a changed workflow's first run: a retro looks at it ([T185](../../../factory/decisions/185.md)).

**A failed run or a `needs-human` flag.** Read the comment the factory left on the ticket or pull request, then `gh run view <id> --log-failed`, and find the row in "What breaks". With no row, find the cause and file a ticket (the `ticket` skill) that also asks for its row. A failed check or review on a pull request gets a fix round, three at most: do nothing until the third fails.

**Telling the owner.** Only when something needs them, merged or broke. One message for one event: what happened, what you did about it, and what you need from them as one action ("approve #148").

## What breaks

Each row's ticket was filed to remove the need for you to act; read whether its fix is on `main` from the ticket, never from here. What to do applies when the factory has not done it. `checks` is a job of `ci`, the workflow run on every push to a pull request.

| Symptom | How to confirm | What to do | Ticket |
|---|---|---|---|
| A build ends with no pull request ready for review | The comment on the ticket; the last entry's `terminal_reason` and `result` in `issue-<n>/` on the `sessions` branch | Do what the comment's first line says: nothing, add `ready` again, or split the ticket ([A467b](../../../factory/decisions/467.md)) | #69, #467 |
| A pull request conflicts with `main` | `gh pr view <n> --json mergeable` | A merge starts its fix round, not one of the three. If none started: `gh workflow run fix.yml -f pr=<n>`, unless it waits to merge ([M485c](../../../factory/decisions/485.md)) | #89, #124 |
| A fix round ran for seconds and pushed nothing | Its log says "Skipping action due to workflow validation" | `gh workflow run fix.yml -f pr=<n>` | #89, #142 |
| A fix round was announced and never ran | The pull request's next comment starts "Start the fix round again", and the `fix` run failed at its first step | `gh workflow run fix.yml -f pr=<n>` | #433 |
| Fix rounds are counted that no engineer ran | `factory/scripts/fix-rounds.sh <n>` against the pull request's comments | A hand step: delete only the announcement comments of the rounds with no session | #89 |
| `checks` fails saying a workflow source differs from its installed copy on `main` | It ran between a workflow change merging and its install | If it stayed failed: `gh run rerun <id> --failed` | #102, #134 |
| A pull request's reviewers skip themselves, or `checks` says it is "an install behind" | Its `ci` run began before a workflow change was installed | As for a conflict | #134, #142 |
| End-to-end tests all fail with `Invalid URL` | Vercel's status on the head commit reads "Skipped" | Push no empty commit; file a bug | #92 |
| A merge call fails with 502 or 504 | Look on `main` for a commit whose title ends with the pull request's number | Approving again retries. Never run a merge yourself | #67 |
| A second review passes what the first failed, with no change to the code | Compare the two verdicts | File the dropped findings as a ticket, and tell the owner before they approve | #97 |
| Factory tests fail on a Mac and pass in `checks` | `pnpm test` on the Mac names the files | It blocks no merge; file a bug naming the files | #121 |
| Every merge puts every other open pull request in conflict | The conflicts are all in one file each ticket adds a line to | File a ticket to split the file; until it merges start one such ticket at a time | #130, #132 |
| A pull request has used its three fix rounds and conflicts with `main` | `factory/scripts/fix-rounds.sh <n>`, and `mergeable` | The owner chooses: close it and build the ticket again, or the hand merge below. When a pull request is closed, take `in-progress` off its ticket if it is still there | #124, #155 |
| Every new job fails before its first step | The run says "The job was not started because recent account payments have failed or your spending limit needs to be increased": the month's Actions minutes are used | Start nothing, and tell the owner. Once jobs start again the next merge or closed pull request runs them again, or `flag-idle.yml` within six hours; sooner, one command: `factory/scripts/rerun-refused.sh`. `gh run rerun <id>` for a refused run it leaves | #150, #220, #271 |
| No pull request gets a preview and end-to-end jobs fail | Vercel's status on the commit says the deployment was limited: the day's allowance is used | Start nothing and push nothing: each push is a deployment, and a fix round cannot fix it. Tell the owner, and when the deployments begin to age out | #151 |

## A hand step

Anything you do to the repo or a pull request that the factory should have done: merging `main` into a branch, deleting a comment, taking a label off. It is allowed only when the factory cannot build the fix because of the very thing that is stuck, and once: file the ticket that removes the need for it before or straight after, write both in the state issue, and next time use what the ticket built. A product change, or a change to a protected file on `main`, is never a hand step.

**Merging a conflict by hand,** only when no fix round is left or one pushed nothing:

1. Clone the repo into a new folder outside your working copy and check out the pull request's branch.
2. `git merge origin/main`. Where both sides added lines, keep both.
3. Run `pnpm lint` and `pnpm test`; fix only what the merge broke.
4. Commit, and push to the pull request's branch. Never force-push.
5. Correct what the merge made untrue: the pull request's description, and any ticket it lists that cites a decision or entry the merge changed.
6. Delete the folder.

A pull request that waited for the owner still does.
