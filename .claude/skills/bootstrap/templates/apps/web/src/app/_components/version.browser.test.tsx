// @vitest-environment happy-dom
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { expect, it, vi } from "vitest";

import { Version } from "./version";

// An error boundary works only in a browser, so this renders as one does, where version.test.tsx
// renders as the server does.
it("keeps the rest of the page when the health cannot be read", async () => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  let refuse!: (reason: Error) => void;
  vi.stubGlobal("fetch", () => new Promise((_, reject) => (refuse = reject)));
  // No retry: the browser's cache would ask three more times, seconds apart, before it gave the failure.
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const page = document.body.appendChild(document.createElement("div"));
  await act(async () =>
    createRoot(page).render(
      <QueryClientProvider client={queryClient}>
        <h1>The waitlist</h1>
        <Suspense fallback="Reading the version">
          <Version />
        </Suspense>
      </QueryClientProvider>,
    ),
  );
  expect(page.textContent).toBe("The waitlistReading the version");

  await act(async () => refuse(new Error("The health route did not answer")));

  expect(page.textContent).toBe("The waitlist");
});
