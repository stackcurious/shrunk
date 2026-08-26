import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { deviceKey, hitRateLimit, KROGER_HOURLY_LIMIT } from "../src/ratelimit";

describe("hitRateLimit", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("counts up to the limit then refuses", async () => {
    const device = `dev-${crypto.randomUUID()}`;
    for (let i = 1; i <= 3; i++) {
      expect(await hitRateLimit(env.KV, device, 3)).toEqual({ allowed: true, count: i });
    }
    expect(await hitRateLimit(env.KV, device, 3)).toEqual({ allowed: false, count: 3 });
  });

  it("counts each device separately", async () => {
    const a = `dev-${crypto.randomUUID()}`;
    const b = `dev-${crypto.randomUUID()}`;
    await hitRateLimit(env.KV, a, 1);
    expect(await hitRateLimit(env.KV, a, 1)).toMatchObject({ allowed: false });
    expect(await hitRateLimit(env.KV, b, 1)).toMatchObject({ allowed: true });
  });

  it("resets counter on hour boundary", async () => {
    vi.useFakeTimers();
    const start = new Date("2026-08-26T12:00:00Z").getTime();
    vi.setSystemTime(start);

    const device = "dev-x";
    expect(await hitRateLimit(env.KV, device, 2)).toEqual({ allowed: true, count: 1 });
    expect(await hitRateLimit(env.KV, device, 2)).toEqual({ allowed: true, count: 2 });
    expect(await hitRateLimit(env.KV, device, 2)).toEqual({ allowed: false, count: 2 });

    vi.setSystemTime(start + 3_600_000);
    expect(await hitRateLimit(env.KV, device, 2)).toEqual({ allowed: true, count: 1 });

    vi.useRealTimers();
  });

  it("defaults to 60 calls per hour", () => {
    expect(KROGER_HOURLY_LIMIT).toBe(60);
  });

  it("keeps a separate bucket per purpose for the same device", async () => {
    // I4: /v1/observations reuses this limiter with its own purpose so a
    // device's Kroger proxy calls and its crowd submissions don't share one
    // counter — otherwise each feature would silently steal the other's quota.
    const device = `dev-${crypto.randomUUID()}`;
    expect(await hitRateLimit(env.KV, device, 1, "kroger")).toEqual({ allowed: true, count: 1 });
    expect(await hitRateLimit(env.KV, device, 1, "observations")).toEqual({ allowed: true, count: 1 });
    expect(await hitRateLimit(env.KV, device, 1, "kroger")).toEqual({ allowed: false, count: 1 });
    expect(await hitRateLimit(env.KV, device, 1, "observations")).toEqual({ allowed: false, count: 1 });
  });

  it("defaults to the kroger purpose bucket when none is given", async () => {
    const device = `dev-${crypto.randomUUID()}`;
    await hitRateLimit(env.KV, device, 1);
    expect(await hitRateLimit(env.KV, device, 1, "kroger")).toEqual({ allowed: false, count: 1 });
  });
});

describe("deviceKey", () => {
  it("prefers X-Device-Id, then the connecting IP, then anonymous", () => {
    expect(deviceKey(new Request("https://x/", { headers: { "x-device-id": "abc" } }))).toBe("abc");
    expect(deviceKey(new Request("https://x/", { headers: { "cf-connecting-ip": "1.2.3.4" } }))).toBe("1.2.3.4");
    expect(deviceKey(new Request("https://x/"))).toBe("anonymous");
  });
});
