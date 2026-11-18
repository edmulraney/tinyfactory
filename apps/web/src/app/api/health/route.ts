import { connection } from "next/server";
import { getHealth } from "@/server/health";

export async function GET() {
  // Answer at request time: a prerendered response would report the build, not the running deployment.
  await connection();
  return Response.json(await getHealth(), { headers: { "Cache-Control": "no-store" } });
}
