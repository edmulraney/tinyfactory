---
name: ticket
description: Turn a conversation, bug report or research note into a GitHub issue that follows the factory's ticket templates. Use when the user wants to file an Initiative, Bug or Tweak.
---

# Ticket

An agent builds exactly what the ticket says. Never edit one that is `in-progress` or has an open pull request: a change of mind is the owner's "Request changes" review.

1. **Pick the type.** Initiative: a feature or experiment, with a hypothesis and success metric. Bug: behaviour differs from what was intended. Tweak: a small, low-risk change to behaviour. Chore: no change in behaviour. Research: a question answered from public sources, as files in `product/`. Factory: a change to the factory itself.
2. **Fill every section** of `.github/ISSUE_TEMPLATE/<type>.md`, with `PURPOSE.md` and `product/` for context.
3. **Before an Initiative,** ask the user, one question at a time, what problem it solves, for whom, and what is out of scope. Push back on scope the hypothesis does not need.
4. **Acceptance criteria** (Initiative, Bug, Tweak): `- **AC1:** Given <state>, when <action>, then <result>`, each testable through the running app. The result is what a person using the product sees or does, never how the product is built: the template's comments hold the test and an example. Under "States", read the app to find every state a person can reach each touched screen in, also a state the scope leaves out ([T575a](../../../factory/decisions/575.md)). A Chore has neither. A Factory ticket says what can be run or observed to prove it, a Research ticket what a script can check in its files.
5. **Title** as `CLAUDE.md` says. A Bug's says what is fixed. A change that needs two clauses is usually two tickets.
6. **Body:** the change and its reason, "Change" in 120 words at most. It says what must be true afterwards, and names the way to get there only where the owner chose it ([A617a](../../../factory/decisions/617.md)). Evidence is a link to the run or pull request, never the story. It does not talk to the reader. It reuses an existing label before adding one ([T576a](../../../factory/decisions/576.md)). A ticket that adds a rule to a rule file never asks for the rule to be short or for other lines to be cut to fit the file's word budget ([T535](../../../factory/decisions/535.md)).
7. **Create:** `gh issue create --title "<title>" --label <type> --body-file <temporary file>`.
8. **Validate:** `factory/scripts/check-ticket.sh <number>`, and fix what it reports.
9. Tell the user the number. It is built when it gets `ready`.

A request the factory cannot build waits in the backlog, linked to the `factory` ticket you file to make it possible ([T33f](../../../factory/decisions/33.md)).

An agent nobody asked files a ticket only for a defect it saw happen, with a link to the run or output that shows it: an idea or a risk is not filed ([T223](../../../factory/decisions/223.md)). A retro's proposal has its own bar, in the `retro` skill.

## A proof ticket

For what only a later run can show. The owner or the session driving the backlog files it after the merge, never an engineer ([T170](../../../factory/decisions/170.md)). A changed workflow's first run needs none: a retro looks at it ([T185](../../../factory/decisions/185.md)). Title: "Confirm" and what the run will show, in the title format. Body: the pull request that left it, what to look for and in which run. Label `proof` alone, and skip step 8, which refuses it. The owner closes it once the run has been seen.
