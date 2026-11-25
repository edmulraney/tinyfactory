---
name: Bug
about: Something behaves differently from what was intended.
labels: bug
---

<!-- Title: an imperative verb, then what changes, e.g. "Export forecast as CSV". 60 characters or fewer. -->

## What happens
<!-- The wrong behaviour, as observed. -->
<!-- Example: Pressing "Export" on a forecast with no rows downloads nothing and shows no message. -->

## What should happen
<!-- The intended behaviour. -->

## Steps to reproduce
1. 

## Acceptance criteria
<!-- One per line, numbered. AC1 should fail today and pass once the bug is fixed. -->
<!-- Each says what a person using the product sees or does, in their words. It never names how the product is built: a class, a token, a colour, an element's id, a function. The check: if the code were rewritten and the product behaved the same, the criterion would still hold. How something looks is shown by a screenshot, not by a criterion. -->
<!-- Bad: "then its text is in the `destructive` colour." Good: "then I see a message that says the password is wrong." -->
<!-- None names a screen's width or any size in pixels: every end-to-end test already runs at both supported widths, mobile and desktop (`DESIGN.md`, "Supported screens"). -->
- **AC1:** Given …, when …, then …

## States
<!-- One row for each state a person can reach each screen this change touches in, such as signed out, signed in with nothing saved, signed in with a race. A state the scope leaves out gets its row too. A row says what the person sees and names the criterion that proves it, or says "unchanged". Write "No screen" if the change touches no screen. -->
<!-- Example: - Dashboard, signed in with a race: I see the race and its date (AC1) -->
<!-- Example: - Dashboard, signed in with no race: unchanged -->

## Docs to update
<!-- Which docs change with this fix. Write "None" if none. -->
