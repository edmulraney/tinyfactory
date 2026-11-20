# {{name}}

Read `PURPOSE.md` (who this is for and what it will not do), `ARCHITECTURE.md` (how the code is organised), `DESIGN.md` (how the interface looks and behaves), `TASTE.md` (what good work looks like) and `SECURITY.md` (who is trusted) before changing code.

@TASTE.md

Working on the factory itself (`factory/`, `.claude/skills/`, `.github/`)? Its mission and principles are at the top of `factory/README.md`; follow them.

## Commands

Run from the repo root.

- `pnpm lint`, `pnpm typecheck`, `pnpm test` (unit, Vitest), `pnpm build`
- `pnpm test:e2e` (Playwright; builds and starts the app locally unless `BASE_URL` is set)

All five must pass before a pull request is marked ready for review.

## Tests

- Unit tests sit next to the code as `*.test.ts`.
- Acceptance tests: `apps/web/e2e/acceptance/<issue-number>-<slug>.spec.ts`, one test per criterion, titled `AC<n>: …`. Write them first and watch them fail.
- End-to-end tests import `test` and `expect` from `e2e/test.ts`, which adds an accessibility scan to every test that opens a page.

## Commits, branches and PR titles

Use Conventional Commits. Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `ci`.

- **Ticket title:** an imperative verb, then what changes, e.g. `Export forecast as CSV`. One clause: no reason, no colon, no comma. 60 characters or fewer, sentence case, no full stop at the end. `factory/scripts/check-ticket.sh` checks it.
- **Commit and PR title:** `<type>: <imperative summary>`, e.g. `feat: export forecast as CSV`. The summary is the ticket's title in the same words, and the whole title is 72 characters or fewer. PRs are squash-merged, so the PR title becomes the commit on `main`.
- **Both say what changes, not where:** `Fix scaffold in an empty directory` could be any fix; `Fix scaffold failing lint in an empty directory` says which.
- **Branch:** `<type>/<issue-number>-<slug>`, e.g. `feat/12-export-forecast-csv`. Work with no issue omits the number.
- **Slug:** two to five words naming the outcome or feature a customer would recognise (`export-forecast-csv`, `not-found-page`), never the implementation (`add-util`, `refactor-table`, `fix-bug`). A ticket has one slug: the branch and its acceptance test file both use it.
- **PR description** follows `.github/PULL_REQUEST_TEMPLATE.md`: `Closes #<issue-number>`, one paragraph of 50 words at most on what changed, then one line each, only when there is something to say, for how it differs from the ticket and what it needs from the owner after merging. Its first sentence says what changed and stands alone, and it stays under 100 words. `factory/scripts/check-pr-conventions.sh` checks it.

## Decisions are written down

Nothing is decided in passing, for two reasons: a written decision can be traced and understood later, by a person or an agent; and an agent starts every task cold, so what is written is the only context it has to make fewer mistakes and to see the wider goal its task serves. When you choose between real alternatives (a tool, a setting, a pattern, a limit, a way of working), record what you chose, why, and what you rejected, in the same change, in the place a reader would look for it:

| A decision about | Goes in |
|---|---|
| What the product is and is not | `PURPOSE.md` (the owner's call) |
| A product choice, including what we chose not to build | `product/decisions.md` |
| How the code is organised | `ARCHITECTURE.md` |
| How the interface looks and behaves | `DESIGN.md` |
| What good work looks like | `TASTE.md` |
| How the factory works | `factory/decisions.md` |
| A setting made to stay on a free plan | The ticket's entry in `factory/free-tier/`, with numbers, written as `factory/free-tier.md` says |
| How an agent does its job | That agent's skill |
| One line of code | A comment on that line saying why |

Plans and status notes are not files. A plan is an issue; a result is a commit message, a pull request or a row in the decision record. A file made to get a piece of work done is deleted in the change that finishes it. `pnpm lint` fails on a document nobody owns.

The repo is the only memory. A rule, preference or lesson that should shape future work is written in this repo, where every person and every agent reads it. It is never kept only in an assistant's private memory, local settings or a file on one person's machine, because the next person or agent to work here would not have it.

A decision record is a file (`factory/decisions.md`, `product/decisions.md`) that holds the format and the sections, and a folder beside it where each ticket keeps its rows in a file of its own (`factory/decisions/<ticket>.md`), so that two pull requests never edit the same file. `factory/scripts/decisions.sh [record]` prints a whole record; `pnpm lint` checks it.

A decision with no written reason is not finished. If the right place is off limits to you, write the decision and its reason in the pull request description, and file a `factory` ticket to record it where it belongs.

## Off limits

- **The factory's files:** `.claude/`, `.github/`, `factory/`. Only a `factory` ticket changes them, and only **Fred** builds one. His pull request merges once both reviewers pass it, unless it changes what only the owner decides (`factory/scripts/owner-decides.sh`), which waits for their approval:
  - **spend or limits:** a model, effort, turn limit or timeout, the tickets in flight;
  - **secrets or permissions:** a `permissions:` block, a secret, a token or key script, the tools or bots an agent may use;
  - **this rule:** the scripts that decide the hold.
- **The product's bar:** `TASTE.md`, `DESIGN.md`, the design theme (`globals.css`, `components.json`), and lint, TypeScript and test configuration (including `e2e/test.ts`). **Esme** changes one when her ticket asks for it. Whoever changes one, the pull request waits for the owner.
- **`CLAUDE.md`:** the same wait, whoever changes it.
- **Workflows** are changed in `factory/workflows/`. The copies GitHub runs (`.github/workflows/`) are never edited: the installer copies them in once the pull request merges, so a changed workflow never runs before both reviewers pass it, or before the owner approves what only they decide. `pnpm lint` fails on an installed copy that was edited, or never installed.

## Every change is a ticket

When the owner asks for something, do not make the change yourself. Write the ticket of the right type (the `ticket` skill) and start it (the `promote` skill); the factory builds it. That holds for the product and for the factory, workflows included. The two exceptions are a setup step that needs the owner's own logins, and a hand step to unstick the factory, as the `operate` skill limits it (`factory/decisions.md` [A120b](factory/decisions/120.md)).
