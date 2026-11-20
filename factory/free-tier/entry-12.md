### 12. Screenshots are published from a job that already runs

- **Set:** two steps of the `verdicts` job in `ci.yml` fetch the end-to-end job's artifact and run `post-screenshots.sh`, which pushes the ticket's screenshots to the `sessions` branch and posts a comment, a new one for each push that passed (`decisions.md` [P98](../decisions/98.md); ticket #18). No job was added.
- **Protects:** Actions minutes. The end-to-end job cannot hold the token that writes the branch (`decisions.md` [P22](../decisions/18.md)), and a job of its own would be billed a whole minute on every push to a pull request: 9 minutes a ticket would become 10, and about 220 tickets a month about 200.
- **Numbers:** the artifact is 0.25 MB, and the script makes one clone of `sessions`, one push and two calls to GitHub. Whether that tips the `verdicts` job over a minute boundary shows in the job's billed time.
- **Storage:** nothing against the 500 MB of artifacts: the images go to the `sessions` branch, which GitHub does not meter but asks to keep under 1 GB with the rest of the repo. The two page screenshots measured on this repo (1280 by 720) were 12 KB and 60 KB, and only the ticket's own tests are kept (`decisions.md` [P20](../decisions/18.md)). At three page criteria a ticket and one fix round, about 0.25 MB a ticket: 200 tickets a month is about 50 MB a month.
- **Automated:** yes.
