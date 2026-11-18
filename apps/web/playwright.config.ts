import { defineConfig, devices } from "@playwright/test";

// With BASE_URL set (CI, against a Vercel preview) the tests hit that deployment.
// Without it they build and start the app locally.
const baseURL = process.env.BASE_URL ?? "http://localhost:3000";
// Vercel previews sit behind a login; this header lets automation through.
const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;

export default defineConfig({
  testDir: "./e2e",
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  // The JSON report is what factory/scripts/post-screenshots.sh reads: each test's title, and
  // where its screenshot is (decisions P19).
  reporter: [["list"], ["html", { open: "never" }], ["json", { outputFile: "test-results/results.json" }]],
  use: {
    baseURL,
    screenshot: "on",
    trace: "retain-on-failure",
    extraHTTPHeaders: bypass ? { "x-vercel-protection-bypass": bypass } : undefined,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: process.env.BASE_URL
    ? undefined
    : {
        command: "pnpm build && pnpm start",
        url: baseURL,
        reuseExistingServer: !process.env.CI,
        timeout: 180_000,
      },
});
