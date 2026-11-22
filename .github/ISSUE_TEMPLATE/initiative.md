---
name: Initiative
about: A feature or experiment. Every initiative states a hypothesis and how we will know it worked.
labels: initiative
---

<!-- Title: an imperative verb, then what changes, e.g. "Export forecast as CSV". One clause: no reason, no colon, no comma. 60 characters or fewer, no full stop at the end. -->

## Problem
<!-- Who has this problem, and what is it costing them? Link the research in product/ if there is any. -->
<!-- Example: A planner retypes each forecast into a spreadsheet to share it, about ten minutes a time (product/research/2026-11-03-planner.md). -->

## Hypothesis
<!-- "We believe that <change> will cause <outcome> for <who>." -->

## Success metric
<!-- Three lines, each read by a script. The event is one the product records, which `ARCHITECTURE.md` lists; if it records none that fits, "Scope" adds the event. The number proves the hypothesis: "at least <n> runners in a week" or "at least <n> times in a week". The date is the day we look. -->
<!-- Example: - Event: race added -->
<!-- Example: - Number: at least 5 runners in a week -->
<!-- Example: - Date: 2026-12-20 -->

## Scope
<!-- What is in. What is explicitly out. -->

## Acceptance criteria
<!-- One per line, numbered. Each becomes an executable test titled with its id. -->
<!-- Each says what a person using the product sees or does, in their words. It never names how the product is built: a class, a token, a colour, an element's id, a function. The check: if the code were rewritten and the product behaved the same, the criterion would still hold. How something looks is shown by a screenshot, not by a criterion. -->
<!-- Bad: "then its text is in the `destructive` colour." Good: "then I see a message that says the password is wrong." -->
<!-- None names a screen's width or any size in pixels, which `check-ticket.sh` fails: every end-to-end test already runs at both supported widths, mobile and desktop (`DESIGN.md`, "Supported screens"). -->
- **AC1:** Given …, when …, then …

## States
<!-- One row for each state a person can reach each screen this change touches in, such as signed out, signed in with nothing saved, signed in with a race. A state the scope leaves out gets its row too. A row says what the person sees and names the criterion that proves it, or says "unchanged". Write "No screen" if the change touches no screen. -->
<!-- Example: - Dashboard, signed in with a race: I see the race and its date (AC1) -->
<!-- Example: - Dashboard, signed in with no race: unchanged -->

## Docs to update
<!-- Which docs, diagrams or READMEs change with this work. Write "None" if none. -->

## Visual proof
<!-- Screens or flows the pull request must show in screenshots. Write "None" if not user-facing. -->
