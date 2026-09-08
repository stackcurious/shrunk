import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app from "../src/index";
import { lookupFDC } from "../src/lookup/fdc";
import { lookupOFF } from "../src/lookup/off";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("lookupFDC", () => {
  it("returns name/brand/category when the gtin matches", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      // The gtin goes out as a field-scoped leading wildcard, not as our
      // canonical 13-digit form — see gtinQuery in src/lookup/fdc.ts.
      expect(decodeURIComponent(url)).toContain("query=gtinUpc:*28400642255");
      expect(url).toContain("api_key=k");
      return jsonResponse({ foods: [{ gtinUpc: "028400642255", description: "GATORADE THIRST QUENCHER", brandOwner: "Stokely-Van Camp", brandName: "Gatorade", foodCategory: "Sports Drinks" }] });
    });
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    // "Sports Drinks" matches no alias, so canonicalCategory keeps it as-is.
    // Spec §1 rule 6: no packageWeight/publishedDate/fdcId in this fixture,
    // so those three carry through as null.
    expect(hit).toEqual({ name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Sports Drinks", packageWeight: null, observedAt: null, fdcId: null });
  });

  // FDC's `query` matches the gtinUpc string exactly as stored, and it stores
  // all three spellings: of 50 sampled "Doritos" records, 26 were 14-digit,
  // 19 were 12-digit and 5 were 13-digit. Sending only our canonical 13-digit
  // zero-padded form therefore missed ~90% of the catalogue outright
  // (`query=0016000362451` -> totalHits 0, `query=00016000362451` -> 1), which
  // is why on-miss lookups almost never carried FDC data. A field-scoped
  // leading wildcard on the zero-stripped digits matches every spelling.
  it("queries the gtinUpc field with a leading wildcard so every zero-padding matches", async () => {
    const fetchImpl = vi.fn(async (_input: RequestInfo | URL) => jsonResponse({ foods: [] }));
    await lookupFDC("0016000362451", "k", fetchImpl as unknown as typeof fetch);
    const url = String(fetchImpl.mock.calls[0][0]);
    expect(decodeURIComponent(url)).toContain("query=gtinUpc:*16000362451");
  });

  it("picks the food whose gtin actually matches, not merely the first", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        foods: [
          // A leading wildcard can also match a longer gtin that ends in the
          // same digits; only an exact normalized match is our product.
          { gtinUpc: "09928400642255", description: "DECOY", packageWeight: "99 oz" },
          { gtinUpc: "00028400642255", description: "GATORADE", brandName: "Gatorade", packageWeight: "28 fl oz" },
        ],
      }),
    );
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit?.name).toBe("Gatorade");
    expect(hit?.packageWeight).toBe("28 fl oz");
  });

  it("returns null when the top hit is a different gtin or the request fails", async () => {
    const wrong = vi.fn(async () => jsonResponse({ foods: [{ gtinUpc: "011111111111", description: "X" }] }));
    expect(await lookupFDC("0028400642255", "k", wrong as unknown as typeof fetch)).toBeNull();
    const failing = vi.fn(async () => jsonResponse({}, 500));
    expect(await lookupFDC("0028400642255", "k", failing as unknown as typeof fetch)).toBeNull();
  });

  // I8: foodCategory is routed through canonicalCategory so it agrees with
  // the same vocabulary products.category, the digest and the feed use.
  it("I8: maps foodCategory through canonicalCategory when it matches an alias", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ foods: [{ gtinUpc: "028400642255", description: "X", brandName: "X", foodCategory: "beverage" }] }),
    );
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("Beverages");
  });

  // Spec §1 rule 6: packageWeight, an observed_at derived from
  // publishedDate/modifiedDate, and the fdcId all survive onto the hit so
  // the on-miss route (routes/product.ts) can turn them into an observation.
  it("spec §1 rule 6: extracts packageWeight, publishedDate and fdcId", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        foods: [{
          fdcId: 654321,
          gtinUpc: "028400642255",
          description: "GATORADE ORANGE",
          brandName: "Gatorade",
          foodCategory: "Sports Drinks",
          packageWeight: "28 fl oz",
          publishedDate: "2019-05-08",
        }],
      }),
    );
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit?.packageWeight).toBe("28 fl oz");
    expect(hit?.fdcId).toBe("654321");
    expect(hit?.observedAt).toBe(Math.floor(Date.parse("2019-05-08") / 1000));
  });

  it("spec §1 rule 6: falls back to modifiedDate when publishedDate is absent", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        foods: [{ gtinUpc: "028400642255", description: "X", modifiedDate: "2021-01-01" }],
      }),
    );
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit?.observedAt).toBe(Math.floor(Date.parse("2021-01-01") / 1000));
  });
});

describe("lookupOFF", () => {
  it("returns name/brand/image/category on status 1", async () => {
    const fetchImpl = vi.fn(async (url: string, init?: RequestInit) => {
      expect((init?.headers as Record<string, string>)["User-Agent"]).toContain("Shrunk/2.0");
      // I8: categories_tags must be requested — it is the only source of a
      // real category from OFF.
      expect(url).toContain("categories_tags");
      return jsonResponse({
        status: 1,
        product: {
          product_name: "Doritos Nacho Cheese",
          brands: "Doritos, Frito-Lay",
          image_url: "https://img/x.jpg",
          categories_tags: ["en:snacks", "en:salty-snacks", "en:tortilla-chips"],
        },
      });
    });
    expect(await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch)).toEqual({
      name: "Doritos Nacho Cheese",
      brand: "Doritos",
      imageUrl: "https://img/x.jpg",
      // I8: last tag, "en:" stripped, routed through canonicalCategory —
      // "tortilla-chips" has no alias, so it is kept as-is.
      category: "tortilla-chips",
      // Spec §1 rule 6: no quantity/last_modified_t in this fixture.
      quantity: null,
      observedAt: null,
    });
  });

  it("I8: maps the last categories_tags entry through canonicalCategory when it matches an alias", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ status: 1, product: { product_name: "X", categories_tags: ["en:groceries", "en:beverages"] } }),
    );
    const hit = await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("Beverages");
  });

  it("I8: category is '' — never the literal 'Uncategorized' — when categories_tags is absent", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ status: 1, product: { product_name: "X" } }));
    const hit = await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("");
    expect(hit?.category).not.toBe("Uncategorized");
  });

  it("returns null on status 0 or non-200", async () => {
    const miss = vi.fn(async () => jsonResponse({ status: 0 }));
    expect(await lookupOFF("0028400642255", miss as unknown as typeof fetch)).toBeNull();
    const notFound = vi.fn(async () => jsonResponse({}, 404));
    expect(await lookupOFF("0028400642255", notFound as unknown as typeof fetch)).toBeNull();
  });

  // Spec §1 rule 6: OFF's raw `quantity` string and its unix-seconds
  // `last_modified_t` both survive onto the hit.
  it("spec §1 rule 6: extracts quantity and last_modified_t", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({
        status: 1,
        product: { product_name: "X", quantity: "500 g", last_modified_t: 1700000000 },
      }),
    );
    const hit = await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch);
    expect(hit?.quantity).toBe("500 g");
    expect(hit?.observedAt).toBe(1700000000);
  });
});

/**
 * Spec §1 rule 6 (docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md):
 * an on-miss `/v1/product/{gtin}` lookup (FDC, then OFF) used to discard the
 * size string entirely, leaving a product with zero observations ("Not
 * enough data yet" in the app even though FDC/OFF told us the size). These
 * hit the route end-to-end (D1 + the shared normalizer) to prove the Worker
 * now writes an accepted observation when the size parses, and still
 * creates a bare product when it doesn't.
 */
describe("on-miss lookup keeps the size (spec §1 rule 6)", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM price_snapshots"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  afterEach(() => vi.unstubAllGlobals());

  it("writes an accepted volume observation from FDC packageWeight", async () => {
    const gtin = "0052000338317";
    const publishedDate = "2019-05-08";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("api.nal.usda.gov")) {
          return new Response(
            JSON.stringify({
              foods: [
                {
                  fdcId: 654321,
                  gtinUpc: gtin,
                  description: "GATORADE ORANGE THIRST QUENCHER",
                  brandName: "Gatorade",
                  foodCategory: "Sports Drinks",
                  packageWeight: "28 fl oz",
                  publishedDate,
                },
              ],
            }),
            { status: 200, headers: { "content-type": "application/json" } }
          );
        }
        throw new Error(`unexpected fetch to ${url}`);
      })
    );

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();

    expect(body.name).toBe("Gatorade Orange Thirst Quencher");
    expect(body.unit_kind).toBe("volume");
    expect(body.observations).toHaveLength(1);
    expect(body.observations[0]).toMatchObject({
      unit_kind: "volume",
      source: "fdc",
      source_ref: "654321",
    });
    expect(body.observations[0].quantity).toBeCloseTo(828.06, 1);
    expect(body.observations[0].observed_at).toBe(Math.floor(Date.parse(publishedDate) / 1000));

    // Persisted, not just shaped for this one response.
    const row = await env.DB
      .prepare("SELECT unit_kind FROM products WHERE gtin = ?")
      .bind(gtin)
      .first<{ unit_kind: string }>();
    expect(row?.unit_kind).toBe("volume");
    const obsCount = await env.DB
      .prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ? AND status = 'accepted'")
      .bind(gtin)
      .first<{ n: number }>();
    expect(obsCount?.n).toBe(1);
  });

  it("falls back to OFF quantity when FDC misses, writing an accepted mass observation", async () => {
    const gtin = "0012345678905";
    const lastModified = 1700000000;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("api.nal.usda.gov")) {
          return new Response(JSON.stringify({ foods: [] }), { status: 200, headers: { "content-type": "application/json" } });
        }
        if (url.includes(`world.openfoodfacts.org/api/v2/product/${gtin}.json`)) {
          return new Response(
            JSON.stringify({
              status: 1,
              product: {
                product_name: "Store Brand Yogurt",
                brands: "Store Brand",
                image_url: "https://img/x.jpg",
                categories_tags: ["en:dairies"],
                quantity: "500 g",
                last_modified_t: lastModified,
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } }
          );
        }
        throw new Error(`unexpected fetch to ${url}`);
      })
    );

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();

    expect(body.name).toBe("Store Brand Yogurt");
    expect(body.unit_kind).toBe("mass");
    expect(body.observations).toHaveLength(1);
    expect(body.observations[0]).toMatchObject({ unit_kind: "mass", source: "off", observed_at: lastModified });
    expect(body.observations[0].quantity).toBeCloseTo(500, 1);
  });

  it("creates the product with no observation when the size is unparseable", async () => {
    const gtin = "0011111111110";
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("api.nal.usda.gov")) {
          return new Response(
            JSON.stringify({
              foods: [
                {
                  fdcId: 1,
                  gtinUpc: gtin,
                  description: "MYSTERY BEVERAGE",
                  brandName: "Nobrand",
                  foodCategory: "Beverages",
                  packageWeight: "1 bottle",
                  publishedDate: "2020-01-01",
                },
              ],
            }),
            { status: 200, headers: { "content-type": "application/json" } }
          );
        }
        throw new Error(`unexpected fetch to ${url}`);
      })
    );

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();

    expect(body.name).toBe("Mystery Beverage");
    expect(body.unit_kind).toBeNull();
    expect(body.observations).toEqual([]);

    const obsCount = await env.DB
      .prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ?")
      .bind(gtin)
      .first<{ n: number }>();
    expect(obsCount?.n).toBe(0);
  });
});

/**
 * Spec §1 rule 6 fires only on a *miss*. Products created by the on-miss
 * lookup before that rule existed keep a name and nothing else, and no code
 * path ever revisits them — 6 such rows on the production D1 on 2026-08-27
 * (e.g. 0052000338317 "Gatorade", origin='lookup', zero observations), which
 * is exactly the "Not enough data yet" dead-end rule 1 forbids. `/v1/product`
 * now re-runs the same FDC→OFF size backfill for them, once, rate-limited by
 * products.updated_at so an unparseable (or missing) size can't turn every
 * request for that product into an upstream call.
 */
describe("size backfill for an existing lookup product (spec §1 rule 6)", () => {
  const HOUR = 3600;
  const gtin = "0052000338317";

  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM price_snapshots"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  afterEach(() => vi.unstubAllGlobals());

  const now = () => Math.floor(Date.now() / 1000);

  async function seedProduct(opts: { origin?: string; updatedAt: number; unitKind?: string | null }) {
    await env.DB.prepare(
      "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, origin, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, ?, ?, 1, ?)"
    )
      .bind(gtin, opts.unitKind ?? null, opts.origin ?? "lookup", opts.updatedAt)
      .run();
  }

  function stubUpstream(handlers: { fdc?: unknown; off?: unknown }) {
    const stub = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      const body = url.includes("api.nal.usda.gov") ? handlers.fdc : url.includes("openfoodfacts.org") ? handlers.off : undefined;
      if (body === undefined) throw new Error(`unexpected fetch to ${url}`);
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    });
    vi.stubGlobal("fetch", stub);
    return stub;
  }

  const fdcHit = (extra: Record<string, unknown>) => ({
    foods: [{ fdcId: 654321, gtinUpc: "052000338317", description: "GATORADE ORANGE", brandName: "Gatorade", foodCategory: "Sports Drinks", ...extra }],
  });

  it("re-looks the size up and writes an accepted observation", async () => {
    const updatedAt = now() - 2 * HOUR;
    await seedProduct({ updatedAt });
    stubUpstream({ fdc: fdcHit({ packageWeight: "28 fl oz", publishedDate: "2019-05-08" }) });

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect(res.status).toBe(200);
    const body = await res.json<any>();

    expect(body.unit_kind).toBe("volume");
    expect(body.observations).toHaveLength(1);
    expect(body.observations[0]).toMatchObject({ unit_kind: "volume", source: "fdc", source_ref: "654321", raw_text: "28 fl oz" });
    expect(body.observations[0].quantity).toBeCloseTo(828.06, 1);
    expect(body.observations[0].observed_at).toBe(Math.floor(Date.parse("2019-05-08") / 1000));

    const row = await env.DB
      .prepare("SELECT unit_kind, updated_at FROM products WHERE gtin = ?")
      .bind(gtin)
      .first<{ unit_kind: string; updated_at: number }>();
    expect(row?.unit_kind).toBe("volume");
    // The attempt is recorded, so the next request inside the hour is a no-op.
    expect(row?.updated_at).toBeGreaterThan(updatedAt);
  });

  it("falls through to Open Food Facts when FDC has no packageWeight", async () => {
    await seedProduct({ updatedAt: now() - 2 * HOUR });
    stubUpstream({
      fdc: fdcHit({}),
      off: { status: 1, product: { product_name: "Gatorade", quantity: "500 g", last_modified_t: 1700000000 } },
    });

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    const body = await res.json<any>();
    expect(body.unit_kind).toBe("mass");
    expect(body.observations).toHaveLength(1);
    expect(body.observations[0]).toMatchObject({ unit_kind: "mass", source: "off", observed_at: 1700000000 });
    expect(body.observations[0].quantity).toBeCloseTo(500, 1);
  });

  it("does not call upstream again within the retry window", async () => {
    await seedProduct({ updatedAt: now() - 60 });
    const stub = stubUpstream({ fdc: fdcHit({ packageWeight: "28 fl oz" }) });

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect((await res.json<any>()).observations).toEqual([]);
    expect(stub).not.toHaveBeenCalled();
  });

  it("records the attempt even when the size never parses, so it stops hammering", async () => {
    await seedProduct({ updatedAt: now() - 2 * HOUR });
    const stub = stubUpstream({ fdc: fdcHit({ packageWeight: "1 bottle" }), off: { status: 0 } });

    const first = await app.request(`/v1/product/${gtin}`, {}, env);
    expect((await first.json<any>()).observations).toEqual([]);
    const callsAfterFirst = stub.mock.calls.length;
    expect(callsAfterFirst).toBeGreaterThan(0);

    const second = await app.request(`/v1/product/${gtin}`, {}, env);
    expect((await second.json<any>()).observations).toEqual([]);
    expect(stub.mock.calls.length).toBe(callsAfterFirst);
  });

  it("leaves rows the importer/curated seed owns alone", async () => {
    await seedProduct({ origin: "fdc", updatedAt: now() - 2 * HOUR });
    const stub = stubUpstream({ fdc: fdcHit({ packageWeight: "28 fl oz" }) });

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect((await res.json<any>()).observations).toEqual([]);
    expect(stub).not.toHaveBeenCalled();
  });

  it("does nothing when the product already has an accepted observation", async () => {
    await seedProduct({ updatedAt: now() - 2 * HOUR });
    await env.DB.prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.06, 'volume', '28 fl oz', 1500000000, 'fdc', '1', 0.9, 'accepted', 1)"
    )
      .bind(gtin)
      .run();
    const stub = stubUpstream({ fdc: fdcHit({ packageWeight: "12 fl oz" }) });

    const res = await app.request(`/v1/product/${gtin}`, {}, env);
    expect((await res.json<any>()).observations).toHaveLength(1);
    expect(stub).not.toHaveBeenCalled();
  });
});
