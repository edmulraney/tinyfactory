import { defineConfig } from "drizzle-kit";

// For `pnpm db:generate`, which writes a migration from a change to the schema and connects to
// nothing. Migrations are run by `src/db/migrate.mts` (ARCHITECTURE.md, "Database").
export default defineConfig({ dialect: "postgresql", schema: "./src/db/schema.ts", out: "./src/db/migrations" });
