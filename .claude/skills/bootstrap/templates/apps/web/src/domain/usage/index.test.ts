import { afterEach, describe, expect, it, vi } from "vitest";

import { recordUsage } from "./index";
import { insertUsageEvent } from "./repository";

vi.mock("./repository", () => ({ insertUsageEvent: vi.fn() }));

describe("recordUsage", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.mocked(insertUsageEvent).mockReset();
  });

  it("keeps who did it and the event", async () => {
    await recordUsage("ada@example.com", "waitlist joined");
    expect(insertUsageEvent).toHaveBeenCalledExactlyOnceWith("ada@example.com", "waitlist joined");
  });

  it("does not fail what the user did when the database cannot be reached, and logs why", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(insertUsageEvent).mockRejectedValue(new Error("connect ECONNREFUSED"));
    await expect(recordUsage("ada@example.com", "waitlist joined")).resolves.toBeUndefined();
    expect(log).toHaveBeenCalledOnce();
  });
});
