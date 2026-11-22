import { db } from "@/db/client";
import { usageEvents } from "@/db/schema";

import type { UsageEvent } from "./types";

export async function insertUsageEvent(event: UsageEvent, accountId?: string): Promise<void> {
  await db().insert(usageEvents).values({ event, accountId });
}
