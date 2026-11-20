---
name: promote
description: Add the `ready` label, which starts an unattended build, to a backlog ticket that meets the bar. Use when asked to promote, start or ship a ticket, or after filing one the owner wants built.
---

# Promote

`ready` starts a build that merges and deploys unwatched. This skill is the owner's standing permission to add it to a ticket that meets every point of the bar; anything short is a question for the owner.

## The bar

1. **It follows its template:** `factory/scripts/check-ticket.sh <n>` passes, and the title is an imperative verb and what changes, not only where.
2. **It was asked for** by the owner, an interview `intake` sorted as "build now", or a retro proposal the owner accepted. Your own idea: ask the owner before filing it (`factory/decisions.md` [T223](../../../factory/decisions/223.md)).
3. **It fits `PURPOSE.md`** and is nothing under "What it will not do".
4. **You can picture the Playwright test for each criterion.** A chore has none and changes no behaviour; a research ticket lists checks on its files; a factory ticket says how it will be proven.
5. **An Initiative has** a hypothesis, a success metric, and a signal with three independent sources in `product/signals.md`, none of them synthetic (`factory/decisions.md` [A33c](../../../factory/decisions/33.md)), or the owner's explicit request. A Tweak or Bug is cheap and plainly right.
6. **It is one pull request's worth,** or split it and promote the first.
7. **Its builder may touch it.** Esme builds initiative, bug, tweak and chore tickets and changes none of the factory's files (`CLAUDE.md`, "Off limits"). Rosa builds `research` tickets and changes only `product/`. Fred builds `factory` tickets. Tell the owner the pull request waits for them if the ticket changes what only they decide, the product's bar or `CLAUDE.md`.
8. **It is not in flight** (`factory/scripts/in-flight.sh`). The exception: this ticket's line ending `left unfinished` is a build cut short, which `ready` builds again (`factory/decisions.md` [T64h](../../../factory/decisions/64.md)). With five others being built or checked, or five pull requests waiting for the owner, it waits with `ready`, and is started when a place frees ([T269a](../../../factory/decisions/269.md)).

## Steps

1. `factory/scripts/thread.sh <n>`, and check every point, afresh for each ticket.
2. **Met:** `gh issue edit <n> --add-label ready`, the same for an accepted `proposal` or a ticket waiting with `needs-human`. Tell the owner which ticket you started, or that it waits for a place, in a line why it met the bar, and whether it is likely to edit the same lines as a ticket in flight.
3. **Not met:** do not label it. Fix what you can in the ticket (a vague criterion, a missing section) and check again, unless it is `in-progress` or has an open pull request: that one is never edited. Otherwise tell the owner which point failed and what you need.

Never add `ready` to make a point or to test the factory unless the owner asked for that test.
