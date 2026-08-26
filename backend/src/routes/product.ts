import { Hono } from "hono";
import type { Env } from "../env";
import { getAcceptedObservations, getProduct, getRecentSnapshots, insertProduct, type ObservationRow, type ProductRow } from "../db";
import { normalizeGTIN } from "../gtin";
import { lookupFDC } from "../lookup/fdc";
import { lookupOFF } from "../lookup/off";

export const productRoute = new Hono<{ Bindings: Env }>();

export async function buildProductResponse(db: D1Database, product: ProductRow, locationId: string | null) {
  const observations = await getAcceptedObservations(db, product.gtin);
  const price_snapshots = locationId ? await getRecentSnapshots(db, product.gtin, locationId) : [];
  return { ...product, observations, price_snapshots, needs_confirmation: needsConfirmation(observations) };
}

/**
 * Spec §4 step 4 — the live Kroger size disagrees with everything else we know,
 * so the app should ask for a label photo. Observations arrive oldest-first.
 */
export function needsConfirmation(observations: ObservationRow[]): boolean {
  const newest = (match: (o: ObservationRow) => boolean) => [...observations].reverse().find(match) ?? null;
  const kroger = newest((o) => o.source === "kroger");
  if (!kroger) return false;
  const other = newest((o) => o.source !== "kroger" && o.unit_kind === kroger.unit_kind);
  if (!other || other.quantity <= 0) return false;
  return Math.abs(kroger.quantity - other.quantity) / other.quantity > 0.01;
}

productRoute.get("/v1/product/:gtin", async (c) => {
  const gtin = normalizeGTIN(c.req.param("gtin"));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);

  let product = await getProduct(c.env.DB, gtin);
  if (!product) {
    product = await createFromLookups(c.env, gtin);
    if (!product) return c.json({ error: "not_found" }, 404);
  }

  const locationId = c.req.query("locationId") ?? null;
  c.header("Cache-Control", "public, max-age=3600");
  return c.json(await buildProductResponse(c.env.DB, product, locationId));
});

async function createFromLookups(env: Env, gtin: string): Promise<ProductRow | null> {
  const fdc = await lookupFDC(gtin, env.FDC_API_KEY);
  let row: ProductRow | null = null;
  if (fdc) {
    row = { gtin, name: fdc.name, brand: fdc.brand, category: fdc.category, image_url: null, unit_kind: null };
  } else {
    const off = await lookupOFF(gtin);
    if (off) row = { gtin, name: off.name, brand: off.brand, category: "", image_url: off.imageUrl, unit_kind: null };
  }
  if (!row) return null;
  await insertProduct(env.DB, row);
  return row;
}
