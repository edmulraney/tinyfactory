import { afterEach, describe, expect, it, vi } from "vitest";
import { joinWaitlist } from "./index";
import { insertEntry } from "./repository";

vi.mock("./repository", () => ({ insertEntry: vi.fn() }));

describe("joinWaitlist", () => {
  afterEach(() => vi.restoreAllMocks());

  it("saves the address in lower case and without the spaces around it", async () => {
    expect(await joinWaitlist("  Ada@Example.COM ")).toEqual({ status: "joined" });
    expect(insertEntry).toHaveBeenCalledExactlyOnceWith("ada@example.com");
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
    vi.mocked(insertEntry).mockClear();
    expect(await joinWaitlist(posted)).toEqual({ status: "invalid email" });
    expect(insertEntry).not.toHaveBeenCalled();
  });

  it("answers unavailable when the database cannot be reached, and logs why", async () => {
    vi.mocked(insertEntry).mockRejectedValueOnce(new Error("connect ECONNREFUSED"));
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(await joinWaitlist("ada@example.com")).toEqual({ status: "unavailable" });
    expect(log).toHaveBeenCalledOnce();
  });
});
