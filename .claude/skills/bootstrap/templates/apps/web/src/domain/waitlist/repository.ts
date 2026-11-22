import { db } from "@/db/client";
import { waitlistEntries } from "@/db/schema";

/** Answers whether the address was added: `false` for one already on the list. */
export async function insertEntry(email: string): Promise<boolean> {
  const added = await db().insert(waitlistEntries).values({ email }).onConflictDoNothing().returning({ email: waitlistEntries.email });
  return added.length > 0;
}
