import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app from "../src/index";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };

const PRODUCT = {
  productId: "0002840064225",
  upc: "0002840064225",
  brand: "Gatorade",
  description: "Gatorade Thirst Quencher Lemon-Lime",
  categories: ["Beverages"],
  images: [{ perspective: "front", sizes: [{ size: "large", url: "https://img/large.jpg" }] }],
  items: [
    {
      itemId: "0001",
      size: "28 fl oz",
      price: { regular: 1.89, promo: 1.5, regularPerUnitEstimate: 0.07, promoPerUnitEstimate: 0.05 },
      inventory: { stockLevel: "HIGH" },
    },
  ],
};

/**
 * A fresh device per test so the 60/hour counter never leaks across tests.
 * I4: must be UUID-shaped — this is what DeviceIdentity.current actually
 * sends — or the middleware 400s before any of these tests' stubs matter.
 */
function headers() {
  return { "X-Device-Id": crypto.randomUUID() };
}

function jsonResponse(body: unknown, status = 200, responseHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

/**
 * Stubs global `fetch`; `handler` returns the Response for a call it
 * recognizes, or `undefined` for one it doesn't — which fails the test loudly.
 */
function stubFetch(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      const res = await handler(url, init);
      if (!res) throw new Error(`unexpected fetch: ${init?.method ?? "GET"} ${url.pathname}${url.search}`);
      return res;
    }),
  );
}

/** Like `stubFetch`, but the token exchange always succeeds first. */
function stubKroger(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  stubFetch(async (url, init) => {
    if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
    return handler(url, init);
  });
}

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  // Nothing is stubbed by default — a test that doesn't call stubFetch/stubKroger
  // must never reach the network (mirrors the old disableNetConnect()).
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      throw new Error(`unexpected fetch: ${String(input)}`);
    }),
  );
});

afterEach(() => vi.unstubAllGlobals());

describe("GET /v1/kroger/locations", () => {
  it("returns mapped locations with attribution and the upstream cache header", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/locations") return undefined;
      expect(url.search).toBe("?filter.zipCode.near=45044&filter.radiusInMiles=15&filter.limit=20");
      return jsonResponse(
        { data: [{ locationId: "01400943", chain: "KROGER", name: "Hyde Park", address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" }, geolocation: { latitude: 39.14, longitude: -84.42 } }] },
        200,
        { "cache-control": "public, max-age=3600" },
      );
    });

    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const body = await res.json<any>();
    expect(body.attribution).toBe("Prices from Kroger");
    expect(body.locations[0]).toEqual({
      locationId: "01400943",
      chain: "KROGER",
      name: "Hyde Park",
      address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" },
      geolocation: { latitude: 39.14, longitude: -84.42 },
    });
  });

  it("rejects a malformed zip without calling Kroger", async () => {
    const res = await app.request("/v1/kroger/locations?zip=abc", { headers: headers() }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_zip" });
  });
});

describe("GET /v1/kroger/product/:gtin", () => {
  it("maps price, size, stock and image and echoes the gtin we were asked for", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products/0002840064225") return undefined;
      expect(url.search).toBe("?filter.locationId=01400943");
      return jsonResponse({ data: PRODUCT }, 200, { "cache-control": "private, max-age=1800" });
    });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("private, max-age=1800");
    expect(await res.json<any>()).toMatchObject({
      gtin: "0028400642255",
      location_id: "01400943",
      product_id: "0002840064225",
      brand: "Gatorade",
      category: "Beverages",
      image_url: "https://img/large.jpg",
      size: "28 fl oz",
      quantity: 828.058,
      unit_kind: "volume",
      regular: 1.89,
      promo: 1.5,
      per_unit_estimate: 0.05,
      stock_level: "HIGH",
      attribution: "Prices from Kroger",
    });
  });

  it("400s without a locationId (Kroger returns no price without one)", async () => {
    const res = await app.request("/v1/kroger/product/0028400642255", { headers: headers() }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "missing_location" });
  });

  it("404s when Kroger does not carry the product", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products/0002840064225") return undefined;
      return jsonResponse({ errors: { code: "PRODUCT-NOT-FOUND" } }, 404);
    });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });

  it("passes a revoked key (401) through", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products/0002840064225") return undefined;
      return jsonResponse({ error: "unauthorized" }, 401);
    });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "kroger_upstream", status: 401 });
  });
});

describe("GET /v1/kroger/search", () => {
  it("ranks by price per base unit, cheapest first", async () => {
    const cheap = { ...PRODUCT, productId: "0002840064226", upc: "0002840064226", description: "Store Brand", items: [{ size: "32 fl oz", price: { regular: 1.0, promo: 0 }, inventory: { stockLevel: "HIGH" } }] };
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      expect(url.search).toBe("?filter.term=Beverages&filter.locationId=01400943&filter.limit=50");
      return jsonResponse({ data: [PRODUCT, cheap] }, 200, { "cache-control": "private, max-age=1800" });
    });

    const res = await app.request("/v1/kroger/search?term=Beverages&locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("private, max-age=1800");
    const body = await res.json<any>();
    expect(body.attribution).toBe("Prices from Kroger");
    expect(body.results.map((r: any) => r.description)).toEqual(["Store Brand", "Gatorade Thirst Quencher Lemon-Lime"]);
    expect(body.results[0].price_per_base_unit).toBeCloseTo(1.0 / 946.353, 6);
  });

  it("passes a quota error (429) through", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      return jsonResponse({ error: "quota" }, 429);
    });

    const res = await app.request("/v1/kroger/search?term=Snacks&locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "kroger_upstream", status: 429 });
  });

  it("never persists search results", async () => {
    const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      return jsonResponse({ data: [PRODUCT] });
    });

    await app.request("/v1/kroger/search?term=Dairy&locationId=01400943", { headers: headers() }, { ...env, KROGER_PERSIST: "on" });
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    expect(after!.n).toBe(before!.n);
  });
});

describe("per-device rate limit", () => {
  it("429s once the device is over the hourly limit, without calling Kroger", async () => {
    const device = crypto.randomUUID();
    const bucket = Math.floor(Date.now() / 1000 / 3600);
    await env.KV.put(`rl:kroger:${device}:${bucket}`, "60", { expirationTtl: 3600 });

    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: { "X-Device-Id": device } }, env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
  });
});

describe("I4 — device identity and the global Kroger budget", () => {
  beforeEach(async () => {
    const bucket = Math.floor(Date.now() / 1000 / 3600);
    await env.KV.delete(`rl:kroger:global:${bucket}`);
  });

  it("400s a missing X-Device-Id without touching KV or Kroger", async () => {
    const res = await app.request("/v1/kroger/locations?zip=45044", {}, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("400s a non-UUID X-Device-Id", async () => {
    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: { "X-Device-Id": "not-a-uuid" } }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("T5: 400s an oversized X-Device-Id instead of 500ing on a too-long KV key", async () => {
    const res = await app.request(
      "/v1/kroger/locations?zip=45044",
      { headers: { "X-Device-Id": "x".repeat(600) } },
      env,
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("T5: 400s an empty X-Device-Id rather than collapsing into a shared bucket", async () => {
    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: { "X-Device-Id": "" } }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("429s every device once the global hourly budget is exhausted, before the per-device check", async () => {
    const bucket = Math.floor(Date.now() / 1000 / 3600);
    await env.KV.put(`rl:kroger:global:${bucket}`, "400", { expirationTtl: 3600 });

    // A brand-new device, nowhere near its own 60/hour cap, still 429s.
    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: headers() }, env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
  });

  it("counts toward the global budget on every request, shared across devices", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/locations") return undefined;
      return jsonResponse({ data: [] }, 200);
    });

    await app.request("/v1/kroger/locations?zip=45044", { headers: headers() }, env);
    await app.request("/v1/kroger/locations?zip=45044", { headers: headers() }, env);

    const bucket = Math.floor(Date.now() / 1000 / 3600);
    const count = await env.KV.get(`rl:kroger:global:${bucket}`);
    expect(count).toBe("2");
  });
});
