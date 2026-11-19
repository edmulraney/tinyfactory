# Architecture

## Two things in one repository

- **The package.** `npx tinyfactory <name>` (`bin/tinyfactory.mjs`) runs the bootstrap skill, which sets up a new project: a repository, a board, the factory, an app, hosting and a database.
- **The factory.** Skills, workflows, scripts and their tests. It is copied into every project, and it also runs here, to build tinyfactory.

There is no app in this repository. A change here is a change to the factory or to the package.

## Where things are

| Folder | Holds |
|---|---|
| `bin/` | The command a person runs |
| `.claude/skills/` | One skill for each agent's job. `bootstrap/` is setup: its scripts, the manifest and the templates |
| `.claude/skills/bootstrap/templates/` | What a new project starts with and tinyfactory does not use itself: seed documents, and the app's lint and test setup |
| `factory/workflows/` | The source of every workflow |
| `.github/workflows/` | The copies GitHub runs, installed from the sources after a merge. Never edited |
| `factory/scripts/` | What the workflows run. Bash, each with its use in its first lines |
| `factory/tests/` | A test file for each script; `helpers.sh` makes the stand-ins for outside commands |
| `factory/decisions/`, `factory/free-tier/` | The records: one file for each ticket |
| `product/` | What users of tinyfactory said, and product decisions |

## What reaches a project

Setup copies two things into a new project, and nothing else:

- **The paths in `.claude/skills/bootstrap/manifest.txt`.** The factory owns them, and they are the same in every project.
- **The templates.** Each project edits its copies afterwards.

Everything at the root of this repository (`PURPOSE.md`, this file, `TASTE.md`, `CLAUDE.md`, `README.md`, `package.json`, `product/`) is tinyfactory's own and reaches no project. The copy is one-way and happens once: a project owns its files from then on.

So a change to a file in the manifest changes every project set up afterwards. What only this repository needs is kept out of a project by name, where the script that copies decides (`scaffold.sh`).

## Principles

- **A script before an agent.** What a script or a check can decide, it decides. An agent is for judgement.
- **One workflow for each event, one skill for each job.** A workflow runs an agent with one skill when its event arrives.
- **A workflow never runs before it is reviewed.** It is changed in `factory/workflows/`, where GitHub runs nothing, and installed once its pull request has merged.
- **Only the owner starts anything.** A workflow that runs an agent, holds a secret or writes to the repository acts for the repository's owner and for nobody else.
- **Every script has a test.** The test stands in for each outside command and proves each failure as well as the success.

## Domain language

| Term | Meaning |
|---|---|
| Project | A repository that `npx tinyfactory` set up |
| Owner | The GitHub account that owns the repository |
| Ticket | A GitHub issue written to a template. The `ready` label starts its build |
| Manifest | The list of paths the factory owns in every project |
| Seed | A template a project edits after setup |
| Fix round | A fresh session that fixes a pull request after a failed check or review |
| Retro | The agent that finds the cause of a run's friction and may propose a change |
