## The limits

Figures are the providers' published free-plan limits on 2026-11-14. "Per ticket" is measured on this repo (ticket #12, a small change with no fix round).

| Service and plan | Limit | Used by | Per ticket | Ceiling |
|---|---|---|---|---|
| GitHub Actions, Free, private repo | 2,000 minutes a month. Every job rounds up to a whole minute | Every workflow job | 9 minutes: build 4, five CI jobs 5. Merging adds 2, and a test of the group when several wait or `main` moved ([entry #455](455.md)) | About 220 tickets a month at 9 minutes each. Measured over 171 tickets from 14 to 18 November 2026: 51 minutes a ticket, so about 39 a month ([entry #388](388.md)) |
| GitHub Actions, Free, public repo | No limit on minutes ([entry #385](385.md)) | Every workflow job | The same jobs, counted against nothing | Not a constraint |
| GitHub artifact storage, Free | 500 MB | Playwright report (0.25 MB, kept 30 days); three transcripts (0.05 MB together, kept 90 days) | 0.3 MB | Not a constraint: 200 tickets is about 60 MB |
| Vercel, Hobby | 100 deployments a day, one building at a time, 45 minutes per build | One preview per push to a pull request, one production deploy per merge; none for a change to the factory's own folders alone ([entry #165](165.md)) | 2, plus 1 per fix round; none for the draft's first commit ([entry 15](entry-15.md)). A ticket that changes only the factory's folders: 0 | About 50 tickets a day that change the app |
| Neon, Free | 10 branches per project including production, so 9 for previews. 1 GB storage, 100 compute-hours a month, compute sleeps after 5 idle minutes | One branch per pull request, held from a build of the app until its end-to-end tests pass ([entry #672](672.md)) | 1 branch while a build is tested or fails, or while a draft is built | 9 between the pull requests being tested, failing or drafted at once and those closed in the last six hours ([entry #672](672.md)); the factory's own can ask for 10 ([entry #481](481.md)) |
| Vercel Web Analytics, Hobby | 50,000 page views a month, shared by every project of the account, then collection pauses; no custom events (read 2026-11-22, [entry #644](644.md)) | Each page a visitor opens, through the layout's `Analytics` component | None | About 1,600 page views a day across the account's projects |
| Neon Auth, Free | 60,000 monthly active users per project (read 2026-11-17) | Sign-in, for a product with accounts (`sign-in.sh`) | None | Not a constraint: an idea with 60,000 people signing in each month is proven |
| Claude subscription | The plan's usage limits. The one part that is not free | Esme, Adam, Ryan | About $1 at API prices | Depends on the plan |

**What binds first:** in a private repo, Actions minutes, at about 220 small tickets a month that each pass first time, and at about 39 as tickets were measured ([entry #388](388.md)); in a public one, Neon's branches ([entry #385](385.md)). Before the settings below, Neon's branch limit would have stopped the factory at the tenth pull request of the month.

**A limit that is not a number:** Vercel's Hobby plan is for personal, non-commercial use. A product that starts charging needs Vercel Pro, whatever its traffic.
