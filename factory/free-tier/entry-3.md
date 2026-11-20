### 3. The transcript branch is never deployed

- **Set:** the `sessions` branch carries `apps/web/vercel.json` with `git.deploymentEnabled: false`.
- **Protects:** Vercel's 100 deployments a day.
- **Why:** Vercel tries to build every branch pushed to the repo. Each saved transcript was a failed deployment: three per ticket (Esme, Adam, Ryan), plus one per fix round.
- **Numbers:** 5 deployments per ticket became 2, so the daily ceiling went from 20 tickets to 50. It also stops that branch claiming one of Neon's 9 preview slots.
- **Automated:** yes. `sessions-branch.sh`, through which every write to the branch goes (`decisions.md` [A98](../decisions/98.md)), writes the file whenever it is missing. An "ignored build step" on the project does not work: Vercel fails on the missing app folder first.
