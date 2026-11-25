---
name: Tweak
about: A small, low-risk change that needs no hypothesis.
labels: tweak
---

<!-- Title: an imperative verb, then what changes, e.g. "Export forecast as CSV". 60 characters or fewer. -->

## Change
<!-- What should be different, in a sentence or two. 120 words at most: evidence is a link to the run or pull request, never the story of it. A ticket that rests on another ticket still open adds a line `After #<n>`: its build starts once #<n> has closed. -->
<!-- Example: The export button reads "Export as CSV". It reads "Export" today, and nothing says which format it gives. -->

## Acceptance criteria
<!-- One per line, numbered. Each becomes an executable test titled with its id. -->
<!-- Each says what a person using the product sees or does, in their words. It never names how the product is built: a class, a token, a colour, an element's id, a function. The check: if the code were rewritten and the product behaved the same, the criterion would still hold. How something looks is shown by a screenshot, not by a criterion. -->
<!-- Bad: "then its text is in the `destructive` colour." Good: "then I see a message that says the password is wrong." -->
<!-- None names a screen's width or any size in pixels: every end-to-end test already runs at both supported widths, mobile and desktop (`DESIGN.md`, "Supported screens"). -->
- **AC1:** Given …, when …, then …

## States
<!-- One row for each state a person can reach each screen this change touches in, such as signed out, signed in with nothing saved, signed in with a race. A state the scope leaves out gets its row too. A row says what the person sees and names the criterion that proves it, or says "unchanged". Write "No screen" if the change touches no screen. -->
<!-- Example: - Dashboard, signed in with a race: I see the race and its date (AC1) -->
<!-- Example: - Dashboard, signed in with no race: unchanged -->

## Docs to update
<!-- Which docs change with this tweak. Write "None" if none. -->
