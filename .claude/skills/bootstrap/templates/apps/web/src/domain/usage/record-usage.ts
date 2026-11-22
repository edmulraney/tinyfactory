import { insertUsageEvent } from "./repository";
import type { UsageEvent } from "./types";

/**
 * Records that `event` happened now. Call it where the event happens, once it has happened.
 * `accountId` is the id of the account that did it; leave it out for a visitor with no account.
 */
export async function recordUsage(event: UsageEvent, accountId?: string): Promise<void> {
  try {
    await insertUsageEvent(event, accountId);
  } catch (cause) {
    // What the user did has happened, and must not fail because counting it did.
    console.error(`The usage event "${event}" could not be recorded`, cause);
  }
}
