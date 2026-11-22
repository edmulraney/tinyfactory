import { recordUsage } from "@/domain/usage";

import { insertEntry } from "./repository";
import type { JoinResult } from "./types";

// The longest address a mail server accepts.
const LONGEST_EMAIL = 254;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function joinWaitlist(email: unknown): Promise<JoinResult> {
  // What arrives was posted to a server action, so it may be anything.
  if (typeof email !== "string") return { status: "invalid email" };
  const address = email.trim().toLowerCase();
  if (address.length > LONGEST_EMAIL || !EMAIL.test(address)) return { status: "invalid email" };
  try {
    // An address already on the list is answered like a new one, so the answer tells nobody who is on it.
    if (await insertEntry(address)) await recordUsage(address, "waitlist joined");
    return { status: "joined" };
  } catch (cause) {
    // The visitor is told only that it was not saved; the log says why.
    console.error("The waitlist entry could not be saved", cause);
    return { status: "unavailable" };
  }
}
