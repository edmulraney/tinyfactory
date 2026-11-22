# The factory

A ticket goes in; a reviewed, tested, deployed change comes out. A human decides what gets built and is asked only when the agents can't proceed.

This file holds the mission and the principles. Each entry of the three lists under them is a file of its own, in the folder named after its list's heading: `README/known-gaps/` beside this file holds the known gaps. `factory/scripts/readme.sh` prints the whole guide ([H484a](decisions/484.md)).

## Mission

**Rapidly validate an idea at zero cost.**

The factory lets a founder bootstrap a software factory and verify their idea as fast as possible, free of charge, without producing AI slop.

One cost remains today: the agents run on a Claude subscription, which most founders already have. The factory will eventually run on open-weight models as well; until it does, "free" means everything except the model.

## Principles

Every decision in the record (`decisions.md`) should follow from one of these. When two pull in different directions, the earlier one wins.

1. **Free until the idea is proven.** Use the free plans of services that can also carry a real product: GitHub, Vercel, Neon. When an idea works, the plan is upgraded, not the stack. Leave a free plan only when validated demand requires it. The free-tier log has every limit and what stretches it.
2. **A script before an agent.** If a linter, a test or a script can decide something, it does, every time and for nothing. Agents are for judgement. Their tokens are the factory's only real cost, so each agent run has to earn its place.
3. **One opinionated stack.** The stack is chosen once, for speed of prototyping, and a founder is not asked to choose. It is picked for how much is already built: shadcn/ui for the interface, and its AI elements when a product has AI features.
4. **Stand on giants, and build the least that tests the hypothesis.** Take proven tools at their defaults and do not rebuild what exists. This is not a Ferrari. Minimal does not mean sloppy: tests, review and design rules are what keep quick work from becoming slop.
5. **Done means proven.** A ticket carries acceptance criteria, each becomes a test written first, and nothing merges or counts as deployed on trust.
6. **Production is where you find out.** Getting a small change in front of real use teaches more than scrutinising it beforehand, and a small change is cheap to take back. So keep changes small and reversible, ship them, and watch. Tests prove a change does what its ticket says; only use shows whether the ticket was right.
7. **A person brings the evidence and owns the rules; agents turn evidence into work.** An interview becomes a scoped ticket, or a signal to watch until there is more of it. A ticket that meets the bar is started. A change to what the factory spends or may reach or to the product's bar, and anything the agents cannot settle, comes back to a person.
8. **It improves itself.** Every finished run is evidence about the factory: where an agent misunderstood, repeated itself or spent tokens a script could have saved. A run with more friction than one fix round gets a retro, as does a defect the owner meets in use, and a cause seen twice becomes a proposed change to a skill or script. *A first version is built; it proposes changes and starts those for a repeated fault.*
9. **The board is the control plane; the monorepo is the brain.** A person sees and steers the work on the GitHub board. Everything the agents know (the purpose, what users said, the rules, their own transcripts) is plain files in the repo. No other tool: nothing to synchronise, nothing complex, nothing paid.
10. **Every change is a ticket.** A request, whether for the product or for the factory, becomes a ticket of the right type, and the factory builds it. Nobody edits the repo by hand, person or assistant. Two things cannot go this way: setup steps that need the owner's own logins, and a hand step that unsticks a factory too stuck to build its own fix, taken once and with a ticket that removes the need for it (`decisions.md` [A120b](decisions/120.md)).
11. **Nothing by hand.** The factory acts before it asks a person, who steps in only when a decision is theirs or the factory cannot act. Setup is one command. A step a person has to do is a bug, kept only where a service leaves no other way. So is a comment that gives a person a command the factory could have run.
12. **An engineer cannot loosen the rules its own change is judged by,** only the owner changes what the factory spends or may reach, and every credential has the least access that works.
13. **Build what the evidence supports.** A feature carries a hypothesis and a measure of success, and a problem heard once is watched, not built.
14. **Every decision is written down with its reason.** For two reasons. A decision can then be traced and understood later: otherwise nobody, person or agent, can tell a choice from an accident. And an agent starts every task cold: what is written is the only context it has, and it is what lets it make fewer mistakes and see the wider goal its task serves.
15. **A person's decision makes the agents' next decision more accurate.** A correction, an answer or an approval withheld is recorded with its reason where the next agent reads it, so that no person is asked the same thing twice. It is the reason for the decision records, and for the retro on a change the owner sends back.

## Where things are

| What | Where |
|---|---|

## What the factory measures

Seven measures judge a change to the factory. Each merge records its ticket's ([M246](decisions/246.md)); `factory/scripts/measures.sh --week 2026-W47`, or `--month 2026-11`, prints them, and a month's also counts the tickets opened to cut each rule file to its word budget ([H476f](decisions/476.md)).

| Measure | What it is for |
|---|---|

## Known gaps

