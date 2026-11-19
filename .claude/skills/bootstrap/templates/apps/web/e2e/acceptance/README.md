# Acceptance tests

One file per ticket, named `<issue-number>-<slug>.spec.ts` with the same slug as the ticket's branch
(`feat/12-not-found-page` → `12-not-found-page.spec.ts`), so this folder reads as a list of what
the product does. One test per acceptance criterion, titled with its id:

```ts
import { expect, test } from "../test";

test("AC1: a visitor sees the product name on the home page", async ({ page }) => { … });
```

Import from `../test`, not from `@playwright/test`: it adds an accessibility scan to every test
that opens a page.

The page a test leaves on screen is what its pull request shows for that criterion: CI posts the
screenshot taken at the end of each test, captioned with the test's title
(`factory/scripts/post-screenshots.sh`).

CI fails a pull request if any `AC<n>` in its ticket has no plain `test(…)` with that title prefix
(`test.skip`, `test.fixme`, `test.only`, `test.fail` and `test.describe` do not count), if anything
in the file is skipped, or if the file is misnamed (`factory/scripts/check-acceptance.sh`). Write
the test first and watch it fail.
