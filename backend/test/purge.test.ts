import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0028400642255";

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, '01400943', 1.89, 0, 0.07, '28 fl oz', 'HIGH', 1700000000)").bind(GTIN),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'kroger', '01400943', 0.8, 'accepted', 1)").bind(GTIN),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1600000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN),
  ]);
});

describe("POST /v1/admin/purge-kroger", () => {
  it("deletes every snapshot and every kroger observation, keeping the rest", async () => {
    const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-secret" } }, env);
    expect(res.status).toBe(200);
    // The seeded product has origin='fdc' (default) and keeps its 'fdc'
    // observation, so it is never a purge-kroger candidate — products: 0.
    expect(await res.json()).toEqual({ deleted: { price_snapshots: 1, observations: 1, products: 0 } });

    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    const rows = await env.DB.prepare("SELECT source FROM observations").all<{ source: string }>();
    expect(snaps!.n).toBe(0);
    expect(rows.results.map((r) => r.source)).toEqual(["fdc"]);
  });

  it("rejects a missing or wrong bearer", async () => {
    const anonymous = await app.request("/v1/admin/purge-kroger", { method: "POST" }, env);
    expect(anonymous.status).toBe(401);
    expect(await anonymous.json()).toEqual({ error: "unauthorized" });

    const wrong = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer nope" } }, env);
    expect(wrong.status).toBe(401);

    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    expect(snaps!.n).toBe(1);
  });

  // Phase-3 review C1: purge-kroger must remove products rows that are 100%
  // Kroger-derived, or §9's "one command removes every Kroger-derived row" is
  // false — a Kroger CDN image_url and Kroger's own name/category would
  // survive indefinitely.
  describe("C1 — Kroger-origin products", () => {
    const KROGER_ONLY_GTIN = "0011110000003";
    const KROGER_WITH_FDC_OBS_GTIN = "0022220000004";
    const NON_KROGER_ORIGIN_GTIN = "0033330000005";

    beforeEach(async () => {
      await env.DB.batch([
        // A product Kroger created first, whose only observation is the
        // 'kroger' one deleted by the second statement in the same batch —
        // this row must be deleted.
        env.DB
          .prepare(
            "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, origin, created_at, updated_at) VALUES (?, 'Kroger Item', 'K', 'Beverages', 'https://cdn.kroger.com/x.jpg', 'volume', 'kroger', 1, 1)",
          )
          .bind(KROGER_ONLY_GTIN),
        env.DB
          .prepare(
            "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'kroger', '01400943', 0.8, 'accepted', 1)",
          )
          .bind(KROGER_ONLY_GTIN),

        // A product Kroger created first, but which also picked up an FDC
        // observation afterwards — the row must survive because it is no
        // longer purely Kroger-derived (its 'kroger' observation is deleted,
        // its 'fdc' one is not).
        env.DB
          .prepare(
            "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, origin, created_at, updated_at) VALUES (?, 'Kroger Then FDC', 'K', 'Beverages', NULL, 'volume', 'kroger', 1, 1)",
          )
          .bind(KROGER_WITH_FDC_OBS_GTIN),
        env.DB
          .prepare(
            "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'kroger', '01400943', 0.8, 'accepted', 1)",
          )
          .bind(KROGER_WITH_FDC_OBS_GTIN),
        env.DB
          .prepare(
            "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'fdc', '1', 0.9, 'accepted', 1)",
          )
          .bind(KROGER_WITH_FDC_OBS_GTIN),

        // A product with no observations at all, but origin != 'kroger' —
        // must never be touched by purge-kroger regardless of its
        // observation count.
        env.DB
          .prepare(
            "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, origin, created_at, updated_at) VALUES (?, 'Lookup Item', 'L', 'Snacks', NULL, NULL, 'lookup', 1, 1)",
          )
          .bind(NON_KROGER_ORIGIN_GTIN),
      ]);
    });

    it("deletes a Kroger-origin product left with no observations", async () => {
      const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-secret" } }, env);
      expect(res.status).toBe(200);

      const row = await env.DB.prepare("SELECT gtin FROM products WHERE gtin = ?").bind(KROGER_ONLY_GTIN).first();
      expect(row).toBeNull();
    });

    it("keeps a Kroger-origin product that still has a non-kroger observation", async () => {
      const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-secret" } }, env);
      expect(res.status).toBe(200);

      const row = await env.DB.prepare("SELECT gtin FROM products WHERE gtin = ?").bind(KROGER_WITH_FDC_OBS_GTIN).first();
      expect(row).not.toBeNull();
      const remaining = await env.DB.prepare("SELECT source FROM observations WHERE gtin = ?").bind(KROGER_WITH_FDC_OBS_GTIN).all<{ source: string }>();
      expect(remaining.results.map((r) => r.source)).toEqual(["fdc"]);
    });

    it("never deletes a non-Kroger-origin product even with zero observations", async () => {
      const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-secret" } }, env);
      expect(res.status).toBe(200);

      const row = await env.DB.prepare("SELECT gtin FROM products WHERE gtin = ?").bind(NON_KROGER_ORIGIN_GTIN).first();
      expect(row).not.toBeNull();
    });

    it("reports the deleted products count", async () => {
      const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-secret" } }, env);
      const body = await res.json<{ deleted: { products: number } }>();
      // The base beforeEach also seeds one 'fdc'-origin product (unaffected);
      // only KROGER_ONLY_GTIN is Kroger-origin with zero surviving observations.
      expect(body.deleted.products).toBe(1);
    });
  });
});
