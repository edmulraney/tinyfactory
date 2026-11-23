import { dehydrate, HydrationBoundary, QueryClientProvider } from "@tanstack/react-query";
import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

import { getQueryClient } from "@/lib/query";

import { readHealth } from "../actions";
import { healthQuery } from "./health-query";
import { Version } from "./version";

vi.mock("../actions", () => ({ readHealth: vi.fn() }));

// As `PrefetchedVersion` does: the health is read on the server and handed to the browser, which renders it from the cache.
async function renderWithCommit(commit: string) {
  vi.mocked(readHealth).mockResolvedValue({ status: "ok", commit });
  const server = getQueryClient();
  await server.prefetchQuery(healthQuery);
  return renderToString(
    <QueryClientProvider client={getQueryClient()}>
      <HydrationBoundary state={dehydrate(server)}>
        <Version />
      </HydrationBoundary>
    </QueryClientProvider>,
  );
}

describe("Version", () => {
  it("shows the short commit the server read", async () => {
    expect(await renderWithCommit("0123456789abcdef0123456789abcdef01234567")).toContain("Version 0123456");
  });

  it("shows nothing where the platform gives no commit", async () => {
    expect(await renderWithCommit("unknown")).toBe("");
  });
});
