# What the bootstrap still can't do

The bootstrap skill (`.claude/skills/bootstrap/`) is the record of what is automated: each script says what it does, and `scaffold.sh` builds a project in an empty folder. This file keeps only what is left over: steps that are not automated, steps a human must do, and traps we fell into.

## Not automated yet

| Step | State | What it would take |
|---|---|---|
| One-day previews | One browser step | Vercel's project API rejects the retention setting. `database.sh` opens the page, prints the four values, and confirms them on its next run. Why it matters is in `free-tier.md` [entry 1](free-tier/entry-1.md) |
| Locking `main` on a private free-plan repo | GitHub refuses rulesets and branch protection there. The factory's guards stand in: a git hook in agent jobs and the `guard-main` alarm | GitHub Pro, or a public repo; `github.sh` sets the ruleset by itself when GitHub allows it. That path has never run, because this repo is on the free plan |
| The board's automations | One browser step | GitHub has no API to switch a project's automations on. `board.sh` creates a new board as a copy of a template board, when `FACTORY_BOARD_TEMPLATE_OWNER` and `FACTORY_BOARD_TEMPLATE_NUMBER` name one, and prints the click for the one automation a copy lacks; with no template it builds the board from nothing; an existing board is left as it is. On any board it opens the page, prints the clicks for any of the five that is off, and confirms them on its next run. For "Auto-add to project" it prints the repository and the text to enter as the filter, `is:issue is:open`: every ticket and no pull request, because a card is a ticket (decisions [T4](decisions/20.md)). The API says only whether each is on, not which column it sets, so that part is not checked. What a copy carries is under Gotchas, Git and GitHub |
| Letting the workflow installer through a ruleset on `main` | `workflow-app.sh` puts the project's workflow app on the bypass list of the ruleset `github.sh` sets (decisions [S385c](decisions/385.md)). It was written against GitHub's documentation and a stand-in | The first setup run on a repo the owner made public, or on a paid plan, is the test: GitHub allows the ruleset there, and never has on this private repo on the free plan |
| Trusted domains for sign-in | Not started | Neon's documentation says Neon Auth redirects (OAuth, email links) only to domains on a branch's list, localhost excepted. The first ticket that needs a redirect adds production's domain and a wildcard for previews (`POST …/branches/{id}/auth/domains`) to `sign-in.sh` |
| Publishing the package to npm | A person's step | `npx tinyfactory <name>` (`bin/tinyfactory.mjs`) runs the package of that name on npm, and `npm publish` needs the owner's npm login. `npx github:<owner>/tinyfactory <name>` runs the same command from the repository |
| Bootstrap run end to end in one go | Each script is tested; the whole sequence has never run on a brand-new repo | Delete everything and run it for a fresh project |
| Setting a passphrase-free signing key | Preflight detects the hang but does not fix it | `git config --local user.signingkey` in `github.sh`, choosing a key loaded in ssh-agent |

## Setup changes that wait for a session

When a merged pull request changes a setup script, `factory/scripts/apply-setup.sh` applies it if the factory holds a credential that can: `board.sh` (the `BOARD_TOKEN` secret) and `labels.sh` (the workflow's own token). One that fails puts its output on the ticket, adds `needs-human` and fails the run. The scripts below it cannot run. It says so on the pull request and adds `needs-human`; the change takes effect when the script is next run in a session with the owner's logins. The reason is the same for all of them: the factory stores no Vercel credential and no credential with admin rights on the repo, and why not is in `decisions.md`, rows [M9](decisions/setup.md) and [U2](decisions/36.md).

| Script | Needs |
|---|---|
| `vercel.sh` | The owner's Vercel login |
| `database.sh` | The owner's Vercel login |
| `github.sh` (repo settings, the ruleset on `main`) | Admin rights on the repo |
| `preview-access.sh` | The owner's Vercel login, and admin rights on the repo to store the secret |
| `database-key.sh` | The owner's Vercel login, a Neon sign-in approved in the browser, and admin rights on the repo to store the secret |
| `sign-in.sh` | The owner's Vercel login, a Neon sign-in approved in the browser, and a GitHub login that reads the repo's variables |
| `agent-token.sh`, `board-token.sh`, `workflow-app.sh` | A browser approval by the owner, and admin rights on the repo to store the secret |

## Human-only (technical limits)

A script starts each of these and waits; the human approves in a browser, or at the terminal for Neon's terms. The human types a command only to agree to those terms when an agent runs setup.

| Step | Why |
|---|---|
| The purpose interview and choosing the mission | Only the human knows what they are building. The `purpose` skill runs it; `purpose.sh` opens that skill from a terminal |
| GitHub login with `repo`, `workflow`, `project` | OAuth consent. `project` is account-wide and cannot be narrowed to one repo |
| Vercel login | OAuth consent |
| Claude subscription token | OAuth consent; `agent-token.sh` starts it and stores the token |
| Board token | A one-time code approved in the browser; `board-token.sh` starts it and stores the token. It asks for `project` only |
| The workflow app | Two clicks in the browser: GitHub creates an app only from its owner's browser, and no API installs one. `workflow-app.sh` opens both pages, waits, and stores the key. |
| Installing GitHub Apps (Claude, Vercel) | No API creates an installation. Once per account; with "All repositories" later projects need nothing |
| Neon sign-in | OAuth consent in the browser; `database-key.sh` starts it with Neon's CLI and waits, and `sign-in.sh` uses the same session. It works for a Neon account that Vercel created. The session stays on the owner's machine; only a key limited to this project is stored in GitHub |
| Neon terms | Only the person who is bound by Neon's marketplace terms can agree to them. `database.sh` prints the links and asks at the terminal before it accepts them through the Vercel CLI. With no terminal, as when an agent runs setup, it stops and prints the command for the human to run in one (decisions [S601](decisions/601.md)) |

## Agent jobs on the owner's runner

Four jobs that run an agent (`implement`, `fix`, `retro`, `review`) run on GitHub's hosted runner, billed by the minute in a private repo, unless the repository variable `AGENT_RUNNER` names the label of a self-hosted runner, which GitHub bills nothing (`free-tier.md` [entry #426](free-tier/426.md); decisions [A1](decisions/setup.md), [A426a](decisions/426.md)). It is for a private repo only: a public repo's minutes are free, and there a stranger's pull request would start a review on the owner's machine. Nothing sets it up, because it needs a machine of the owner's and admin rights on the repo:

1. Take a Linux x64 machine or virtual machine that stays on and is used for nothing else: an agent runs any command on it as the runner's user, and what one job leaves outside its home folder is there for the next (decision [A426c](decisions/426.md)). It needs Ubuntu, as GitHub's runner has, with `git`, `gh`, `jq` and `curl` installed, and `sudo` with no password for the runner's user, because the Playwright install adds system packages.
1. On GitHub open the repo's Settings → Actions → Runners → New self-hosted runner, choose Linux and x64, and run on that machine the download and `./config.sh` commands the page prints. Keep the labels it offers; `self-hosted` is one of them.
1. `sudo ./svc.sh install && sudo ./svc.sh start` in the runner's folder, so the runner starts again when the machine does.
1. `gh variable set AGENT_RUNNER --body self-hosted`, in a session with the owner's login.

A runner takes one job at a time and the others wait, unbilled. For jobs to run side by side, repeat the second and third steps in another folder on the machine: two reviews and three builds can be due at once. While the machine is off every agent job waits, and GitHub cancels one that waited 24 hours. `factory/scripts/minutes.sh <day> <day>` shows what the four jobs were billed on a day. `gh variable delete AGENT_RUNNER` puts them back on GitHub's runner.

These steps were written from GitHub's documentation and have not been run.

## Gotchas (each one cost us time)

**Vercel**
- Hobby refuses to deploy a private repo owned by a GitHub organization. A personal private repo works, including commits authored and pushed by the Claude app.
- Importing before the first push gives a failing first build. A monorepo needs Root Directory `apps/web`.
- An empty commit is skipped as "didn't affect this project", and so is one that changes only `factory/`, `.claude/` or `.github/`, which are workspace packages for that reason (decisions [M165a](decisions/165.md)); every other branch push gets a preview. A change to a file outside every workspace package (the root's documents, `product/`) counts as a change to everything and is built. The skipped commit's status is still `success`, and Vercel's PR comment then holds no preview URL; CI tests the preview the branch was last tested on, unless the last deployment before it failed (decisions [M92a](decisions/92.md), [M92c](decisions/92.md)).
- Previews sit behind a Vercel login (HTTP 302). CI needs the bypass secret from `preview-access.sh`.
- Vercel creates no GitHub deployment records here; CI reads the preview URL from Vercel's PR comment after its commit status goes green.
- `vercel api` exists in CLI 65.x but not 50.x; scripts call `npx vercel@latest`.
- `vercel link` drops a `.env.local` with a short-lived token; `database.sh` removes it.
- Vercel tries to build every branch, including `sessions`, and fails on the missing app folder. An "ignored build step" does not help: the root directory check fails first. `sessions-branch.sh`, which every script that writes the branch sources, keeps an `apps/web/vercel.json` on it with `git.deploymentEnabled: false`.
- A preview's Neon database branch is deleted only when the last Vercel deployment for its git branch is deleted, and Vercel keeps previews 30 days. Neon's free plan allows 10 branches. Hence one-day preview retention, set in the dashboard: the project API rejects `deploymentExpiration`. One day was still too slow on a busy day, so CI also deletes the branch itself through Neon (`free-tier.md` [entry 8](free-tier/entry-8.md)).
- On 14 November 2026 the factory stalled on that limit after twelve pull requests in a day, and the fix round could not help: its empty commit does not make Vercel rebuild a preview (see above). What cleared it was deleting the stale database branches and redeploying the failed preview.
- Vercel's CLI login cannot create a token ("Cannot create tokens for this app"), and a dashboard token was refused a project-only one (403). The factory stores no Vercel token (decisions [M9](decisions/setup.md)).
- Vercel's CLI refuses deletions when no person is at the terminal: `vercel remove` answers with a command to run "only after a human approves", and `vercel api -X DELETE` needs an explicit skip flag.
- A Vercel token was refused another token of any kind ("You don't have permission to create the token").
- The per-preview database branch setting is not in Vercel's CLI or API spec, and the connection record shows no field for it until it has been switched on once. Diffing the record before and after a manual tick revealed `deployments`, which the connection endpoint accepts in a PATCH.
- Vercel creates the Neon database but gives the project no Neon API key, and has no command or API for database branches. Neon's own CLI login (`npx neonctl auth`) works for an account created through Vercel and can create a key limited to one project. The Neon project id is the database resource's external id in Vercel, and a preview's branch is named `preview/<git branch>`.
- A deployment that got its own database branch shows `integrations: {status: "ready"}` in its record; one that did not shows `null`.
- In the connection dialog, the "Create Database Branch For Deployment" boxes stay greyed out until "Require Active Resource Before Deploy" is switched on.

**Neon Auth**
- Neon switches auth on for a database Vercel created: `sign-in.sh` has done so through Neon's CLI. Vercel's own form offers it when the database is created, and `database.sh` answers `auth=false`. Neon's documentation excludes only projects with IP Allow or Private Networking. If Neon refuses, `sign-in.sh` prints the clicks and confirms them on its next run.
- How a preview learns the auth address of its own database branch: Neon's integration tells it. With auth on for the production branch, Neon provisions it on each `preview/…` branch and gives that preview's deployment its own `NEON_AUTH_BASE_URL` when it builds, as it does `DATABASE_URL`. Such per-branch values are never listed in the project's settings. So `sign-in.sh` sets the address for production only (decisions [S287b](decisions/287.md)).
- Not documented, and seen: when auth is switched on after the database was made, Neon's integration lists `NEON_AUTH_BASE_URL` for previews itself. `sign-in.sh` says which it found, and leaves a listed one alone.
- How people sign in is two settings of a database branch: Magic Link, off until switched on (`PATCH …/branches/{id}/auth/plugins/magic-link`), and email and password, on until switched off (`PATCH …/auth/email_and_password`); `GET …/auth/plugins` shows both. `sign-in.sh` switches the link on and the password off for the production branch and every `preview/…` branch that has Neon Auth (decisions [S342a](decisions/342.md), [S342b](decisions/342.md)). A preview's branch made before auth was on has none: `neon neon-auth status` says so, and the script passes over it (decisions [S384](decisions/384.md)). Neon's CLI has no command that changes Magic Link, so the script sends all three requests with the CLI's `api` command (neonctl 9.6.3).
- A step of `ci.yml`'s `checks` job switches Magic Link on, with the Neon key, for production's branch and for the preview's branch of the pull request it checks (decisions [M342](decisions/342.md)), so a preview made before the link was on can send one with no session on the owner's machine. It leaves email and password alone: switching it off locks people out of an app that still signs them in by a password, so `sign-in.sh` does it, run once the app on `main` sends a link. A failure shows in that step's log and fails no check; for a product with no accounts Neon has no sign-in settings to show, so the step is expected to fail in every run. If it fails for a product with accounts, `sign-in.sh` in a session with the owner's logins does the same.
- A branch made from production copies its users, so a test user kept in production can sign in on every preview. Sessions do not carry over: a cookie belongs to one domain.
- The CLI's `neon-auth enable` answers a branch that already has auth (HTTP 409) with what is there, so it is safe to repeat; `neon-auth status` prints a sentence, not JSON, for a branch with none.
- The cookie secret must be at least 32 characters; `openssl rand -base64 32` gives 44.

**Claude in Actions**
- The Claude app only issues a token when the workflow file on `main` is identical to the one running. From a PR that adds or edits the workflow, the action skips itself and still reports success.
- `claude-code-action` rejects the `push` trigger.
- A failed agent run shows only `is_error: true`. Run the `agent-check` workflow to see the API error.
- `claude setup-token` hard-wraps the token at terminal width; a hand-copied token was truncated to 79 characters and failed with a 401.
- PRs opened by the Claude app need `allowed_bots: claude` on any Claude step they trigger.
- Claude's own progress comments fire `issue_comment`; the job's `if` must skip them.
- `claude-fable-5-2` needs CLI 2.1.290+. An older local CLI cannot run it; Actions installs the latest.

**Git and GitHub**
- `commit.gpgsign` with a passphrase-protected key makes `git commit` hang at an invisible prompt.
- With two `gh` accounts on one machine, every script acts as the active one; check it before setup. `gh auth refresh` has no `-u` flag.
- Without squash-only merging, the first merge produced a merge commit; `github.sh` now sets it.
- Two jobs pushing to the `sessions` branch at once: rebasing in a clone with no committer identity silently saved nothing. `sessions-branch.sh` now retries from a fresh clone and verifies the push, for every script that writes the branch.
- A workflow's own token cannot touch a personal project board, and a token with only `project` cannot see a private repo's issues ("Could not resolve to a node"). Hence no workflow moves a card: GitHub's own project automations add and move them. The `project`-only token is kept for the one thing it can do, re-running `board.sh`, which is why that script skips the repo link when its login cannot see the repo.
- Setting a board's columns without passing each existing column's `id` replaces them: cards lose their status and every automation that pointed at a column is reset. `board.sh` passes the ids.
- A copied board (seen on 17 November 2026, ticket #283) carries the Status columns, the four views and these automations switched on, each still setting its column: "Item added to project", "Pull request linked to issue", "Item closed", "Item reopened". A card added to the copy was in Backlog, closed in Deployed, reopened in Backlog. It does not carry "Auto-add to project", which is not listed on the copy at all: it names the repository, so that click stays.
- GitHub fills the filter of "Auto-add to project" with `is:issue,pr is:open label:bug` (seen on 19 November 2026). Left as it is, the board takes only tickets labelled `bug`, and pull requests as cards of their own.
- The template board is private, by the owner's choice, so only the owner's account can copy it. For any other account `board.sh` builds the board from nothing and prints all five clicks. That path was written against a stand-in: what GitHub answers an account that cannot see the template is assumed to be "Could not resolve", as it is for a repo.
- GitHub's project automations cannot react to a label. A column only a label could fill stays empty; use a filtered view.
- A step that holds a secret must not run scripts from a pull request's checkout, or after pull request code or an agent has run in the same job: the pull request can change the script.
- Anything a workflow does with its own token (merging, labelling, opening issues) starts no other workflow, except `gh workflow run`. That is why any `guard-main` run means a bot pushed to `main`, and why `ship.sh` starts the retro and the workflow installer that way, and `merge-queue.sh` the run that tests and merges.
- A workflow's own token can never write a file in `.github/workflows/`, whatever permissions the job asks for; neither can the Claude app. Hence the project's own app, used by `install-workflows.yml` alone.
- A workflow file must be on `main` before `gh workflow run` can start it, and a pull request that changes a file in `.github/workflows/` runs its changed version at once. Hence sources in `factory/workflows/`, where GitHub runs nothing.

**Scaffold**
- shadcn's `init` (4.23) rewrites `globals.css` with `--font-sans: var(--font-sans)`, which points at itself; `scaffold.sh` repoints it at the layout's font variable. It also makes dark mode class-based, so the app no longer follows the system setting.
- shadcn installs a package called `cn`. It is shadcn's own (repo `shadcn-ui/cn`), not a typo-squat of the `cn` helper.
- shadcn's own components use one-off values, so the lint rule against them is off for `src/components/ui`.
- Removing Tailwind's palette also removes `black` and `white`; the theme adds them back.
- shadcn's stock destructive button and badge (red text on a pale red tint) fail WCAG AA contrast at 3.82:1. The accessibility scan catches it the first time one appears on a page.
- create-next-app fails if the parent folder is missing, pins `@types/node` to 20 (Vitest needs 22+), and needs `next typegen` before `tsc` on a clean checkout.
- `$(pnpm -v)` inside `cat > package.json <<EOF` returns nothing, because the redirect has already created an empty `package.json`.
- `apps/web/AGENTS.md` is generated by create-next-app and re-created by `next dev`. Commit it.

## Fallback: labels instead of a board

For people who won't grant the account-wide `project` permission, skip `board.sh` and `board-token.sh`. Ticket state as labels (`ready`, `in-progress`, `needs-human`, `deployed`, and `proposal` and `proof` for what the board shows in views of their own) needs nothing extra and lives inside the repo. The factory reads the board for one thing, the order of the tickets that wait: with no board, the ticket that has waited longest with `ready` starts first (decisions [T335b](decisions/335.md)).
