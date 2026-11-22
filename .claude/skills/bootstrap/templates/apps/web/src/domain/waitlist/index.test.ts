import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { recordUsage } from "@/domain/usage";

import { joinWaitlist } from "./index";
import { insertEntry } from "./repository";

vi.mock("./repository", () => ({ insertEntry: vi.fn() }));
vi.mock("@/domain/usage", () => ({ recordUsage: vi.fn() }));

describe("joinWaitlist", () => {
  beforeEach(() => {
    vi.mocked(insertEntry).mockResolvedValue(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.mocked(insertEntry).mockReset();
    vi.mocked(recordUsage).mockReset();
  });

  it("saves the address in lower case and without the spaces around it, and records that the visitor joined", async () => {
    expect(await joinWaitlist("  Ada@Example.COM ")).toEqual({ status: "joined" });
    expect(insertEntry).toHaveBeenCalledExactlyOnceWith("ada@example.com");
    expect(recordUsage).toHaveBeenCalledExactlyOnceWith("ada@example.com", "waitlist joined");
  });

  it("answers an address already on the list like a new one, and records nothing", async () => {
    vi.mocked(insertEntry).mockResolvedValue(false);
    expect(await joinWaitlist("ada@example.com")).toEqual({ status: "joined" });
    expect(recordUsage).not.toHaveBeenCalled();
  });

  it.each([
    ["nothing", undefined],
    ["a file", new Blob()],
    ["an empty field", ""],
    ["no @", "ada.example.com"],
    ["no dot after the @", "ada@example"],
    ["a space inside", "ada lovelace@example.com"],
    ["more than 254 characters", `${"a".repeat(243)}@example.com`],
  ])("refuses %s and saves nothing", async (_, posted) => {
    expect(await joinWaitlist(posted)).toEqual({ status: "invalid email" });
    expect(insertEntry).not.toHaveBeenCalled();
    expect(recordUsage).not.toHaveBeenCalled();
  });

  it("answers unavailable when the database cannot be reached, and logs why", async () => {
    vi.mocked(insertEntry).mockRejectedValueOnce(new Error("connect ECONNREFUSED"));
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await joinWaitlist("ada@example.com")).toEqual({ status: "unavailable" });
    expect(log).toHaveBeenCalledOnce();
    expect(recordUsage).not.toHaveBeenCalled();
  });
});
