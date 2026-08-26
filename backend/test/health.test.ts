import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import app from "../src/index";

describe("GET /health", () => {
  it("returns ok and the migrated tables exist", async () => {
    const res = await app.request("/health", {}, env);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    const tables = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('products','observations','price_snapshots') ORDER BY name"
    ).all<{ name: string }>();
    expect(tables.results.map((t) => t.name)).toEqual(["observations", "price_snapshots", "products"]);
  });
});
