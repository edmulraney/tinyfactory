import { defaultShouldDehydrateQuery, environmentManager, QueryClient } from "@tanstack/react-query";

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      // An answer the server read ahead is fresh when the page arrives, so the browser does not ask again at once.
      queries: { staleTime: 60_000 },
      dehydrate: {
        // A server component starts a read and does not wait for it, so the read is handed to the browser still pending.
        shouldDehydrateQuery: (query) => defaultShouldDehydrateQuery(query) || query.state.status === "pending",
        // Next.js reads its own errors to tell a dynamic page, and redacts what it shows the browser itself.
        shouldRedactErrors: () => false,
      },
    },
  });
}

let browserQueryClient: QueryClient | undefined;

/**
 * The cache that client components read data through. The server makes a new one for each call, so
 * no answer crosses from one request into another; the browser keeps one for as long as the page is
 * open, so an answer read once is not read again by the next component that asks.
 */
export function getQueryClient(): QueryClient {
  if (environmentManager.isServer()) return makeQueryClient();
  browserQueryClient ??= makeQueryClient();
  return browserQueryClient;
}
