import { dehydrate, HydrationBoundary } from "@tanstack/react-query";
import { connection } from "next/server";

import { getQueryClient } from "@/lib/query";

import { healthQuery } from "./health-query";
import { Version } from "./version";

/** Reads the health on the server for each visit and hands it to `Version` in the browser. */
export async function PrefetchedVersion() {
  // The running deployment's, not the build's.
  await connection();
  const queryClient = getQueryClient();
  await queryClient.prefetchQuery(healthQuery);
  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Version />
    </HydrationBoundary>
  );
}
