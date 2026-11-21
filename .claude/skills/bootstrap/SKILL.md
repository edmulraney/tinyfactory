---
name: bootstrap
description: Set up a new factory project end to end (monorepo, purpose, GitHub repo, hosting, database, board, agents). Use when starting a project in an empty directory, or to repair a partly set-up one.
---

# Bootstrap

Ask the human nothing about setup: they only answer the purpose interview, and approve in a browser when a script waits for it.

## Steps

From the project root, `scripts/bootstrap.sh` runs every step in order. Each is a script in `scripts/` that is safe to re-run; run them one at a time to handle a failure or an approval in between: `preflight.sh`, `scaffold.sh`, `purpose.sh`, `github.sh`, `vercel.sh`, `database.sh`, `database-key.sh`, `sign-in.sh`, `preview-access.sh`, `board.sh`, `board-token.sh`, `workflow-app.sh`, `agent-token.sh`.

Run a script that waits for the human in the background, and pass on the code, URL or clicks it prints word for word. Never hand the human a command to type.

- `preflight.sh` fails: run each listed `fix:` command yourself (a login command prints a one-time code and a URL, then waits), and re-run preflight when it exits.
- `purpose.sh` skips when you run the bootstrap yourself: run the `purpose` skill in the conversation at that point, so the first commit carries the purpose.
- `database.sh` and `board.sh` end by printing clicks for what no API can set: pass them on, then re-run the script to confirm.
- `database-key.sh` may open a Neon sign-in: the human signs in the way the Vercel account does.
- `sign-in.sh` skips a product whose `PURPOSE.md` says it has no accounts. If Neon refuses, it prints clicks: pass them on, then re-run it.
- `board-token.sh` waits up to 15 minutes: the human approves as the account that owns the repo.
- `workflow-app.sh` waits up to 10 minutes for each of two approvals: the human clicks **Create GitHub App**, then installs it on **only this repo**.
- `agent-token.sh` waits up to 10 minutes for a browser approval.
- The Claude GitHub App must be installed on the account, by the human: `https://github.com/apps/claude`.

## What belongs where

- **`manifest.txt`** lists the files the factory owns, each by its place in a project; `scaffold.sh` copies them into new projects, those under `apps/` from `templates/` where this repo holds no app, and makes `.github/workflows/` from `factory/workflows/`.
- **`templates/`** holds the seeds each project edits afterwards (`CLAUDE.md`, `ARCHITECTURE.md`, `DESIGN.md`, `TASTE.md`, the health service the factory's route calls, and the app's first code: the database folder and the waitlist on the home page, which `ARCHITECTURE.md` names as the reference feature). `PURPOSE.md` is not a seed.
- This skill sets a project up and repairs a broken setup. Any later change to the factory is a `factory` ticket. `factory/scripts/apply-setup.sh` applies a merged change to one of these scripts where the factory holds a credential that can; `factory/manual-steps.md` lists the scripts that wait for a session.
- A change to how setup or the factory works gets a row in the ticket's file in `factory/decisions/`, in the same commit, as the header of `factory/decisions.md` says. A service setting changed for cost or quota gets an entry in the ticket's file in `factory/free-tier/`, as `factory/free-tier.md` says.
- Anything done by hand during setup is a bug in the bootstrap: put it in a script or the manifest, and re-run `scaffold.sh` in an empty directory to check.

## When a script fails

- Fix the cause, then the script, so the next run needs no help.
- `scaffold.sh` installs the latest Next.js, so generator changes are the likeliest break: read `apps/web/AGENTS.md` and the docs it points to before changing generated code.
- An agent run in Actions fails with no clear error: run the `agent-check` workflow, which prints the API error.
- `vercel.sh` reports the repo is not accessible: give the human `https://github.com/apps/vercel/installations/new` to install Vercel's GitHub App, then re-run the script.
- A workflow change takes effect once merged and installed (`install-workflows.yml`), never from a pull request.
