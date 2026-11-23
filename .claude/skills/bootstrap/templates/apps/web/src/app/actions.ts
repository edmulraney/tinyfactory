"use server";

import { joinWaitlist, type JoinResult } from "@/domain/waitlist";

export async function join(_previous: JoinResult | null, form: FormData): Promise<JoinResult> {
  return joinWaitlist(form.get("email"));
}
