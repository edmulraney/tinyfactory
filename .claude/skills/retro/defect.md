# The retro of a defect met in use

The owner met a defect or a gap in the running product, which every check had passed. In the facts, `defect` holds its ticket and `fixed_by` the pull requests that closed it. In place of steps 2 and 3 of the `retro` skill:

1. **Read what they met:** `factory/scripts/thread.sh <n>`, and in the diff of each pull request in `fixed_by` the lines it removed from tests and decision records.
2. **Find the tickets and pull requests that let it through,** by building the behaviour or putting it out of scope. Grep `apps/web/e2e/acceptance/`, `product/decisions/` and `architecture/decisions/` for the behaviour: a file's name starts with its ticket's number. A ticket's pull request is the `/pull/<n>` that its build's transcripts name, in `.sessions/issue-<n>/`.
3. **Name the step that should have caught it,** the earliest of: the idea's slices, the ticket's scope and criteria, the engineer's tests, a review, a check, the owner's look at the visual proof. `cause` is why it did not.

`summary` names those tickets and that step. `cost.amount` is "1 ticket", the one that puts the defect right, with the figures of its cost comment once it has shipped; `saves` is the share of that ticket the step would have spared; `cost.kind` holds `stopped` (`factory/decisions.md` [A574c](../../../factory/decisions/574.md)). A defect no step could have caught is a `one-off` and proposes nothing.
