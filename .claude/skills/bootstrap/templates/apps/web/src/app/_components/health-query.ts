import { queryOptions } from "@tanstack/react-query";

import { readHealth } from "../actions";

/** `PrefetchedVersion` reads the health ahead on the server with these, and `Version` reads it in the browser with the same. */
export const healthQuery = queryOptions({ queryKey: ["health"], queryFn: () => readHealth() });
