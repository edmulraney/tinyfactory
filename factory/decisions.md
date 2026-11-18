# Factory decisions

- One row per decision, and nothing else: no paragraph, list or note. This file holds only the sections; `factory/scripts/decisions.sh <this file>` prints the whole record.
- **File:** a ticket's rows go in `decisions/<ticket>.md` beside this file (`setup.md` for a Source of `setup`), as tables with a section's columns and no heading. A pull request adds its own file and edits no shared one.
- **ID:** the section's letter and the number of the ticket adding the row (`T62`), with a letter after it when the ticket adds several to one section (`A69a`, `A69b`); never renumbered or reused. Rows numbered in order (`T4`) came first and keep their IDs. Everything cites a decision by its ID.
- **Decision:** what is true now, in one present-tense sentence of 25 words or fewer. **Why:** the one reason to keep it, in one sentence of 30 or fewer.
- **Rejected:** each alternative turned down, with its reason, in 30 words or fewer; never empty, or the row is a description and belongs in a comment.
- **Source:** the tickets that hold the story (`#47`), or `setup`. The row alone gives the reason; a row over a limit is several decisions, so split it.
- A changed decision is rewritten in the file it lives in and keeps its ID; its old choice moves to Rejected. "To revisit" rows (Idea, Parked because, Revisit when) keep the same limits.

## T: Tickets and state

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## A: Agents

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## M: Merging and deploying

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## P: Pull requests

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## W: Workflow changes

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## S: Stack and setup

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## U: Setup changes after a merge

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## D: Design

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## H: Housekeeping

| ID | Decision | Why | Rejected | Source |
|---|---|---|---|---|

## R: To revisit

| ID | Idea | Parked because | Revisit when | Source |
|---|---|---|---|---|
