---
name: publicize-repo
description: Make the project's GitHub repository public, with secret scanning, push protection, approval of outside contributors' runs, private vulnerability reporting and pinned actions. Use when the owner asks to make the repository public or to open-source it.
---

# Publicize the repo

A public repository shows anyone every ticket, every decision, every workflow log and every agent transcript on the `sessions` branch, and lets anyone open an issue or a pull request. Setup keeps every repository private (`factory/decisions.md` [S3](../../../factory/decisions/setup.md)). `factory/scripts/publicize-repo.sh` is the only way the factory makes one public ([S385a](../../../factory/decisions/385.md)).

1. **Only on the owner's word, given in this session.** Run it with the owner's own `gh` login, which holds the admin rights that no workflow token holds. Going public cannot be taken back: a fork or a copy made while the repository is public stays.
2. **Run `factory/scripts/publicize-repo.sh`.** It refuses, and changes nothing, while an action is not pinned by its commit id, a transcript is published without the token scrub, or a token from before the scrub would become readable. Then tell the owner what it listed. File a `factory` ticket for each fix to a script or workflow (the `ticket` skill), and never edit one yourself. Revoking a token and deleting the `sessions` branch's history or an artifact are the owner's calls, as neither can be undone.
3. **Show the owner the settings it prints.** It sets only what differs, then reads each setting back. When it fails it names the setting; run it again.
