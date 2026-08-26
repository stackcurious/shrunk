import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KrogerClient, KrogerError } from "../src/kroger/client";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };

function jsonResponse(body: unknown, status = 200, responseHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

/**
 * Stubs global `fetch` for one test. `handler` returns the Response for a call
 * it recognizes, or `undefined` for one it doesn't — which fails the test
 * loudly instead of silently hitting the real network.
 */
function stubFetch(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  const mock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const res = await handler(url, init);
    if (!res) throw new Error(`unexpected fetch: ${init?.method ?? "GET"} ${url.pathname}${url.search}`);
    return res;
  });
  vi.stubGlobal("fetch", mock);
  return mock;
}

/** Like `stubFetch`, but the token exchange always succeeds first. */
function stubKroger(handler: (url: URL, init: RequestInit | undefined) => Response | undefined | Promise<Response | undefined>) {
  return stubFetch(async (url, init) => {
    if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
    return handler(url, init);
  });
}

beforeEach(async () => {
  await env.KV.delete("kroger:token");
});

afterEach(() => vi.unstubAllGlobals());

describe("KrogerClient.token", () => {
  it("requests a client-credentials token and caches it in KV", async () => {
    const fetchMock = stubFetch((url, init) => {
      expect(url.pathname).toBe("/v1/connect/oauth2/token");
      expect(init?.method).toBe("POST");
      expect(init?.body).toBe("grant_type=client_credentials&scope=product.compact");
      expect((init?.headers as Record<string, string>).authorization).toBe(`Basic ${btoa("test-client:test-secret")}`);
      return jsonResponse(TOKEN_BODY);
    });

    const client = new KrogerClient(env);
    expect(await client.token()).toBe("tok-123");
    expect(await env.KV.get("kroger:token")).toBe("tok-123");

    // Second call must be served from KV — a second HTTP call would bump this count.
    expect(await client.token()).toBe("tok-123");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("throws KrogerError with the upstream status when the token call fails", async () => {
    stubFetch(() => jsonResponse({ error: "invalid_client" }, 401));

    await expect(new KrogerClient(env).token()).rejects.toMatchObject({ status: 401 });
    expect(await env.KV.get("kroger:token")).toBeNull();
  });

  it("exposes KrogerError for callers to branch on", () => {
    expect(new KrogerError(429).status).toBe(429);
    expect(new KrogerError(429)).toBeInstanceOf(Error);
  });
});

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
      soldBy: "UNIT",
      price: { regular: 1.89, promo: 1.5, regularPerUnitEstimate: 0.07, promoPerUnitEstimate: 0.05 },
      fulfillment: { instore: true, curbside: true, delivery: false, shiptohome: false },
      inventory: { stockLevel: "HIGH" },
    },
  ],
};

describe("KrogerClient calls", () => {
  it("fetches locations near a zip and forwards Cache-Control", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/locations") return undefined;
      expect(url.search).toBe("?filter.zipCode.near=45044&filter.radiusInMiles=15&filter.limit=20");
      return jsonResponse(
        { data: [{ locationId: "01400943", chain: "KROGER", name: "Hyde Park", address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" }, geolocation: { latitude: 39.14, longitude: -84.42 } }] },
        200,
        { "cache-control": "public, max-age=3600" },
      );
    });

    const result = await new KrogerClient(env).locations("45044");
    expect(result.data).toHaveLength(1);
    expect(result.data[0].locationId).toBe("01400943");
    expect(result.cacheControl).toBe("public, max-age=3600");
  });

  it("fetches one product at a location", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products/0002840064225") return undefined;
      expect(url.search).toBe("?filter.locationId=01400943");
      return jsonResponse({ data: PRODUCT }, 200, { "cache-control": "private, max-age=1800" });
    });

    const result = await new KrogerClient(env).product("0002840064225", "01400943");
    expect(result.data?.items?.[0].price?.regular).toBe(1.89);
    expect(result.cacheControl).toBe("private, max-age=1800");
  });

  it("batches at most 50 product ids into one call", async () => {
    const ids = Array.from({ length: 60 }, (_, i) => String(i).padStart(13, "0"));
    let requestedIds = "";
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      requestedIds = decodeURIComponent(url.searchParams.get("filter.productId")!);
      return jsonResponse({ data: [PRODUCT] });
    });

    const result = await new KrogerClient(env).products(ids, "01400943");
    expect(requestedIds.split(",")).toHaveLength(50);
    expect(result.data).toHaveLength(1);
  });

  it("searches by term at a location", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      expect(url.search).toBe("?filter.term=Beverages&filter.locationId=01400943&filter.limit=50");
      return jsonResponse({ data: [PRODUCT] });
    });

    const result = await new KrogerClient(env).search("Beverages", "01400943");
    expect(result.data[0].productId).toBe("0002840064225");
  });

  it("drops the cached token on 401 and surfaces the status", async () => {
    await env.KV.put("kroger:token", "stale-token");
    stubFetch((url) => {
      if (url.pathname !== "/v1/products/0002840064225") return undefined;
      return jsonResponse({ error: "unauthorized" }, 401);
    });

    await expect(new KrogerClient(env).product("0002840064225", "01400943")).rejects.toMatchObject({ status: 401 });
    expect(await env.KV.get("kroger:token")).toBeNull();
  });

  it("surfaces 429 so the route can pass it through", async () => {
    stubKroger((url) => {
      if (url.pathname !== "/v1/products") return undefined;
      return jsonResponse({ error: "quota" }, 429);
    });

    await expect(new KrogerClient(env).search("Snacks", "01400943")).rejects.toMatchObject({ status: 429 });
  });
});
