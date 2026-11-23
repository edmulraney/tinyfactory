import { dehydrate, HydrationBoundary, noop } from "@tanstack/react-query";
import { connection } from "next/server";

import { getHealth } from "@/domain/health";
import { getQueryClient } from "@/lib/query";

import { healthQuery } from "./health-query";
import { Version } from "./version";

/** Starts reading the health on the server for each visit, and hands the read to `Version` in the browser while it runs. */
export async function PrefetchedVersion() {
  // The running deployment's, not the build's.
  await connection();
  const queryClient = getQueryClient();
  // Not awaited: the page streams on, and the pending read is handed over. The server reads the
  // domain itself (decisions S688b).
  void queryClient.query({ ...healthQuery, queryFn: getHealth }).catch(noop);
  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Version />
    </HydrationBoundary>
  );
}
