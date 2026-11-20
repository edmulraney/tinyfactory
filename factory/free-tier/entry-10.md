### 10. A pull request is tested with the current `main` only when `main` has moved

- **Set:** a pull request that passed its checks and reviews waits to merge, and `merge-group.yml` tests those that wait together with `main`, once for the group ([entry #455](455.md)). A group of one whose own `checks` job passed with `main` as it is now merges with no second test, because `checks` tested that merge (`decisions.md` [M17](../decisions/57.md)). Until ticket #455 a job of `ci.yml`, `fits-main`, tested each pull request alone whenever `main` had moved (tickets #57, #250). After a merge, an open factory pull request GitHub reports as conflicting gets a fix round directly (ticket #89).
- **Protects:** Actions minutes. A job that starts is billed a whole minute, so the test of a group is a job a condition skips when there is nothing to test.
- **Numbers:** the four commands the test runs (`pnpm lint`, `typecheck`, `test`, `build`) took 46 seconds together on the two-core runner that built ticket #57: 29, 4, 1 and 12. The factory's own tests have since made the `checks` job, which runs the same commands, 3.3 billed minutes ([entry #388](388.md)).
  - One ticket in flight, merging by itself: `main` does not move under it, and no second test runs.
  - Several that wait together, or one under which `main` moved: [entry #455](455.md).
  - A pull request left in conflict: a fix round (about 6 minutes), started by the merge that caused it, in a job that already runs.
  - Rejected, testing every open pull request on every merge: with three open, 3 minutes on every merge, to find sooner a break that is rare.
- **Storage:** each passing `checks` job leaves a 41-byte artifact naming the commit of `main` it ran with, kept 90 days, and each run of `merge-group.yml` one of a few kilobytes, kept 7. Nothing against 500 MB.
- **Automated:** yes.
