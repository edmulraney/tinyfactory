### 9. The factory's own tests run inside `pnpm test`, not in a job of their own

- **Set:** `test-factory.sh`, the first part of `pnpm test`, runs every test in `factory/tests/` (tickets #56 and #61). The `checks` job already runs `pnpm test`, so no workflow step or job was added.
- **Protects:** Actions minutes. A job of its own would cost a whole minute on every push to a pull request, because every job rounds up: 9 minutes a ticket would become 10, and about 220 tickets a month about 200.
- **Numbers:** 181 tests in 8 files take about 17 seconds on a two-core machine (measured on the runner that built ticket #56), with no network and no install. That is added to the `checks` job, which already runs; whether it tips that job over a minute boundary shows in the job's billed time.
- **What they save:** a fix round on a factory script costs about 6 Actions minutes, and $3.27 and $5.83 of agent usage on pull requests #42 and #46.
- **Automated:** yes.
