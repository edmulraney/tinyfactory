### 14. A fix round is a workflow of its own, started by a job of one minute

- **Set:** the `fix` job left `ci.yml` for a workflow of its own, `fix.yml`. A `ci` run in which something failed starts it from a job, `start-fix`, that only runs `start-fix-round.sh` (ticket #89; `decisions.md` [A89a](../decisions/89.md) to [A89h](../decisions/89.md)).
- **Protects:** Claude usage and the owner's time, at the price of Actions minutes. As a job of `ci.yml`, a fix round in a run that was re-run, or was in flight when `ci.yml` changed on `main`, got no token for its engineer: on 16 November 2026 pull requests #86 and #87 each had rounds that ran five seconds, fixed nothing and were counted, and three conflicts were resolved by hand in an hour.
- **Numbers:**
  - A fix round after a failed check or review: 1 minute more than before, the `start-fix` job, which checks out `main` and makes two calls to GitHub. A round goes from about 6 billed minutes to about 7. Not measured yet: no round has run this way.
  - A fix round for a pull request a merge left in conflict: 1 minute less than before ([entry 10](entry-10.md)).
  - A round with nothing to fix, asked for twice for one pull request: about 1 minute, the checkout and the look, and no engineer session (`decisions.md` [A89e](../decisions/89.md)).
  - A round whose engineer session never begins is not counted against the three (`decisions.md` [A89c](../decisions/89.md)), and fails its job, which starts a retro ([entry 11](entry-11.md)): 2 to 3 minutes and $1 to $2.
  - Rejected, `fix.yml` starting itself when a `ci` run ends in failure: the same minute, spent on every failed run, a person's pull requests included, and nothing would start a round for a conflict, which has no run.
- **Automated:** yes.
