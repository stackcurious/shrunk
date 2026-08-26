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

  it("has an index on observations(source, source_ref) so admin lookups after the FDC import don't full-scan", async () => {
    // I2: getObservationBySubmission queries WHERE source = 'crowd' AND
    // source_ref = ? on a table spec §1 puts at ~1.7M rows after the FDC
    // import; obs_gtin(gtin, status, observed_at) cannot serve this query.
    const index = await env.DB
      .prepare("SELECT name, tbl_name FROM sqlite_master WHERE type='index' AND name = 'obs_source_ref'")
      .first<{ name: string; tbl_name: string }>();
    expect(index).toMatchObject({ name: "obs_source_ref", tbl_name: "observations" });

    const plan = await env.DB
      .prepare("EXPLAIN QUERY PLAN SELECT id FROM observations WHERE source = 'crowd' AND source_ref = 'x'")
      .all<{ detail: string }>();
    const detail = plan.results.map((r) => r.detail).join(" | ");
    expect(detail).toContain("obs_source_ref");
    expect(detail).not.toContain("SCAN");
  });
});
