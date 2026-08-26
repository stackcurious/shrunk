import { Hono, type Context } from "hono";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";
import { KROGER_ATTRIBUTION, KrogerClient, KrogerError } from "../kroger/client";
import { krogerProductId } from "../kroger/ids";
import { toLiveProduct } from "../kroger/map";
import { deviceKey, hitRateLimit } from "../ratelimit";

type Ctx = Context<{ Bindings: Env }>;

export const krogerRoute = new Hono<{ Bindings: Env }>();

// One shared quota protects the whole /v1/kroger/* surface (spec §6.6).
krogerRoute.use("/v1/kroger/*", async (c, next) => {
  const { allowed } = await hitRateLimit(c.env.KV, deviceKey(c.req.raw));
  if (!allowed) return c.json({ error: "rate_limited" }, 429);
  await next();
});

/**
 * 401 (key revoked) and 429 (quota) reach the app unchanged so it can show
 * "Store prices unavailable right now" (spec §8); everything else is a 502.
 */
function upstreamError(c: Ctx, err: unknown): Response {
  const status = err instanceof KrogerError ? err.status : 0;
  if (status === 401) return c.json({ error: "kroger_upstream", status: 401 }, 401);
  if (status === 429) return c.json({ error: "kroger_upstream", status: 429 }, 429);
  return c.json({ error: "kroger_upstream", status }, 502);
}

krogerRoute.get("/v1/kroger/locations", async (c) => {
  const zip = (c.req.query("zip") ?? "").replace(/\D/g, "");
  if (zip.length !== 5) return c.json({ error: "invalid_zip" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).locations(zip);
    c.header("Cache-Control", cacheControl ?? "public, max-age=3600");
    return c.json({
      locations: data.map((l) => ({
        locationId: l.locationId,
        chain: l.chain ?? "",
        name: l.name ?? "",
        address: {
          addressLine1: l.address?.addressLine1 ?? "",
          city: l.address?.city ?? "",
          state: l.address?.state ?? "",
          zipCode: l.address?.zipCode ?? "",
        },
        geolocation: { latitude: l.geolocation?.latitude ?? null, longitude: l.geolocation?.longitude ?? null },
      })),
      attribution: KROGER_ATTRIBUTION,
    });
  } catch (err) {
    return upstreamError(c, err);
  }
});

krogerRoute.get("/v1/kroger/product/:gtin", async (c) => {
  const gtin = normalizeGTIN(c.req.param("gtin"));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);
  const locationId = c.req.query("locationId") ?? "";
  if (!locationId) return c.json({ error: "missing_location" }, 400);

  const productId = krogerProductId(gtin);
  if (!productId) return c.json({ error: "invalid_gtin" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).product(productId, locationId);
    if (!data) return c.json({ error: "not_found" }, 404);

    const live = toLiveProduct(data);
    // PERSISTENCE HOOK — Task 7 inserts the snapshot/observation write here.
    c.header("Cache-Control", cacheControl ?? "no-store");
    return c.json({ ...live, gtin, location_id: locationId, attribution: KROGER_ATTRIBUTION });
  } catch (err) {
    if (err instanceof KrogerError && err.status === 404) return c.json({ error: "not_found" }, 404);
    return upstreamError(c, err);
  }
});

krogerRoute.get("/v1/kroger/search", async (c) => {
  const term = (c.req.query("term") ?? "").trim();
  if (!term) return c.json({ error: "missing_term" }, 400);
  const locationId = c.req.query("locationId") ?? "";
  if (!locationId) return c.json({ error: "missing_location" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).search(term, locationId);
    // Search results are proxied only — never written to D1 (spec §6.1).
    const results = data
      .map(toLiveProduct)
      .filter((p) => p.regular !== null || p.promo !== null)
      .sort((a, b) => (a.price_per_base_unit ?? Infinity) - (b.price_per_base_unit ?? Infinity));

    c.header("Cache-Control", cacheControl ?? "no-store");
    return c.json({ results, attribution: KROGER_ATTRIBUTION });
  } catch (err) {
    return upstreamError(c, err);
  }
});
