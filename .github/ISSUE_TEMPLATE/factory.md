---
name: Factory
about: A change to the factory itself - its scripts, skills, checks, templates or rules.
labels: factory
---

<!-- Title: an imperative verb, then what changes, e.g. "Export forecast as CSV". One clause: no reason, no colon, no comma. 60 characters or fewer, no full stop at the end. -->

## Change
<!-- What should be different in how the factory works, and why. Name the files if you know them. 120 words at most: evidence is a link to the run or pull request, never the story of it. If the change makes the factory act by itself (start, retry, re-run or pass something on), say when it must not: what stops it when the cause is one every run shares, such as an outage or a limit. If the change adds to what is trusted (a domain, an origin, a token's reach, a tool list), name each entry exactly; a pattern needs the reason nobody else can match it. A ticket that rests on another ticket still open adds a line `After #<n>`: its build starts once #<n> has closed. -->
<!-- Example: `check-pr-conventions.sh` fails a description over 100 words, with the count. The owner reads every one, and #148 ran to 592 words for 20 lines. -->

## How we will know it works
<!-- What can be run or observed afterwards that proves it. A pull request for this waits for the owner only if it changes spend or limits, secrets or permissions, the merge gate, the product's bar or `CLAUDE.md`. -->
