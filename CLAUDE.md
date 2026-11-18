# tinyfactory

This repository is tinyfactory itself: the files it gives every project. It is not a project made with it. `README.md` says what it is and how far it has been tested.

## Starting a project

`npx tinyfactory <name>` makes the folder `<name>` and runs the whole bootstrap in it (`bin/tinyfactory.mjs`). To run one step, follow `.claude/skills/bootstrap/SKILL.md`: run its scripts from an empty directory outside this repository, by their full path, for example `<this repository>/.claude/skills/bootstrap/scripts/bootstrap.sh`. `scaffold.sh` copies the files listed in `.claude/skills/bootstrap/manifest.txt` from here into the new project.

## Changing tinyfactory

- No factory runs on this repository: its one workflow, `.github/workflows/scaffold.yml`, only checks that a project can still be scaffolded from the package `npx tinyfactory` runs. The other skills in `.claude/skills/` (`ticket`, `promote`, `operate` and the agents' own) are for use inside a project, not here. Change this repository with an ordinary pull request.
- A change to a script comes with a change to its test in `factory/tests/`. Run them with `factory/scripts/test-factory.sh`.
- A decision gets a row in `factory/decisions/`, as the header of `factory/decisions.md` says.
- Write plainly, for a reader who has read neither the ticket nor the code (`.claude/skills/bootstrap/templates/TASTE.md`, "Writing").
