import { afterEach, expect, it, vi } from "vitest";
import journal from "./migrations/meta/_journal.json";

// The database stops here: a unit test has none. Drizzle's migrator is stood in for, and the
// script reads back the migrations the database says it has had.
const execute = vi.hoisted(() => vi.fn());
vi.mock("drizzle-orm/neon-http", () => ({ drizzle: () => ({ execute }) }));
vi.mock("drizzle-orm/neon-http/migrator", () => ({ migrate: async () => {} }));

const runScript = () => {
  vi.resetModules();
  vi.stubEnv("DATABASE_URL", "postgres://database.example/app");
  return import("./migrate.mjs");
};

afterEach(() => vi.unstubAllEnvs());

it("passes when the database has had every migration in the journal", async () => {
  // Postgres answers a bigint as text.
  execute.mockResolvedValue({ rows: journal.entries.map((entry) => ({ created_at: String(entry.when) })) });
  await expect(runScript()).resolves.toBeDefined();
});

it("fails the build, naming the migration, when Drizzle skipped one as older than the newest applied", async () => {
  const [skipped] = journal.entries;
  execute.mockResolvedValue({ rows: [{ created_at: String(skipped.when + 1) }] });
  await expect(runScript()).rejects.toThrow(skipped.tag);
});
