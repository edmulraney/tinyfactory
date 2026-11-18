# Staying on the free tier

The factory's first job is to let a product hypothesis be tested without paying for infrastructure. Every entry in the log is a setting or design choice made to stretch a free limit, with the numbers that justify it and whether setup applies it by itself.

**Add an entry whenever a setting is changed for cost or quota reasons.** Say what was set, which limit it protects, the before and after in units someone can check, and why it could or could not be automated. A new entry goes in a file of its ticket's own, `free-tier/<ticket>.md` beside this file, so that two pull requests never edit the same lines. It is headed `### #<ticket>. <title>` (`#62a`, `#62b` when one ticket adds several), ends with its one `- **Automated:**` line, and is cited as `entry #62`. The entries numbered in order (`entry 8`) came first: they stay under Log below and keep their numbers, and no new one is added. `factory/scripts/free-tier.sh` prints the whole log; `factory/scripts/check-free-tier.sh` checks its shape in `pnpm lint`.

## The limits

Figures are the providers' published free-plan limits on 2026-11-14. "Per ticket" is measured on this repo (ticket #12, a small change with no fix round).

| Service and plan | Limit | Used by | Per ticket | Ceiling |
|---|---|---|---|---|
| GitHub Actions, Free, private repo | 2,000 minutes a month. Every job rounds up to a whole minute | Every workflow job | 9 minutes: build 4, five CI jobs 5. A sixth job, `fits-main`, runs only when `main` moved (entry 10) | About 220 tickets a month, built singly; about 180 with three always in flight (entry 16) |
| GitHub artifact storage, Free | 500 MB | Playwright report (0.25 MB, kept 30 days); three transcripts (0.05 MB together, kept 90 days) | 0.3 MB | Not a constraint: 200 tickets is about 60 MB |
| Vercel, Hobby | 100 deployments a day, one building at a time, 45 minutes per build | One preview per push to a pull request, one production deploy per merge; none for a change to the factory's own folders alone (entry #165) | 2, plus 1 per fix round, and perhaps 1 for the draft's first commit (entry 15). A ticket that changes only the factory's folders: 0 | About 50 tickets a day that change the app |
| Neon, Free | 10 branches per project including production, so 9 for previews. 1 GB storage, 100 compute-hours a month, compute sleeps after 5 idle minutes | One branch per pull request, held until its git branch is deleted (entry 8) | 1 branch while the pull request is open | 9 between the pull requests open at once and those merged since checks last ran (entry 8); the factory's own hold 3 at most (entry 16) |
| Neon Auth, Free | 60,000 monthly active users per project (read 2026-11-17) | Sign-in, for a product with accounts (`sign-in.sh`) | None | Not a constraint: an idea with 60,000 people signing in each month is proven |
| Claude subscription | The plan's usage limits. The one part that is not free | Esme, Adam, Ryan | About $1 at API prices | Depends on the plan |

**What binds first:** Actions minutes, at about 220 small tickets a month. Before the settings below, Neon's branch limit would have stopped the factory at the tenth pull request of the month.

**A limit that is not a number:** Vercel's Hobby plan is for personal, non-commercial use. A product that starts charging needs Vercel Pro, whatever its traffic.

## Log

### 1. Previews are kept for one day

- **Set:** Vercel project → Deployment Retention Policy → Canceled, Errored and Pre-Production deployments: 1 day. Production stays at 30 days.
- **Protects:** Neon's 10 branches.
- **Why:** each preview gets its own database branch (entry 2), and Neon deletes that branch only when Vercel deletes the last deployment of the pull request's git branch. Vercel's default keeps previews for 30 days.
- **Numbers:** at 30 days, 9 preview branches means 9 pull requests a month; the tenth gets no database and its build fails. At 1 day the same 9 slots turn over daily: about 270 pull requests a month, 30 times more. That is still only 9 pull requests in any one day, which was not enough: see entry 8. This setting stays as the fallback for a branch entry 8 misses.
- **Errored and canceled too:** a preview that fails to build can still hold a database branch.
- **Production at 30 days:** rolling production back needs the old deployment to still exist. Further back than that, take the ticket back with the `revert` workflow (decisions M19c).
- **Why not delete the preview at the moment of merge:** that needs a Vercel token in GitHub Actions. Vercel's CLI login cannot create tokens, a token cannot create another token, and the dashboard only issues tokens for the whole account. An account-wide token is too much to store where agents run.
- **Automated:** no. Vercel's project API rejects the setting (`deploymentExpiration`: "should NOT have additional property"). `database.sh` opens the page, prints the four values, and on later runs reads them back and confirms.

### 2. Every preview gets its own database branch

- **Set:** on the database's connection to the project, `deployments: {required: true, actions: [{slug: "Neon", environments: ["preview"]}]}`. In the dashboard: "Require Active Resource Before Deploy" on, and "Create Database Branch For Deployment → Preview".
- **Protects:** production data, not a quota. Sharing one database would mean a pull request's migrations run on live data before anyone has reviewed them, its tests write into real records, and two open pull requests fight over one schema. `ARCHITECTURE.md` (Environments) has the full reasoning.
- **Costs:** one of the 9 branch slots per pull request (hence entry 1), and 4.5 seconds added to each preview build (measured). Compute is small: a preview's database wakes for its tests and sleeps after 5 minutes, about 0.02 compute-hours per pull request, so 200 pull requests use about 4 of the 100 hours.
- **Automated:** yes, by `database.sh`. The field is in neither Vercel's CLI nor its public API spec; it was found by comparing the connection record before and after ticking the boxes by hand.

### 3. The transcript branch is never deployed

- **Set:** the `sessions` branch carries `apps/web/vercel.json` with `git.deploymentEnabled: false`.
- **Protects:** Vercel's 100 deployments a day.
- **Why:** Vercel tries to build every branch pushed to the repo. Each saved transcript was a failed deployment: three per ticket (Esme, Adam, Ryan), plus one per fix round.
- **Numbers:** 5 deployments per ticket became 2, so the daily ceiling went from 20 tickets to 50. It also stops that branch claiming one of Neon's 9 preview slots.
- **Automated:** yes. `sessions-branch.sh`, through which every write to the branch goes (`decisions.md` A98), writes the file whenever it is missing. An "ignored build step" on the project does not work: Vercel fails on the missing app folder first.

### 4. Card moves use no Actions minutes

- **Set:** GitHub's own project automations add and move the board's cards (ticket #20). This replaces the earlier setting, which no longer applies: workflows used to move the cards, as a step inside `implement.yml` and `ci.yml` so that only a new ticket's first card cost a run of its own.
- **Protects:** Actions minutes. A separate job costs a whole minute however short it is.
- **Numbers:** a ticket went from 10 minutes to 9, the new-ticket card run being gone: about 220 tickets a month instead of 200.
- **Automated:** partly. GitHub has no API to switch a board's automations on, so a new board is a copy of a template that has four on (`decisions.md` S283a). `board.sh` prints the clicks for the rest and on later runs reads them back and confirms.

### 5. Reviewers run only after end-to-end tests pass

- **Set:** the `adam` and `ryan` jobs need `e2e`. This replaces the earlier setting, which no longer applies: they needed `checks` as well, and now start beside it (ticket #250; entry #250).
- **Protects:** Claude usage and Actions minutes.
- **Numbers:** a pull request that fails its end-to-end tests skips both reviews: 2 minutes and about $0.54 of agent usage saved on each such round.
- **Automated:** yes.

### 6. The repo belongs to a personal account, not an organization

- **Set:** `github.sh` creates the repo under the logged-in user.
- **Protects:** the Vercel bill. Hobby refuses to deploy a private repo owned by a GitHub organization; the alternative is Vercel Pro at $20 a month.
- **Automated:** yes.

### 7. `main` is guarded by the factory, not by GitHub

- **Set:** a git hook in agent jobs and the `guard-main` alarm, in place of a branch ruleset.
- **Protects:** the GitHub bill. Rulesets on a private repo need GitHub Pro at $4 a month.
- **Cost of the choice:** the hook stops mistakes, not a determined agent; the alarm catches the rest after the fact. `github.sh` sets the real ruleset whenever GitHub allows it.
- **Automated:** yes.

### 8. A preview's database branch is deleted as soon as its pull request is gone

- **Set:** the first step of the `checks` job in `ci.yml` lists the Neon branches named `preview/…` and deletes each whose git branch no longer exists. A merged pull request's git branch is deleted at the merge, so its database branch goes when the next pull request's checks start. The step uses the `NEON_API_KEY` secret and the `NEON_PROJECT_ID` variable.
- **Protects:** Neon's 10 branches.
- **What happened:** on 14 November 2026 twelve pull requests in one day used every branch, and the next preview failed with "Branch limit reached". Entry 1 frees a branch a day after its preview was made, so it allows 9 pull requests in a day and no more.
- **Numbers:** before, 9 pull requests opened in any one day. After, however many are merged in a day, the limit is on those open at the same time, less a margin. Vercel asks Neon for a new pull request's branch at the push, before this step has run, so a pull request merged since the last checks run still holds its slot at that moment: the 9 slots are shared by the open pull requests and those merged since the last run. With 8 open and one just merged, the next pull request's preview fails with "Branch limit reached"; its own checks then free the slot, and pushing to it again builds the preview. Once checks have run, the branch count is the open pull requests plus `main`. The step adds a few seconds to a job that already runs, so no Actions minutes.
- **Why Neon directly:** Vercel gives the project no Neon key and has no command or API for database branches. Deleting the preview deployment instead would need a Vercel token, which Vercel issues only for the whole team (entry 1).
- **Why at the next pull request, not at the merge:** the merge is done by `ship.sh`, and the key is never given to a script (`decisions.md` M10). The branch is only needed back when another pull request wants one, which is exactly when this step runs.
- **Automated:** yes, after one browser sign-in. `database-key.sh` signs in with Neon's CLI, creates a key limited to this project and stores it. A project without the variable skips the step and falls back to entry 1.

### 9. The factory's own tests run inside `pnpm test`, not in a job of their own

- **Set:** `test-factory.sh`, the first part of `pnpm test`, runs every test in `factory/tests/` (tickets #56 and #61). The `checks` job already runs `pnpm test`, so no workflow step or job was added.
- **Protects:** Actions minutes. A job of its own would cost a whole minute on every push to a pull request, because every job rounds up: 9 minutes a ticket would become 10, and about 220 tickets a month about 200.
- **Numbers:** 181 tests in 8 files take about 17 seconds on a two-core machine (measured on the runner that built ticket #56), with no network and no install. That is added to the `checks` job, which already runs; whether it tips that job over a minute boundary shows in the job's billed time.
- **What they save:** a fix round on a factory script costs about 6 Actions minutes, and $3.27 and $5.83 of agent usage on pull requests #42 and #46.
- **Automated:** yes.

### 10. A pull request is tested with the current `main` only when `main` has moved

- **Set:** the `fits-main` job in `ci.yml` carries a condition: it is skipped in a run's first attempt, where `checks` starts at the same moment and tests the same merge, and runs when it is asked for again. Until ticket #250 it waited for the reviews, and also ran when one found that `main` had moved since `checks` (entry #250). `ship.sh` asks for it again in one case only: before a merge, for a pull request last tested with an older `main` (ticket #57). After a merge, an open factory pull request GitHub reports as conflicting gets a fix round directly (ticket #89).
- **Protects:** Actions minutes. A job that starts is billed a whole minute, and a skipped job is billed nothing, which is why the skip is a condition and not an early exit.
- **Numbers:** the four commands it runs (`pnpm lint`, `typecheck`, `test`, `build`) took 46 seconds together on the two-core runner that built ticket #57: 29, 4, 1 and 12. With the checkout and install, the `checks` job, which runs the same four, took 38 and 60 seconds on the two pull requests before it. So `fits-main` is one billed minute when it runs.
  - One ticket in flight, merging by itself: `main` does not move under it, the job is skipped, and a ticket stays at 9 minutes.
  - A pull request that waited for the owner while another merged: 2 minutes more, `fits-main` and the merge gate running again after it.
  - A merge that waited its turn behind another, or `main` moving while the run was going: 3 minutes more, the third being `rerun-fits-main.yml`, because a run cannot re-run its own job.
  - A pull request left in conflict: a fix round (about 6 minutes), started by the merge that caused it, in a job that already runs. The minute `fits-main` took to fail on the conflict first is no longer spent (ticket #89).
  - Rejected, testing every open pull request on every merge: with three open, 3 minutes on every merge, to find sooner a break that is rare.
- **Storage:** each passing `checks` or `fits-main` job leaves a 41-byte artifact naming the commit of `main` it ran with, kept 90 days. Nothing against 500 MB.
- **Automated:** yes.

### 11. A retro on a failed factory workflow, and its waits

- **Set:** `retro.yml` runs for a failed `implement`, `approve-merge`, `install-workflows` or `fix` run, and for a failed `merge` or `start-fix` job of `ci` (tickets #70, #89). Its job carries a condition, so it is skipped when the workflow it watches did not fail. `ci` is not watched: its `merge` and `start-fix` jobs start the retro themselves, in a step that runs only when the job failed.
- **Protects:** Actions minutes and Claude usage.
- **Numbers, per failure:** one retro. The five retros so far cost $0.94, $1.15, $1.55, $1.58 and $1.96 of agent usage, and their sessions took 49 to 119 seconds, so with the checkout and the clone of `sessions` a retro is 2 to 3 billed minutes. A failure that lost a build cost far more: $5.44 and 16 minutes on ticket #57.
- **Numbers, when nothing failed:** nothing. Every `implement`, `approve-merge`, `install-workflows` and `fix` run that ends leaves a skipped `retro` run in the Actions list; a skipped job is billed no minute.
  - Rejected, watching `ci` the same way: the event says only that the run failed, so a job would have to start to see which job it was. A failed check is a fix round, so every fix round would cost a minute more.
- **The waits:** the retro's agent is tried up to three times, 5 and then 10 minutes apart, because the service that failed the run may still be down. A runner that waits is billed, so an outage that outlasts all three tries costs 15 minutes of waiting on top of the retro, and the job stops at 45 whatever happens. A retro whose first try works waits for nothing. Five and ten are a judgement: the one outage measured, on ticket #57, defeated seven tries in 70 seconds and was over 28 minutes later.
- **Not retried:** a session that ended for a reason of its own, such as running out of turns. Trying again would pay for the same ending twice more.
- **Automated:** yes.

### 12. Screenshots are published from a job that already runs

- **Set:** two steps at the start of the `adam` job in `ci.yml` fetch the end-to-end job's artifact and run `post-screenshots.sh`, which pushes the ticket's screenshots to the `sessions` branch and posts a comment, a new one for each push that passed (`decisions.md` P98; ticket #18). No job was added.
- **Protects:** Actions minutes. The end-to-end job cannot hold the token that writes the branch (`decisions.md` P22), and a job of its own would be billed a whole minute on every push to a pull request: 9 minutes a ticket would become 10, and about 220 tickets a month about 200.
- **Numbers:** the artifact is 0.25 MB, and the script makes one clone of `sessions`, one push and two calls to GitHub. Whether that tips Adam's job over a minute boundary shows in the job's billed time.
- **Storage:** nothing against the 500 MB of artifacts: the images go to the `sessions` branch, which GitHub does not meter but asks to keep under 1 GB with the rest of the repo. The two page screenshots measured on this repo (1280 by 720) were 12 KB and 60 KB, and only the ticket's own tests are kept (`decisions.md` P20). At three page criteria a ticket and one fix round, about 0.25 MB a ticket: 200 tickets a month is about 50 MB a month.
- **Automated:** yes.

### 13. A session cut short is continued on the runner it ran on

- **Set:** in `implement.yml`, `fix.yml` and `ci.yml` (jobs `adam` and `ryan`), a session that ends before its work is handed over is continued in the same job, twice at most. One the Claude usage limit ended is not continued: its work is kept, its job passes and no retro starts (`decisions.md` A231a, A231c). The retro is not continued but started afresh, with waits of its own (entry 11). After an API error the job waits first: 2 minutes before the first continuation, 5 before the second (ticket #69; `decisions.md` A69a to A69h).
- **Protects:** Claude usage and Actions minutes.
- **What happened:** on 16 November 2026 two builds finished their work and lost it with the runner. Ticket #57: 16 minutes and $5.44, ended by an overloaded API on the last step; building it again took 21 minutes and $6.82. Ticket #67: 15 minutes and $6.13, ended by the engineer's own early stop.
- **Numbers:**
  - A session that is not cut short: one more step, which asks GitHub whether the work was handed over. Seconds, in a job that already runs, so no Actions minutes unless it tips the job over a minute boundary.
  - A wait is billed like any other minute of the job: 2 minutes for one continuation after an API error, 7 for two. That is the most a job can wait, and a ticket whose build and both reviews all waited the full time would use 21 minutes, about 1% of the month's 2,000.
  - A session the agent ended early is continued with no wait.
  - A fix round that pushes nothing on purpose, every finding rebutted, looks the same from outside as one that stopped early, so it is continued once: one resumed session that answers in a turn and changes nothing. It is not continued a second time (`decisions.md` A69g). Not measured yet: no round has been continued.
  - Against that, what a continuation saves is a build from nothing: about 16 Actions minutes and $5 to $7 on each of the two tickets above.
  - The job limits are unchanged (60 minutes for a build or a fix round, 20 for a review), so the waits and the continued runs can never add more than the job was already allowed.
  - Rejected, longer waits or more tries: every minute waited is billed while nothing runs, and Claude Code has already retried for about a minute before the session ends.
- **A build that still hands over no pull request now fails its job,** where one whose engineer ended the turn early used to pass. A failed `implement` run starts a retro (entry 11): 2 to 3 minutes and $1 to $2, for a failure that used to teach nothing.
- **Unfinished work that is kept:** when a build still hands over no pull request, its branch is pushed (`keep-work.sh`). Vercel builds a preview of any branch, so that is 1 of the 100 deployments a day, and its database branch holds one of Neon's 9 preview slots (entry 8) until the git branch is deleted: at the merge, once the next build has finished its pull request from it. A ticket that is dropped instead keeps the slot until its branch is deleted.
- **Automated:** yes.

### 14. A fix round is a workflow of its own, started by a job of one minute

- **Set:** the `fix` job left `ci.yml` for a workflow of its own, `fix.yml`. A `ci` run in which something failed starts it from a job, `start-fix`, that only runs `start-fix-round.sh` (ticket #89; `decisions.md` A89a to A89h).
- **Protects:** Claude usage and the owner's time, at the price of Actions minutes. As a job of `ci.yml`, a fix round in a run that was re-run, or was in flight when `ci.yml` changed on `main`, got no token for its engineer: on 16 November 2026 pull requests #86 and #87 each had rounds that ran five seconds, fixed nothing and were counted, and three conflicts were resolved by hand in an hour.
- **Numbers:**
  - A fix round after a failed check or review: 1 minute more than before, the `start-fix` job, which checks out `main` and makes two calls to GitHub. A round goes from about 6 billed minutes to about 7. Not measured yet: no round has run this way.
  - A fix round for a pull request a merge left in conflict: 1 minute less than before (entry 10).
  - A round with nothing to fix, asked for twice for one pull request: about 1 minute, the checkout and the look, and no engineer session (`decisions.md` A89e).
  - A round whose engineer session never begins is not counted against the three (`decisions.md` A89c), and fails its job, which starts a retro (entry 11): 2 to 3 minutes and $1 to $2.
  - Rejected, `fix.yml` starting itself when a `ci` run ends in failure: the same minute, spent on every failed run, a person's pull requests included, and nothing would start a round for a conflict, which has no run.
- **Automated:** yes.

### 15. Nothing runs on a draft pull request

- **Set:** the jobs in `ci.yml` that need no other (`checks`, `e2e` and `fits-main`) each carry the condition `github.event.pull_request.draft == false`, and every other job depends on them, so a run for a draft skips every job. Marking the pull request ready raises `ready_for_review`, already one of the workflow's triggers, and that run does everything (ticket #50; `decisions.md` A50c).
- **Protects:** Actions minutes, and Claude usage.
- **Why:** an engineer now opens the pull request as a draft when the build starts, so that the board shows the ticket in progress (`decisions.md` T50a). A draft holds an empty commit and a one-line description, so its checks would fail.
- **Numbers:** a skipped job is billed nothing, so a ticket stays at 9 minutes. Without the condition the draft's first push would run `checks` (1 minute, failing on the description), then `start-fix` (1 minute), which would ask for a fix round on a build still going: 2 minutes a ticket at the least, about 220 tickets a month becoming about 180. `start-fix-round.sh` refuses a draft as well (`decisions.md` A50b), for a draft checked by a `ci.yml` older than this entry.
- **Vercel and Neon:** the draft's empty first commit is one more push to the branch. Not measured yet: Vercel skips a commit that changes nothing it builds (`decisions.md` M33), and if it does not skip this one a ticket uses 3 of the 100 deployments a day instead of 2, about 33 tickets a day instead of 50. A preview that is built holds one of Neon's 9 preview slots (entry 8) from the start of the build instead of its end, 5 to 9 minutes longer.
- **Automated:** yes.

### 16. Three tickets in flight at most

- **Set:** `start-build.sh`, the first step of `implement.yml`, starts a build only when fewer than three other tickets are in flight: issues labelled `in-progress`, and open pull requests the factory opened, those waiting for the owner included (ticket #64; `decisions.md` T64a to T64f). Before, the rule was one ticket in flight, kept by the `promote` skill alone.
- **Protects:** Neon's 10 branches, Actions minutes and the Claude subscription's usage limits.
- **Numbers, database branches:** each open pull request holds one of the 9 preview slots (entry 8), so three in flight hold 3. That leaves 6 for pull requests merged since checks last ran, a person's own pull requests, and branches a cut-short build left (entry 13). At one in flight it was 1 of 9; with no limit, the ninth open pull request would take the last slot and the next preview would fail.
- **Numbers, Actions minutes for the re-checks:** worked out from entry 10's figures, not measured. A ticket that merges while nothing else is open stays at 9 minutes. With three in flight the first to merge moves `main` under the other two, and the second moves it under the third, so in the worst case two of the three are tested with `main` again: 2 minutes each when the pull request was waiting, 3 when its merge waited its turn behind another. Three tickets then cost 31 to 33 minutes, not 27: about 11 a ticket, and about 180 tickets a month where there were 220. A merge that leaves another pull request in conflict costs that one a fix round, about 7 minutes and $0.60 (entry 14); the `promote` skill tells the owner when two tickets are likely to edit the same lines.
- **Numbers, the check itself:** four reads from GitHub and one label change, a few seconds in a job that already runs, so no Actions minutes. A refused ticket ends its run in under a minute, billed as one, and starts no retro (`decisions.md` T64f).
  - Rejected, a job of its own holding one concurrency group, to settle two tickets labelled at the same moment: a billed minute on every ticket, 9 minutes becoming 10 (`decisions.md` T64d).
- **Claude usage:** not a figure the factory can read. Three builds at once draw on one subscription's limits three times as fast as one; a session the limit cuts short is not continued: its work is kept and its ticket flagged until the limit resets (entry 13; `decisions.md` A231b).
- **Automated:** yes.

## When to start paying

| Sign | Which limit | What to buy |
|---|---|---|
| More than about 220 tickets a month | Actions minutes | GitHub Actions minutes, or run fewer jobs per ticket |
| More than about 8 pull requests open at once | Neon branches | Neon's paid plan |
| More than about 50 tickets in a day | Vercel deployments | Vercel Pro |
| The product takes money | Vercel Hobby's terms | Vercel Pro |
