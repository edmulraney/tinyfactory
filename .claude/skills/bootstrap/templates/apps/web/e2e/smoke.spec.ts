import { expect, test } from "./test";

// Proves the deployment serves the app at all. Feature behaviour belongs in e2e/acceptance.
// The factory relies on /api/health to confirm that a merge is live.
test("home page renders", async ({ page }) => {
  const response = await page.goto("/");
  expect(response?.ok()).toBe(true);
  await expect(page.locator("main")).toBeVisible();
});

test("health endpoint answers", async ({ request }) => {
  const response = await request.get("/api/health");
  expect(response.ok()).toBe(true);
  expect((await response.json()).status).toBe("ok");
});
