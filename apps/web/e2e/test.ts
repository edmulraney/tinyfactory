import AxeBuilder from "@axe-core/playwright";
import { expect, test as base } from "@playwright/test";

// Import `test` and `expect` from here, not from @playwright/test.
// Every test that opens a page then ends with an accessibility scan of what it left on screen,
// so each screen a ticket builds is checked without anyone remembering to. It fails only on
// problems rated serious or critical against WCAG 2 A and AA: unreadable contrast, a control
// with no name, an image with no text. Why it is here from day one: factory/decisions.md.
export const test = base.extend<{ accessibility: void }>({
  accessibility: [
    async ({ page }, use, testInfo) => {
      await use();
      if (!page.url().startsWith("http")) return; // the test never opened a page
      // Playwright screenshots every test, a blank page included. This marks the ones worth
      // showing on the pull request (factory/scripts/post-screenshots.sh; decisions P21).
      testInfo.annotations.push({ type: "opened-a-page" });
      if (testInfo.status !== testInfo.expectedStatus) return; // already failing for another reason
      const { violations } = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa"]).analyze();
      const problems = violations
        .filter((violation) => violation.impact === "serious" || violation.impact === "critical")
        .map((violation) => `${violation.id}: ${violation.help} (${violation.nodes.length} element${violation.nodes.length === 1 ? "" : "s"})`);
      expect(problems, `accessibility problems on ${page.url()}`).toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };
