### 4. Card moves use no Actions minutes

- **Set:** GitHub's own project automations add and move the board's cards (ticket #20). This replaces the earlier setting, which no longer applies: workflows used to move the cards, as a step inside `implement.yml` and `ci.yml` so that only a new ticket's first card cost a run of its own.
- **Protects:** Actions minutes. A separate job costs a whole minute however short it is.
- **Numbers:** a ticket went from 10 minutes to 9, the new-ticket card run being gone: about 220 tickets a month instead of 200.
- **Automated:** partly. GitHub has no API to switch a board's automations on, so a new board is a copy of a template that has four on (`decisions.md` [S283a](../decisions/283.md)). `board.sh` prints the clicks for the rest and on later runs reads them back and confirms.
