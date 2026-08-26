import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { deviceKey, hitRateLimit, KROGER_HOURLY_LIMIT } from "../src/ratelimit";

describe("hitRateLimit", () => {
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

  it("defaults to 60 calls per hour", () => {
    expect(KROGER_HOURLY_LIMIT).toBe(60);
  });
});

describe("deviceKey", () => {
  it("prefers X-Device-Id, then the connecting IP, then anonymous", () => {
    expect(deviceKey(new Request("https://x/", { headers: { "x-device-id": "abc" } }))).toBe("abc");
    expect(deviceKey(new Request("https://x/", { headers: { "cf-connecting-ip": "1.2.3.4" } }))).toBe("1.2.3.4");
    expect(deviceKey(new Request("https://x/"))).toBe("anonymous");
  });
});
