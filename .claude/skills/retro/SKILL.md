---
name: retro
description: Find the cause of a run's friction (a fix round, a failed review, a stop for a human) or of a failed factory workflow run, or check a changed workflow's first run. Records a lesson, and proposes a change when it can show what the fault cost and the run lost work or money, stopped for a person or repeats an earlier cause. Use with a pull request number, a workflow run id, or both.
---

# Retro

Find the cause of the run's friction and write it down. Fix nothing and change no files.

## What you are given

- **The facts** as JSON, at the path the prompt gives. `owner_rounds` are the fix rounds the owner asked for, in their "Request changes" review; `reviews.<name>.assumptions` is what a reviewer could not check; `terminal_reason`, `api_error_status`, `api_retries` and `result` say how a session ended. For a changed workflow's first run, `changed_by` holds that pull request and its reviewers' assumptions, and `changed_steps` each step its diff names in that workflow: its job, its conclusion and the end of its log, or none of them when the run never reached it.
- **The transcripts** the facts list. Never read one end to end: Grep for the failing step, the error text and the moment the agent changed course.
- **Earlier lessons**, one JSON file each, in the folder the prompt names.
- `gh pr view <n> --comments`, `gh issue view <n> --comments` and, for a failed run, `gh run view <id> --log-failed`.

## Steps

1. **Read the facts** for where the friction was.
2. **Find the cause, not the symptom.** "The type check failed" is a symptom; the cause is why work that failed it was pushed: the ticket left something out, a skill's instruction was missing or wrong, a check does not exist, the agent ignored an instruction, something outside the factory broke, or the factory's own rule, check or step cost more than the work needed (`process`).
3. **For a failure, separate what broke from what the factory did about it.** A service being down (GitHub answering `502`, the model's API overloaded) is `outside`. Then read what the factory did next, in the workflow or script that was running, the ticket's and pull request's comments and labels, and `main`. `handling` lists each that is true:
   - `lost-work`: finished work was thrown away, such as a session's changes never pushed;
   - `left-wrong`: something wrong was left behind, such as a label that no longer fits, a second merge, a half-done step;
   - `told-nobody`: it stopped without a comment or label that tells a person what happened.
4. **List the earlier lessons that repeat:** those with the same cause, not the same symptom, and those whose facts hold an assumption (`unverified` in an older lesson) of the same kind as one in this run's (the same tool or service, the same sort of question). The change for the second kind is whatever would let a reviewer or a check confirm such an assumption.
5. **Decide what would have prevented it.** Ask first what the standard engineering solution to this fault is: where there is one, it is the change, and an instruction in a skill (4 and 5 below) is proposed only when there is none. Otherwise prefer the earliest that works:
   1. for `process`, removing or loosening what caused it;
   2. a script, lint rule or check that fails earlier;
   3. a change to a ticket template or `check-ticket.sh`, so the gap cannot be filed;
   4. removing or rewording an instruction in a skill;
   5. adding an instruction to a skill.

   For a failure outside the factory, first consider trying the failed call again after a wait. `retry` says whether that would have been `enough`, `not-enough` (the service stayed down longer than a retry would wait, or the loss had already happened) or `harmful` (the call may have taken effect before it failed, as a merge can). Propose the retry when `enough`; otherwise what the facts show is needed, such as checking what happened before trying again, or saving the work first. For any other cause it is `not-applicable`.

   "Nothing" is a valid answer for a one-off the factory handled well.
6. **Give what the fault cost and what the change would save,** each with a figure from the facts: a fix round costs about its session's cost and minutes; a session cut short, what it had spent. `cost.kind` lists each that is true:
   - `lost-work`: as in step 3;
   - `lost-money`: a session's cost bought nothing;
   - `stopped`: the run stopped for a person.

## A changed workflow's first run

In place of steps 2 and 3, compare what the pull request in `changed_by` claimed (`gh pr diff`) with what the run did (`changed_steps`). `summary` says whether it did, did not, or never reached the change. Only "did not" has a `change`. One that did has `cause` `one-off`, no `handling` and `retry` `not-applicable`.

## When to propose

`propose` is true only when step 6 gives a figure for the cost and for the saving, and one of these holds:

- **The run lost work or money, or stopped for a person:** `cost.kind` is not empty.
- **The cause has been seen before:** step 4 lists a lesson. One bad run is not a pattern.

A changed workflow's first run that did not do what was claimed, and a failure handled badly, are held to the same bar. Below it the lesson is saved and nothing is filed: `retro-proposal.sh` refuses the proposal (`factory/decisions.md` A223a).

A proposal that adds a check needs an earlier lesson with the same cause, unless this run lost work or money.

## Output

Return the required structured format:

- `summary`: one sentence a person can act on.
- `title`: the change as a ticket title, in the format `CLAUDE.md` gives. It names the change, not what went wrong. Empty when `change.kind` is `none`.
- `cause`: `ticket`, `skill-missing`, `skill-wrong`, `check-missing`, `agent-ignored`, `process`, `outside` or `one-off`.
- `detail`: a short paragraph on what happened and why. For a failure: what broke, then what the factory did about it.
- `evidence`: a link to each run, pull request or comment that shows it, never the story.
- `change`: `kind` (`script`, `check`, `template`, `skill`, `none`), `target` (the file), `proposal` (the exact change and its one reason, small enough for one edit, in 100 words at most, naming the standard engineering solution to the fault or saying there is none) and `removes` (in a phrase, what it also takes away, or `nothing`).
- `cost`: `cost.amount`, what the fault cost on this run, and `cost.kind`, both as step 6.
- `saves`: what the change would have saved on this run, as step 6.
- `repeats`: the file names of step 4's lessons.
- `handling`: as step 3; empty for a pull request's friction or a failure handled well.
- `retry`: as step 5.
- `propose`: true or false.
- `held_by`: the open ticket, among those the prompt names, that already holds this change; `0` for none.
