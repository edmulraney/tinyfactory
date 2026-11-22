import { afterEach, describe, expect, it, vi } from "vitest";

import { recordUsage } from "./index";
import { insertUsageEvent } from "./repository";

vi.mock("./repository", () => ({ insertUsageEvent: vi.fn() }));

describe("recordUsage", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.mocked(insertUsageEvent).mockReset();
  });

  it("keeps the event and the account that did it", async () => {
    await recordUsage("waitlist joined", "account-1");
    expect(insertUsageEvent).toHaveBeenCalledExactlyOnceWith("waitlist joined", "account-1");
  });

  it("does not fail what the user did when the database cannot be reached, and logs why", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(insertUsageEvent).mockRejectedValue(new Error("connect ECONNREFUSED"));
    await expect(recordUsage("waitlist joined")).resolves.toBeUndefined();
    expect(log).toHaveBeenCalledOnce();
  });
});
