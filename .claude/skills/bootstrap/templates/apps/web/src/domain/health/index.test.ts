import { afterEach, describe, expect, it, vi } from "vitest";
import { getHealth } from "./index";

const sha = "0123456789abcdef0123456789abcdef01234567";

describe("getHealth", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("reports the commit the platform deployed", async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", sha);
    expect(await getHealth()).toEqual({ status: "ok", commit: sha });
  });

  it("reports an unknown commit when the platform provides none", async () => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", undefined);
    expect(await getHealth()).toEqual({ status: "ok", commit: "unknown" });
  });

  it.each([
    ["empty", ""],
    ["abbreviated", sha.slice(0, 7)],
    ["uppercase", sha.toUpperCase()],
    ["padded", `${sha}\n`],
  ])("reports an unknown commit when the platform's value is %s", async (_, value) => {
    vi.stubEnv("VERCEL_GIT_COMMIT_SHA", value);
    expect((await getHealth()).commit).toBe("unknown");
  });
});
