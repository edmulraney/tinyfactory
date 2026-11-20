### 1. Previews are kept for one day

- **Set:** Vercel project → Deployment Retention Policy → Canceled, Errored and Pre-Production deployments: 1 day. Production stays at 30 days.
- **Protects:** Neon's 10 branches.
- **Why:** each preview gets its own database branch ([entry 2](entry-2.md)), and Neon deletes that branch only when Vercel deletes the last deployment of the pull request's git branch. Vercel's default keeps previews for 30 days.
- **Numbers:** at 30 days, 9 preview branches means 9 pull requests a month; the tenth gets no database and its build fails. At 1 day the same 9 slots turn over daily: about 270 pull requests a month, 30 times more. That is still only 9 pull requests in any one day, which was not enough: see [entry 8](entry-8.md). This setting stays as the fallback for a branch [entry 8](entry-8.md) misses.
- **Errored and canceled too:** a preview that fails to build can still hold a database branch.
- **Production at 30 days:** rolling production back needs the old deployment to still exist. Further back than that, take the ticket back with the `revert` label (decisions [M19c](../decisions/19.md)).
- **Why not delete the preview at the moment of merge:** that needs a Vercel token in GitHub Actions, and the factory stores none (decisions [M9](../decisions/setup.md)): [entry 8](entry-8.md) frees the branch through Neon. At setup Vercel's CLI login could not create a token, and a token could not create another.
- **Automated:** no. Vercel's project API rejects the setting (`deploymentExpiration`: "should NOT have additional property"). `database.sh` opens the page, prints the four values, and on later runs reads them back and confirms.
