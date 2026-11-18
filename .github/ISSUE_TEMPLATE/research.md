---
name: Research
about: A question answered from public sources. Its output is knowledge in product/, not code.
labels: research
---

<!-- Title: an imperative verb, then what changes, e.g. "Export forecast as CSV". One clause: no reason, no colon, no comma. 60 characters or fewer, no full stop at the end. -->

## Question
<!-- What we want to know, about whom, and what we will do with the answer. -->
<!-- Example: What goes wrong for a runner with a job who trains for a first marathon? The answers become signals to watch. -->

## What to read
<!-- The kinds of public source to search and read, and what to leave out. Nothing behind a login is read. -->

## Output
<!-- The files the research writes, all under product/, and what each holds. -->

## Checks
<!-- What a script can verify in those files, one line each. The first text in backticks is a path under product/, where * stands for any run of characters in a file name; a number before it is the fewest files that must match (one if left out); each later text in backticks is a line every matching file must hold. -->
- 5 files `product/research/*-profile.md`, each with `## Situation` and `## Sources`
- `product/signals.md`
