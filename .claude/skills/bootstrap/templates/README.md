# {{name}}

<!-- The purpose skill puts the mission and what the product is here, from PURPOSE.md. -->

Who it is for and what it will not do: [PURPOSE.md](PURPOSE.md).

This project is built in a [tinyfactory](https://github.com/edmulraney/tinyfactory). AI agents build, review and ship each change, and a person decides what gets built.

## Run it

```sh
pnpm install
pnpm dev        # http://localhost:3000
```

Every pull request has to pass `pnpm lint`, `pnpm typecheck`, `pnpm test` and `pnpm build`. `pnpm test:e2e` runs the end-to-end tests.

## How a change gets made

1. **Open an issue.** The Idea template takes a rough idea, and the product agent turns it into small tickets with you. The other templates are for a ticket you can already describe.
2. **Add the `ready` label** to a ticket. An engineer agent builds it test-first and opens a pull request.
3. **Checks and two reviewer agents** go over the pull request. One that passes merges and deploys by itself.
4. **Answer what is labelled `needs-human`:** approve the pull request, or submit a "Request changes" review that says what to change.

The project board shows where every ticket is. `factory/README.md` is the full guide to the factory.

## Where things are

| What | Where |
|---|---|
| The app (Next.js) | `apps/web/` |
| What the product is for | `PURPOSE.md` |
| Research, signals and product decisions | `product/` |
| How the code is organised | `ARCHITECTURE.md` |
| How the interface looks and behaves | `DESIGN.md` |
| What good work looks like | `TASTE.md` |
| Who the factory acts for, and how to report a vulnerability | `SECURITY.md` |
| The factory: agents, workflows and scripts | `.claude/skills/`, `.github/`, `factory/` |
