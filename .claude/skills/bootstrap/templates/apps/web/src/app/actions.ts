"use server";

import { getHealth, type Health } from "@/domain/health";
import { joinWaitlist, type JoinResult } from "@/domain/waitlist";

export async function join(_previous: JoinResult | null, form: FormData): Promise<JoinResult> {
  return joinWaitlist(form.get("email"));
}

export async function readHealth(): Promise<Health> {
  return getHealth();
}
