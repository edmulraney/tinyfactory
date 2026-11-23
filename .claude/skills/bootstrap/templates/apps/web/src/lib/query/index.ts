import { isServer, QueryClient } from "@tanstack/react-query";

function makeQueryClient() {
  // An answer the server read ahead is fresh when the page arrives, so the browser does not ask again at once.
  return new QueryClient({ defaultOptions: { queries: { staleTime: 60_000 } } });
}

let browserQueryClient: QueryClient | undefined;

/**
 * The cache that client components read data through. The server makes a new one for each call, so
 * no answer crosses from one request into another; the browser keeps one for as long as the page is
 * open, so an answer read once is not read again by the next component that asks.
 */
export function getQueryClient(): QueryClient {
  if (isServer) return makeQueryClient();
  browserQueryClient ??= makeQueryClient();
  return browserQueryClient;
}
