import { Hono } from "hono";
import type { Env } from "../env";
import { getAcceptedObservations, getProduct, getRecentSnapshots, type ProductRow } from "../db";
import { normalizeGTIN } from "../gtin";

export const productRoute = new Hono<{ Bindings: Env }>();

export async function buildProductResponse(db: D1Database, product: ProductRow, locationId: string | null) {
  const observations = await getAcceptedObservations(db, product.gtin);
  const price_snapshots = locationId ? await getRecentSnapshots(db, product.gtin, locationId) : [];
  return { ...product, observations, price_snapshots };
}

productRoute.get("/v1/product/:gtin", async (c) => {
  const gtin = normalizeGTIN(c.req.param("gtin"));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);

  const product = await getProduct(c.env.DB, gtin);
  if (!product) return c.json({ error: "not_found" }, 404);

  const locationId = c.req.query("locationId") ?? null;
  c.header("Cache-Control", "public, max-age=3600");
  return c.json(await buildProductResponse(c.env.DB, product, locationId));
});
