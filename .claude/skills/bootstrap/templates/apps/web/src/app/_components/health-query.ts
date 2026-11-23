import { queryOptions } from "@tanstack/react-query";

import type { Health } from "@/domain/health";

/** `Version` reads the health in the browser with these, and `PrefetchedVersion` starts the same query on the server. */
export const healthQuery = queryOptions({
  queryKey: ["health"],
  // Through a route handler (decisions S669a).
  queryFn: async (): Promise<Health> => {
    const response = await fetch("/api/health");
    if (!response.ok) throw new Error(`The health route answered ${response.status}`);
    return (await response.json()) as Health;
  },
});
