### 7. `main` is guarded by the factory, not by GitHub

- **Set:** a git hook in agent jobs and the `guard-main` alarm, in place of a branch ruleset.
- **Protects:** the GitHub bill. Rulesets on a private repo need GitHub Pro at $4 a month.
- **Cost of the choice:** the hook stops mistakes, not a determined agent; the alarm catches the rest after the fact. `github.sh` sets the real ruleset whenever GitHub allows it.
- **Automated:** yes.
