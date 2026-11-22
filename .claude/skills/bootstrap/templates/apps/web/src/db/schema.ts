import { pgTable, text, timestamp } from "drizzle-orm/pg-core";

// The address is the key, so the table cannot hold one address twice.
export const waitlistEntries = pgTable("waitlist_entries", {
  email: text("email").primaryKey(),
  joinedAt: timestamp("joined_at", { withTimezone: true }).defaultNow().notNull(),
});

// One row each time a user does something the product counts (ARCHITECTURE.md, "Usage"). It has no
// key: a user does the same thing many times, and nothing names one row. `account_id` is empty for
// an event recorded with no account.
export const usageEvents = pgTable("usage_events", {
  accountId: text("account_id"),
  event: text("event").notNull(),
  occurredAt: timestamp("occurred_at", { withTimezone: true }).defaultNow().notNull(),
});
