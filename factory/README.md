# The factory

A ticket goes in; a reviewed, tested, deployed change comes out. A human decides what gets built and is asked only when the agents can't proceed.

## Mission

**Rapidly validate an idea at zero cost.**

The factory lets a founder bootstrap a software factory and verify their idea as fast as possible, free of charge, without producing AI slop.

One cost remains today: the agents run on a Claude subscription, which most founders already have. The factory will eventually run on open-weight models as well; until it does, "free" means everything except the model.

## Principles

Every decision in the record (`decisions.md`) should follow from one of these. When two pull in different directions, the earlier one wins.

1. **Free until the idea is proven.** Use the free plans of services that can also carry a real product: GitHub, Vercel, Neon. When an idea works, the plan is upgraded, not the stack. Leave a free plan only when validated demand requires it. `free-tier.md` has every limit and what stretches it.
2. **A script before an agent.** If a linter, a test or a script can decide something, it does, every time and for nothing. Agents are for judgement. Their tokens are the factory's only real cost, so each agent run has to earn its place.
3. **One opinionated stack.** The stack is chosen once, for speed of prototyping, and a founder is not asked to choose. It is picked for how much is already built: shadcn/ui for the interface, and its AI elements when a product has AI features.
4. **Stand on giants, and build the least that tests the hypothesis.** Take proven tools at their defaults and do not rebuild what exists. This is not a Ferrari. Minimal does not mean sloppy: tests, review and design rules are what keep quick work from becoming slop.
5. **Done means proven.** A ticket carries acceptance criteria, each becomes a test written first, and nothing merges or counts as deployed on trust.
6. **Production is where you find out.** Getting a small change in front of real use teaches more than scrutinising it beforehand, and a small change is cheap to take back. So keep changes small and reversible, ship them, and watch. Tests prove a change does what its ticket says; only use shows whether the ticket was right.
7. **A person brings the evidence and owns the rules; agents turn evidence into work.** An interview becomes a scoped ticket, or a signal to watch until there is more of it. A ticket that meets the bar is started. A change to what the factory spends or may reach or to the product's bar, and anything the agents cannot settle, comes back to a person.
8. **It improves itself.** Every finished run is evidence about the factory: where an agent misunderstood, repeated itself or spent tokens a script could have saved. A run with friction gets a retro, and a cause seen twice becomes a proposed change to a skill or script. *A first version is built; it proposes changes and starts those for a repeated fault.*
9. **The board is the control plane; the monorepo is the brain.** A person sees and steers the work on the GitHub board. Everything the agents know (the purpose, what users said, the rules, their own transcripts) is plain files in the repo. No other tool: nothing to synchronise, nothing complex, nothing paid.
10. **Every change is a ticket.** A request, whether for the product or for the factory, becomes a ticket of the right type, and the factory builds it. Nobody edits the repo by hand, person or assistant. Two things cannot go this way: setup steps that need the owner's own logins, and a hand step that unsticks a factory too stuck to build its own fix, taken once and with a ticket that removes the need for it (`decisions.md` A120b).
11. **Nothing by hand.** Setup is one command. A step a person has to do is a bug in setup, kept only where a service leaves no other way.
12. **An engineer cannot loosen the rules its own change is judged by,** only the owner changes what the factory spends or may reach, and every credential has the least access that works.
13. **Build what the evidence supports.** A feature carries a hypothesis and a measure of success, and a problem heard once is watched, not built.
14. **Every decision is written down with its reason.** For two reasons. A decision can then be traced and understood later: otherwise nobody, person or agent, can tell a choice from an accident. And an agent starts every task cold: what is written is the only context it has, and it is what lets it make fewer mistakes and see the wider goal its task serves.

## Using it

The `ready` label starts a build. Dragging a card starts nothing.

1. **File a ticket.** Ask a Claude Code session in this repo (the `ticket` skill), or use an issue template. Initiative, Bug and Tweak change behaviour and carry numbered acceptance criteria; Chore changes none; Research answers a question in `product/`; Factory changes the factory.
2. **Add the `ready` label,** or ask the `promote` skill to. Three tickets are built or checked at once at most, and a pull request that waits for you is not one of them (T64a). Five pull requests wait for you at most: while five do, no build starts (T361a). A ticket with no place waits with `ready`, a comment on it says which limit holds it, and when a place frees the waiting ticket highest in Backlog starts first: drag a card up to build it sooner (T335a). A ticket whose body has a line `After #<n>` waits with `ready` until #<n> has closed (T339a).
3. **Watch or walk away.** The issue goes `in-progress` and a draft pull request appears, the engineer marks it ready, checks and reviews run, and it merges. The issue closes with `deployed` once production reports the merged commit; a change to the factory's own folders alone deploys nothing, and closes without the label. The card is in **In progress** from the draft until the issue closes, then in **Deployed**, shipped or not: the label says which.
4. **Look for `needs-human`,** on the **Needs you** tab. The ticket was unclear, three fix rounds did not reach green, a session was cut short, nothing was working on it, or only you may decide the change; a comment says what to do.
   - **A pull request that waits for you:** approve it and it ships.
   - **A pull request you want changed:** submit a "Request changes" review saying what. The engineer makes or answers each change, and it comes back for your approval.
   - **A pull request labelled `waits-for-main`:** what failed lies outside it, and its comment says what. The next merge to `main` tests it again (A368a).
   - **A ticket you accept:** add `ready`.
   - **A shipped ticket you want back out:** `gh workflow run revert.yml -f number=<ticket>` has an engineer open the pull request that reverts it. Once that merges the ticket reopens as `reverted`; add `ready` to build it again.
5. **Read what the factory suggests,** on the **Proposals** tab: add `ready` to accept one, or close it.
6. **Confirm what only use can show,** on the **Proofs** tab. When only a later run can show that a merged ticket works, you or the session driving the backlog file a `proof` ticket titled "Confirm …"; the engineer never does (T170). Close it once you have seen the run. A changed workflow needs none: a retro of its first run says on the pull request what it found (T185).
7. **Hand a whole backlog to a session.** It follows the `operate` skill, keeps the state in one issue, and never approves a pull request, pushes to `main` or edits a protected file (A120d).
8. **Share a user interview** in a session: the `intake` skill files tickets only where the evidence is strong.
9. **When an agent run fails with no clear error,** run the `agent-check` workflow: it prints the API error.
10. **Ask for help** in any comment that holds `@claude`: an agent replies (A372a).
11. **Open an Idea:** Peta proposes slices, then files them unstarted once you answer (A353a).
12. **Judge a model as the reviewers** with the `benchmark` workflow; a `factory` ticket adds each problem both reviewers missed (A345d).

## Where things are

| What | Where |
|---|---|
| Agent instructions | `.claude/skills/`: `implement` (Esme), `factory-engineer` (Fred), `research` (Rosa), `refine` (Peta), `review-architecture` (Adam), `review-code` (Ryan), `retro`, `ticket`, `intake`, `purpose`, `promote`, `operate`, `bootstrap` |
| The factory's files, and what only the owner decides, the product's bar included | `factory/scripts/protected-paths.sh`, `factory/scripts/owner-decides.sh`; the merge gate runs `main`'s copies (M2, M272a, M272e) |
| Workflows | Written in `factory/workflows/`. GitHub runs the copies in `.github/workflows/`, installed once a change merges and never edited (W1) |
| The events: what starts each workflow, and what it does | `factory/scripts/events.sh` prints them from `factory/workflows/` (H293a) |
| Scripts, and their tests | `factory/scripts/`, each with its use in its first lines, and `factory/tests/` (H3); for setup, `.claude/skills/bootstrap/scripts/` |
| Why the factory is built this way | The decision record: `factory/decisions.md` and `factory/decisions/<ticket>.md`, printed whole by `factory/scripts/decisions.sh` |
| The stack, and each free limit | Decision S1; the free-tier log, printed whole by `factory/scripts/free-tier.sh` |
| What guards `main` | Decisions M1 and W9; `free-tier.md` entry 7 |
| The rule files, and how many words each may hold | `factory/rule-files.txt` (H172b) |
| Transcripts, screenshots, the retros' lessons and each ticket's measures | The `sessions` branch: one folder per issue or pull request, `lessons/` and `measures.jsonl` (A16, P19, H246a) |
| What a ticket cost | A comment on it when it merges; `factory/scripts/ticket-cost.sh --month 2026-11` prints a month's (M221a) |
| What is not automated | `factory/manual-steps.md` |

## What the factory measures

Six measures judge a change to the factory. Each merge records its ticket's (M246); `factory/scripts/measures.sh --week 2026-W47`, or `--month 2026-11`, prints them.

| Measure | What it is for |
|---|---|
| Cost per ticket: Claude dollars and Actions minutes | The factory's only real cost, and the free plan's minutes |
| Time to merge, split into build, review, fix rounds and waiting (H246c) | How fast an idea is proven, and which part to shorten |
| Share passing with no fix round | Whether tickets and rules are clear enough to build right first time |
| Stops for a person per ten tickets (H246d) | How often the agents could not proceed |
| Tickets opened per merge (H246e) | The work a merge leaves behind |
| Bugs later traced to a ticket | What review and the tests let through |

## Known gaps

- **Four events start nothing:** `intake` accepting an insight (its ticket would go straight to `ready`), a signal reaching three sources (an Initiative proposed), the clock (upkeep tickets) and production breaking (a Bug ticket with the error).
- **An `in-progress` label no build holds is taken off by hand.** A pull request closed unmerged, or a runner that dies mid-build, leaves its ticket holding a place.
- **The bypass header for previews is sent on every request Playwright makes**, including to third-party hosts a page might load.
