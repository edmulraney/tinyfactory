import { expect, test } from "../test";

// A deployment (BASE_URL, as CI sets it to the preview) has a database; a local run has none.
const saved = process.env.BASE_URL
  ? "You are on the list. We will email you when it opens."
  : "We could not save your address just now. Try again in a moment.";

test("AC1: a visitor who leaves an email address is told they are on the list", async ({ page }, testInfo) => {
  await page.goto("/");
  await page.getByLabel("Email").fill(`visitor-${testInfo.project.name}-${Date.now()}@example.com`);
  await page.getByRole("button", { name: "Tell me when it opens" }).click();
  await expect(page.getByText(saved)).toBeVisible();
});

test("AC2: a visitor who leaves something that is no email address is asked for one", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("Email").fill("not an address");
  await page.getByRole("button", { name: "Tell me when it opens" }).click();
  await expect(page.getByText("Enter an email address, such as name@example.com.")).toBeVisible();
  await expect(page.getByLabel("Email")).toBeVisible();
});
