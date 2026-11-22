import { db } from "@/db/client";
import { usageEvents } from "@/db/schema";

import type { UsageEvent } from "./types";

export async function insertUsageEvent(accountId: string, event: UsageEvent): Promise<void> {
  await db().insert(usageEvents).values({ accountId, event });
}
