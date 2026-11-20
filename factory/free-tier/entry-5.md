### 5. Reviewers run only after end-to-end tests pass

- **Set:** the `review` job needs `e2e`. This replaces the earlier setting, which no longer applies: the reviews needed `checks` as well, and now start beside it (ticket #250; [entry #250](250.md)).
- **Protects:** Claude usage and Actions minutes.
- **Numbers:** a pull request that fails its end-to-end tests skips both reviews: 2 minutes and about $0.54 of agent usage saved on each such round.
- **Automated:** yes.
