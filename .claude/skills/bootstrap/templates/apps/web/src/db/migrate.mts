import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/neon-http";
import { migrate } from "drizzle-orm/neon-http/migrator";
import journal from "./migrations/meta/_journal.json" with { type: "json" };

// Run by `pnpm build`, before the app is built (ARCHITECTURE.md, "Database"). A failed migration
// throws, which fails the build, so no deployment runs on a schema it was not written for.
const url = process.env.DATABASE_URL;
if (url) {
  const db = drizzle(url);
  await migrate(db, { migrationsFolder: "src/db/migrations" });

  // Drizzle's migrator runs only a migration dated after the newest one the database has had, and
  // skips an older one without a word. One generated earlier but merged later is such a migration.
  const { rows } = await db.execute(sql`select created_at from drizzle.__drizzle_migrations`);
  const applied = new Set(rows.map((row) => Number(row.created_at)));
  const skipped = journal.entries.filter((entry) => !applied.has(entry.when)).map((entry) => entry.tag);
  if (skipped.length > 0) {
    throw new Error(
      `Drizzle skipped ${skipped.join(", ")}: the database has had a migration generated later. ` +
        "Generate each again, so that it is the newest (ARCHITECTURE.md, \"Database\").",
    );
  }
  console.log("Migrations in src/db/migrations are applied.");
} else {
  console.log("DATABASE_URL is not set, so no migration ran.");
}
