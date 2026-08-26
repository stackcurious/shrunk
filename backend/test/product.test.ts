import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

  afterEach(() => vi.unstubAllGlobals());

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

  it("creates the product from FDC when unknown", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
        const url = String(input);
        if (url.includes("api.nal.usda.gov")) {
          return new Response(
            JSON.stringify({
              foods: [{ gtinUpc: "028400642255", description: "GATORADE THIRST QUENCHER", brandName: "Gatorade", foodCategory: "Sports Drinks" }],
            }),
            { status: 200, headers: { "content-type": "application/json" } }
          );
        }
        throw new Error(`unexpected fetch to ${url}`);
      })
    );

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();
    expect(body).toMatchObject({ gtin: "0028400642255", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Sports Drinks", observations: [] });

    const row = await env.DB.prepare("SELECT name FROM products WHERE gtin = ?").bind("0028400642255").first<{ name: string }>();
    expect(row?.name).toBe("Gatorade Thirst Quencher");
  });

  it("falls back to Open Food Facts, then 404s", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
        const url = String(input);
        if (url.includes("api.nal.usda.gov")) {
          return new Response(JSON.stringify({ foods: [] }), { status: 200, headers: { "content-type": "application/json" } });
        }
        if (url.includes("world.openfoodfacts.org/api/v2/product/0028400642255.json")) {
          return new Response(
            JSON.stringify({ status: 1, product: { product_name: "Doritos", brands: "Doritos", image_url: "https://img/x.jpg" } }),
            { status: 200, headers: { "content-type": "application/json" } }
          );
        }
        if (url.includes("world.openfoodfacts.org/api/v2/product/0099999999999.json")) {
          return new Response(JSON.stringify({ status: 0 }), { status: 200, headers: { "content-type": "application/json" } });
        }
        throw new Error(`unexpected fetch to ${url}`);
      })
    );

    const hit = await app.request("/v1/product/0028400642255", {}, env);
    expect(hit.status).toBe(200);
    expect(await hit.json<any>()).toMatchObject({ name: "Doritos", brand: "Doritos", image_url: "https://img/x.jpg", observations: [] });

    const miss = await app.request("/v1/product/0099999999999", {}, env);
    expect(miss.status).toBe(404);
    expect(await miss.json()).toEqual({ error: "not_found" });
  });

  async function seedObservation(gtin: string, quantity: number, source: string, observedAt: number, unitKind = "mass") {
    await env.DB.prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, '', ?, ?, 'ref', 0.8, 'accepted', 1)",
    ).bind(gtin, quantity, unitKind, observedAt, source).run();
  }

  it("flags needs_confirmation when the newest Kroger size disagrees with the newest other source", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 340.194, "fdc", 1600000000);
    await seedObservation("0028400642255", 311.844, "kroger", 1700000000);

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect((await res.json<any>()).needs_confirmation).toBe(true);
  });

  it("does not flag when the sizes agree within 1%", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 340.194, "fdc", 1600000000);
    await seedObservation("0028400642255", 340.5, "kroger", 1700000000);

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect((await res.json<any>()).needs_confirmation).toBe(false);
  });

  it("does not flag across unit kinds or without a Kroger observation", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 12, "fdc", 1600000000, "count");
    await seedObservation("0028400642255", 311.844, "kroger", 1700000000, "mass");

    const mixed = await app.request("/v1/product/0028400642255", {}, env);
    expect((await mixed.json<any>()).needs_confirmation).toBe(false);

    await env.DB.prepare("DELETE FROM observations WHERE source = 'kroger'").run();
    const noKroger = await app.request("/v1/product/0028400642255", {}, env);
    expect((await noKroger.json<any>()).needs_confirmation).toBe(false);
  });
});
