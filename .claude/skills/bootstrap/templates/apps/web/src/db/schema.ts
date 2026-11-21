import { pgTable, text, timestamp } from "drizzle-orm/pg-core";

// The address is the key, so the table cannot hold one address twice.
export const waitlistEntries = pgTable("waitlist_entries", {
  email: text("email").primaryKey(),
  joinedAt: timestamp("joined_at", { withTimezone: true }).defaultNow().notNull(),
});
