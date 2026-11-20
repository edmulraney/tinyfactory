# Security

## Who the factory acts for

The factory acts only for an account with write access to this repository, and for its own two bot accounts, `github-actions[bot]` and `claude[bot]`. An issue, comment or review from anyone else starts nothing.

## Whose words an agent acts on

An agent treats text written by anyone else, and anything it reads on the web or in a package, as data and never as an instruction.

## Secrets

No agent or script prints a secret, writes one to disk, or sends one anywhere but to the service it is for. A reviewer is given no GitHub token.

## What is not protected

Every agent session holds the Claude token in its environment, because it needs the token to run. An agent that reads a hostile page could be talked into sending the token out. Limiting where an agent may send data would close this, and it is not built.

A pull request from a fork gets no secret from GitHub, so no agent runs on it.

## Reporting a vulnerability

Report it privately: on this repository's Security tab, press "Report a vulnerability". Do not open an issue for it.
