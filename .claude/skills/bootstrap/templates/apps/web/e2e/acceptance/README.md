# Acceptance tests

A ticket's tests are in `<issue-number>-<slug>.spec.ts`, the slug naming the outcome
(`12-not-found-page.spec.ts`), so this folder reads as a list of what the product does. One test per acceptance criterion, titled with its id:

```ts
import { expect, test } from "../test";

test("AC1: a visitor sees the product name on the home page", async ({ page }) => { … });
```

Import from `../test`, not from `@playwright/test`: every test that opens a page then ends with an
accessibility scan, and fails when the page scrolls sideways.

Every test runs twice, at the two screens the app supports (`DESIGN.md`, "Supported screens"): the
`mobile` project is 375px wide and the `desktop` project 1280px (`playwright.config.ts`). So no test
sets a width, and no ticket needs a criterion for one.

The page a test leaves on screen is what its pull request shows for that criterion: CI posts the
screenshot taken at the end of each test, captioned with the test's title
(`factory/scripts/post-screenshots.sh`).

CI fails a pull request if any `AC<n>` in its ticket has no plain `test(…)` with that title prefix
(`test.skip`, `test.fixme`, `test.only`, `test.fail` and `test.describe` do not count), if anything
in the ticket's files is skipped (`factory/scripts/check-acceptance.sh`). Write
the test first and watch it fail.
