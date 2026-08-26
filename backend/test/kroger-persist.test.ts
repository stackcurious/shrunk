import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app from "../src/index";
import { snapshotPerUnit } from "../src/kroger/persist";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };
const GTIN = "0028400642255";

function product(size: string, regular = 1.89) {
  return {
    productId: "0002840064225",
    upc: "0002840064225",
    brand: "Gatorade",
    description: "Gatorade Thirst Quencher",
    categories: ["Beverages"],
    items: [{ size, price: { regular, promo: 0, regularPerUnitEstimate: 0.07 }, inventory: { stockLevel: "HIGH" } }],
  };
}

function jsonResponse(body: unknown, status = 200, responseHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

function stub(size: string, regular = 1.89) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
      if (url.pathname === "/v1/products/0002840064225") return jsonResponse({ data: product(size, regular) });
      throw new Error(`unexpected fetch: ${url.pathname}${url.search}`);
    }),
  );
}

const call = (persist: "on" | "off") =>
  app.request(
    `/v1/kroger/product/${GTIN}?locationId=01400943`,
    { headers: { "X-Device-Id": `dev-${crypto.randomUUID()}` } },
    { ...env, KROGER_PERSIST: persist },
  );

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  await env.DB.batch([
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
});

afterEach(() => vi.unstubAllGlobals());

describe("KROGER_PERSIST", () => {
  it("writes nothing when off", async () => {
    stub("28 fl oz");
    expect((await call("off")).status).toBe(200);
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations").first<{ n: number }>();
    expect([snaps!.n, obs!.n]).toEqual([0, 0]);
  });

  it("writes a snapshot, the product row and a kroger observation when on", async () => {
    stub("28 fl oz");
    expect((await call("on")).status).toBe(200);

    const snap = await env.DB.prepare("SELECT * FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<any>();
    expect(snap).toMatchObject({ location_id: "01400943", regular: 1.89, promo: 0, per_unit_estimate: 0.07, size_raw: "28 fl oz", stock_level: "HIGH" });

    const obs = await env.DB.prepare("SELECT * FROM observations WHERE gtin = ?").bind(GTIN).first<any>();
    expect(obs).toMatchObject({ quantity: 828.058, unit_kind: "volume", raw_text: "28 fl oz", source: "kroger", source_ref: "01400943", confidence: 0.8, status: "accepted" });

    const row = await env.DB.prepare("SELECT name FROM products WHERE gtin = ?").bind(GTIN).first<{ name: string }>();
    expect(row?.name).toBe("Gatorade Thirst Quencher");
  });

  it("does not duplicate an observation when the size has not moved", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
    await env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN).run();

    stub("28 fl oz");
    await call("on");

    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(obs!.n).toBe(1);
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(snaps!.n).toBe(1); // the snapshot is always written
  });

  it("records an observation when the size moved more than 1%", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
    await env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1600000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN).run();

    stub("28 fl oz");
    await call("on");

    const rows = await env.DB.prepare("SELECT source, quantity FROM observations WHERE gtin = ? ORDER BY id").bind(GTIN).all<any>();
    expect(rows.results.map((r) => r.source)).toEqual(["fdc", "kroger"]);
    expect(rows.results[1].quantity).toBeCloseTo(828.058, 3);
  });

  it("writes a snapshot but no observation when the size is unparseable", async () => {
    stub("each");
    await call("on");
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect([snaps!.n, obs!.n]).toEqual([1, 0]);
  });
});

describe("snapshotPerUnit", () => {
  it("prefers Kroger's estimate", () => {
    expect(snapshotPerUnit({ regular: 1.89, promo: null, per_unit_estimate: 0.07, size_raw: "28 fl oz" })).toBe(0.07);
  });

  it("falls back to effective price over parsed quantity", () => {
    expect(snapshotPerUnit({ regular: 1.89, promo: 1.5, per_unit_estimate: null, size_raw: "28 fl oz" })).toBeCloseTo(1.5 / 828.058, 8);
  });

  it("is null without a usable price or size", () => {
    expect(snapshotPerUnit({ regular: null, promo: null, per_unit_estimate: null, size_raw: "28 fl oz" })).toBeNull();
    expect(snapshotPerUnit({ regular: 1.89, promo: null, per_unit_estimate: null, size_raw: "each" })).toBeNull();
  });
});
