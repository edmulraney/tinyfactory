import { QueryClientProvider } from "@tanstack/react-query";
import { Suspense } from "react";
import { prerender } from "react-dom/static";
import { describe, expect, it, vi } from "vitest";

import { getHealth } from "@/domain/health";
import { getQueryClient } from "@/lib/query";

import { PrefetchedVersion } from "./prefetched-version";

vi.mock("next/server", () => ({ connection: async () => {} }));
vi.mock("@/domain/health", () => ({ getHealth: vi.fn() }));

// The server component starts the read and hands it over still pending; the page, rendered to the end
// as the browser receives it, shows what the read answered.
async function renderWithCommit(commit: string) {
  let answer!: (health: { status: "ok"; commit: string }) => void;
  vi.mocked(getHealth).mockReturnValue(new Promise((resolve) => (answer = resolve)));
  const page = prerender(
    <QueryClientProvider client={getQueryClient()}>
      <Suspense>{await PrefetchedVersion()}</Suspense>
    </QueryClientProvider>,
  );
  answer({ status: "ok", commit });
  return new Response((await page).prelude).text();
}

describe("Version", () => {
  it("shows the short commit the server read", async () => {
    expect(await renderWithCommit("0123456789abcdef0123456789abcdef01234567")).toContain("Version 0123456");
  });

  it("shows nothing where the platform gives no commit", async () => {
    expect(await renderWithCommit("unknown")).not.toContain("Version");
  });
});
