import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

async function seedProduct(gtin: string) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, "Gatorade Thirst Quencher", "Gatorade", "Beverages").run();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 907.184, 'mass', '32 oz/907 g', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 793.786, 'mass', '28 oz/794 g', 1625097600, 'fdc', '3', 0.9, 'accepted', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 500, 'mass', '500 g', 1700000000, 'crowd', 'sub1', 0.5, 'pending', 1)").bind(gtin),
    env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, '01400943', 1.89, 0, 0.07, '28 fl oz', 'HIGH', 1700000000)").bind(gtin),
  ]);
}

describe("GET /v1/product/:gtin", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM price_snapshots"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  it("returns product with accepted observations in date order", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const body = await res.json<any>();
    expect(body.gtin).toBe("0028400642255");
    expect(body.name).toBe("Gatorade Thirst Quencher");
    expect(body.unit_kind).toBe("mass");
    expect(body.observations.map((o: any) => o.quantity)).toEqual([907.184, 793.786]);
    expect(body.observations[0]).toMatchObject({ unit_kind: "mass", raw_text: "32 oz/907 g", observed_at: 1517443200, source: "fdc", source_ref: "1", confidence: 0.9 });
    expect(body.price_snapshots).toEqual([]);
  });

  it("normalizes a 12-digit UPC-A in the path", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/028400642255", {}, env);
    expect(res.status).toBe(200);
    expect((await res.json<any>()).gtin).toBe("0028400642255");
  });

  it("includes price snapshots for the requested location only", async () => {
    await seedProduct("0028400642255");
    const res = await app.request("/v1/product/0028400642255?locationId=01400943", {}, env);
    const body = await res.json<any>();
    expect(body.price_snapshots).toHaveLength(1);
    expect(body.price_snapshots[0]).toMatchObject({ location_id: "01400943", regular: 1.89, per_unit_estimate: 0.07, observed_at: 1700000000 });

    const other = await app.request("/v1/product/0028400642255?locationId=99999999", {}, env);
    expect((await other.json<any>()).price_snapshots).toEqual([]);
  });

  it("rejects an invalid gtin", async () => {
    const res = await app.request("/v1/product/12345", {}, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_gtin" });
  });
});
