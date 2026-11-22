import { insertUsageEvent } from "./repository";
import type { UsageEvent } from "./types";

/**
 * Records that the user did `event` now. Call it where the event happens, once it has happened.
 * `accountId` is whatever tells one user from another: an account's id, or the address of a visitor
 * who has no account.
 */
export async function recordUsage(accountId: string, event: UsageEvent): Promise<void> {
  try {
    await insertUsageEvent(accountId, event);
  } catch (cause) {
    // What the user did has happened, and must not fail because counting it did.
    console.error(`The usage event "${event}" could not be recorded`, cause);
  }
}
