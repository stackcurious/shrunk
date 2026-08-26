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
    expect(await res.json()).toEqual({ deleted: { price_snapshots: 1, observations: 1 } });

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
});
