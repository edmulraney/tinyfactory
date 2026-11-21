import { db } from "@/db/client";
import { waitlistEntries } from "@/db/schema";

export async function insertEntry(email: string): Promise<void> {
  await db().insert(waitlistEntries).values({ email }).onConflictDoNothing();
}
