import { afterEach, describe, expect, it, vi } from "vitest";
import { OutboundError, outboundFetch } from "./index";

// Like the real fetch: settles only when the caller's signal aborts it.
const never = (_url: unknown, init?: RequestInit) =>
  new Promise<Response>((_, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal?.reason)));

// Settled either way, so a test can advance the clock and then ask what happened.
const outcome = (call: Promise<Response>) => call.then(() => "answered", (error: unknown) => error);

describe("outboundFetch", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("hands back the service's answer, error status and all", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ message: "no such runner" }, { status: 404 })));
    const response = await outboundFetch("https://service.example/runners/1");
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ message: "no such runner" });
  });

  it("hands back an answer that has no body", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
    expect((await outboundFetch("https://service.example/runners/1")).status).toBe(204);
  });

  it("fails with an OutboundError when the request fails", async () => {
    const refused = new TypeError("fetch failed");
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(refused));
    const error = await outcome(outboundFetch("https://service.example/runners"));
    expect(error).toBeInstanceOf(OutboundError);
    expect(error).toMatchObject({ message: "The request to service.example failed", cause: refused });
  });

  it("fails with an OutboundError when the request to a relative URL fails", async () => {
    const refused = new TypeError("fetch failed");
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(refused));
    const error = await outcome(outboundFetch("/api/runners"));
    expect(error).toBeInstanceOf(OutboundError);
    expect(error).toMatchObject({ message: "The request to /api/runners failed", cause: refused });
  });

  it("fails with an OutboundError when the service has not answered within 5 seconds", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("fetch", vi.fn(never));
    const call = outcome(outboundFetch("https://service.example/runners"));
    await vi.advanceTimersByTimeAsync(4_999);
    await expect(Promise.race([call, "waiting"])).resolves.toBe("waiting");
    await vi.advanceTimersByTimeAsync(1);
    const error = await call;
    expect(error).toBeInstanceOf(OutboundError);
    expect(error).toMatchObject({ message: "No answer from service.example within 5000 ms" });
  });

  it("fails with an OutboundError when the answer's body stalls past the time limit", async () => {
    vi.useFakeTimers();
    const stalled = (_url: unknown, init?: RequestInit) => {
      const body = new ReadableStream({
        start: (controller) => init?.signal?.addEventListener("abort", () => controller.error(init.signal?.reason)),
      });
      return Promise.resolve(new Response(body));
    };
    vi.stubGlobal("fetch", vi.fn(stalled));
    const call = outcome(outboundFetch("https://service.example/runners"));
    await vi.advanceTimersByTimeAsync(5_000);
    expect(await call).toBeInstanceOf(OutboundError);
  });
});
