# Taste

What "good" means here. Reviewers reject work that breaks these, and nothing else: no nitpicks.

## Approach

- **The smallest standard route.** The scale is a startup idea being validated as fast as possible, without slop. Take the smallest standard engineering solution that does the job at that scale; anything heavier is over-engineering. A general problem is solved once, where that solution puts it, not at each call site. Depart only for a reason that serves the business, the product or the user, such as testing a hypothesis before building the whole thing, and record it as a decision.
- **A check names the failure it prevents.** A rule with a script behind it links to where that failure happened. A check that refuses good work is loosened or deleted, never given an exception.

## Code

- **Deep modules.** Small interface, substantial implementation. A wrapper that only forwards calls is noise.
- **No dead code.** No unused exports, commented-out code, speculative options, or "for later" hooks.
- **Solve today's problem.** No abstraction until the second real use. Three similar lines beat a premature helper.
- **Names carry the meaning.** Use the domain language in `GLOSSARY.md`. A comment explains why, never what.
- **A variable, function, output or file takes the standard engineering term:** the word an engineer would search for (`notified`, `failed`, `retry`), never a house word (`told`). Prose stays plain.
- **Errors are handled where something can be done about them,** and nowhere else. Never swallow one silently.
- **No comment that defends not doing something.** If the simple thing was done, there is nothing to explain.
- **A provider's number is read from the provider when it is needed, or not used.** A limit, balance, price or count that GitHub, Vercel, Neon or Anthropic holds is never copied into a script, variable or rule file; a record may keep a dated measurement, which no script reads.

## Tests

- **Every acceptance criterion has a test that would fail without the change.**
- **No tautological tests.** A test that restates the implementation, asserts on mocks it set up itself, or cannot fail proves nothing.
- **Test behaviour, not structure.** Tests survive a refactor that keeps behaviour the same.
- **Never weaken a test or a lint rule to get to green.** Fix the code, or say why the rule is wrong.
- **A test stays only when it proves behaviour a user or a caller depends on that no other test proves.**

## Pull requests

- **One ticket, one pull request, as small as the ticket allows.** Unrelated cleanups go in their own ticket.
- **The docs named in the ticket are updated in the same pull request.**

## Documents

- **A file holds what stays true until someone edits it.** A ticket's state, a date or "for now" is wrong by the next merge. What happened goes in the ticket or a decision row.
- **A decision row stays only when it stops a rejected path being tried again, or changes how the next change is built.**
- **A reason is given in one place.** Every other place still says the fact and names where its reason is: "The factory stores no Vercel token (decisions [M9](factory/decisions/setup.md))", never "([M9](factory/decisions/setup.md))" alone.

## Writing

These rules apply to everything written, code comments and commit messages included.

- **The shortest text that lets the next reader act.** A list or a table before a paragraph, one line for each thing a file lists. Leave out filler and a reason given elsewhere.
- **A written line stays only when an agent needs it to do its work well, to avoid a mistake or to save tokens.** A fact that only some tasks need goes in the document those tasks read.
- **Say the thing itself.** Do not point at it.
- **Name a thing by what it is, and keep that name.**
- **One idea in each sentence, in the active voice, with its articles.**
- **A number is written with what it measures, and with the limit it is judged against when there is one.** "A contrast ratio of 5.5:1 on the destructive button on hover, where the accessibility standard asks for at least 4.5:1", never "(5.5:1)" alone.
