import { Hono } from "hono";
import type { Env } from "../env";
import {
  getAcceptedObservations,
  getProduct,
  getRecentSnapshots,
  insertObservation,
  insertProduct,
  setProductUnitKindIfMissing,
  type ObservationRow,
  type ProductRow,
} from "../db";
import { normalizeGTIN } from "../gtin";
import { lookupFDC } from "../lookup/fdc";
import { lookupOFF } from "../lookup/off";
import { parsePackageWeight } from "../normalize";

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
  // I7: a locationId means the body may carry Kroger-derived price_snapshots
  // (store-level prices). Kroger returns `private` on its own price
  // responses (routes/kroger.ts) — spec §9 says we never widen that, so this
  // response must not be publicly cacheable for an hour. Without a
  // locationId, buildProductResponse never queries snapshots at all.
  c.header("Cache-Control", locationId ? "private, max-age=60" : "public, max-age=3600");
  return c.json(await buildProductResponse(c.env.DB, product, locationId));
});

async function createFromLookups(env: Env, gtin: string): Promise<ProductRow | null> {
  const fdc = await lookupFDC(gtin, env.FDC_API_KEY);
  let row: ProductRow | null = null;
  // Spec §1 rule 6 — the raw size string + when FDC/OFF observed it, kept
  // alongside the name/brand/category so a parseable size becomes the
  // product's first observation instead of being discarded.
  let sizeRaw: string | null = null;
  let observedAt: number | null = null;
  let source: "fdc" | "off" | null = null;
  let sourceRef: string | null = null;
  if (fdc) {
    row = { gtin, name: fdc.name, brand: fdc.brand, category: fdc.category, image_url: null, unit_kind: null };
    sizeRaw = fdc.packageWeight;
    observedAt = fdc.observedAt;
    source = "fdc";
    sourceRef = fdc.fdcId;
  } else {
    const off = await lookupOFF(gtin);
    // I8: off.category is a real category (from categories_tags) or "" —
    // never a hardcoded empty string regardless of what OFF actually had.
    if (off) {
      row = { gtin, name: off.name, brand: off.brand, category: off.category, image_url: off.imageUrl, unit_kind: null };
      sizeRaw = off.quantity;
      observedAt = off.observedAt;
      source = "off";
    }
  }
  if (!row) return null;
  // C1: an on-miss FDC/OFF lookup, not the bulk FDC importer — tagged
  // "lookup" so it is distinguishable from the importer's "fdc" rows, though
  // only "kroger" rows are ever purged.
  await insertProduct(env.DB, row, "lookup");

  // Best-effort: a size that fails to parse (e.g. "1 bottle") must never
  // fail the product response — the product row already landed above.
  if (sizeRaw && source) {
    try {
      const parsed = parsePackageWeight(sizeRaw);
      if (parsed) {
        const now = Math.floor(Date.now() / 1000);
        await insertObservation(env.DB, {
          gtin,
          quantity: parsed.quantity,
          unit_kind: parsed.unitKind,
          raw_text: sizeRaw,
          observed_at: observedAt ?? now,
          source,
          source_ref: sourceRef,
          // "fdc" matches the bulk FDC importer's confidence
          // (scripts/fdc/importer.py); OFF is community-maintained data, so
          // it lands lower. Both are written `status: "accepted"` directly —
          // this path never goes through the crowd gate (gate.ts), which
          // only scores device-submitted OCR observations.
          confidence: source === "fdc" ? 0.9 : 0.7,
          status: "accepted",
        });
        row.unit_kind = parsed.unitKind;
        await setProductUnitKindIfMissing(env.DB, gtin, parsed.unitKind, now);
      }
    } catch (err) {
      console.warn(`product: on-miss size parse/insert failed for ${gtin}`, err);
    }
  }

  return row;
}
