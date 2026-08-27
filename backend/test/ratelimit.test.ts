import { env } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hitRateLimit, isValidDeviceId, KROGER_GLOBAL_HOURLY_LIMIT, KROGER_HOURLY_LIMIT } from "../src/ratelimit";

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

  it("I4: the global Kroger budget is 400 per hour", () => {
    expect(KROGER_GLOBAL_HOURLY_LIMIT).toBe(400);
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

describe("isValidDeviceId", () => {
  it("accepts a UUID in either case, matching Swift's UUID().uuidString and crypto.randomUUID()", () => {
    expect(isValidDeviceId("e5a4f8b2-1234-4321-abcd-1234567890ab")).toBe(true);
    expect(isValidDeviceId("E5A4F8B2-1234-4321-ABCD-1234567890AB")).toBe(true);
    expect(isValidDeviceId(crypto.randomUUID())).toBe(true);
  });

  it("rejects anything not shaped exactly like a UUID (I4 / T5)", () => {
    expect(isValidDeviceId("")).toBe(false);
    expect(isValidDeviceId("dev-e5a4f8b2-1234-4321-abcd-1234567890ab")).toBe(false); // prefixed
    expect(isValidDeviceId("e5a4f8b2123443214321abcd1234567890ab")).toBe(false); // no dashes
    expect(isValidDeviceId("not-a-uuid")).toBe(false);
    expect(isValidDeviceId("1.2.3.4")).toBe(false); // an IP must not be accepted as identity
    expect(isValidDeviceId("x".repeat(600))).toBe(false); // T5: an oversized id must not reach KV at all
  });
});
