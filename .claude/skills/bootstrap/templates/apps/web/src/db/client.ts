import { neonConfig } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
import { outboundFetch } from "@/lib/outbound";

// Each query is one HTTPS request, and the driver takes its fetch only as a global setting.
neonConfig.fetchFunction = outboundFetch;

// Built per call, not once per module: the HTTP driver holds no connection, and a build or a
// local run with no DATABASE_URL must still be able to import the queries.
export function db() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  return drizzle(url);
}
