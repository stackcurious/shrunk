import { Hono } from "hono";
import type { Env } from "../env";
import {
  getAcceptedObservations,
  getProduct,
  getProductLookupState,
  getRecentSnapshots,
  insertObservation,
  insertProduct,
  setProductUnitKindIfMissing,
  touchProduct,
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
  } else {
    await backfillMissingSize(c.env, product);
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

/**
 * Spec §1 rule 6 — the raw size string plus when FDC/OFF observed it, carried
 * alongside the name/brand/category so a parseable size becomes the product's
 * first observation instead of being discarded.
 */
interface SizeCandidate {
  raw: string;
  observedAt: number | null;
  source: "fdc" | "off";
  sourceRef: string | null;
}

/**
 * How long a fruitless backfill attempt suppresses the next one. Bumping
 * `products.updated_at` on every attempt (not only on success) is what keeps a
 * product whose size never parses — or that FDC and OFF simply don't carry —
 * from turning each request for it into two upstream calls.
 */
const BACKFILL_RETRY_SECONDS = 3600;

/**
 * One upstream pass: FDC for identity and size, then OFF for whatever FDC
 * didn't supply. OFF is only called when it can still contribute something
 * (no FDC hit at all, or an FDC hit carrying no `packageWeight`) — an FDC hit
 * with a size costs exactly one request, as before.
 */
async function lookupProduct(env: Env, gtin: string): Promise<{ row: ProductRow | null; size: SizeCandidate | null }> {
  const fdc = await lookupFDC(gtin, env.FDC_API_KEY);
  let row: ProductRow | null = fdc
    ? { gtin, name: fdc.name, brand: fdc.brand, category: fdc.category, image_url: null, unit_kind: null }
    : null;
  let size: SizeCandidate | null = fdc?.packageWeight
    ? { raw: fdc.packageWeight, observedAt: fdc.observedAt, source: "fdc", sourceRef: fdc.fdcId }
    : null;

  if (!row || !size) {
    const off = await lookupOFF(gtin);
    // I8: off.category is a real category (from categories_tags) or "" —
    // never a hardcoded empty string regardless of what OFF actually had.
    if (!row && off) row = { gtin, name: off.name, brand: off.brand, category: off.category, image_url: off.imageUrl, unit_kind: null };
    if (!size && off?.quantity) size = { raw: off.quantity, observedAt: off.observedAt, source: "off", sourceRef: null };
  }

  return { row, size };
}

/**
 * Parses a looked-up size and, when it parses, records it as an accepted
 * observation. Best-effort: a size that fails to parse (e.g. "1 bottle") — or
 * an insert that fails — must never fail the product response. Returns the
 * unit kind that landed, or null.
 */
async function persistSize(env: Env, gtin: string, size: SizeCandidate, now: number): Promise<string | null> {
  try {
    const parsed = parsePackageWeight(size.raw);
    if (!parsed) return null;
    await insertObservation(env.DB, {
      gtin,
      quantity: parsed.quantity,
      unit_kind: parsed.unitKind,
      raw_text: size.raw,
      observed_at: size.observedAt ?? now,
      source: size.source,
      source_ref: size.sourceRef,
      // "fdc" matches the bulk FDC importer's confidence
      // (scripts/fdc/importer.py); OFF is community-maintained data, so
      // it lands lower. Both are written `status: "accepted"` directly —
      // this path never goes through the crowd gate (gate.ts), which
      // only scores device-submitted OCR observations.
      confidence: size.source === "fdc" ? 0.9 : 0.7,
      status: "accepted",
    });
    await setProductUnitKindIfMissing(env.DB, gtin, parsed.unitKind, now);
    return parsed.unitKind;
  } catch (err) {
    console.warn(`product: lookup size parse/insert failed for ${gtin}`, err);
    return null;
  }
}

async function createFromLookups(env: Env, gtin: string): Promise<ProductRow | null> {
  const { row, size } = await lookupProduct(env, gtin);
  if (!row) return null;
  // C1: an on-miss FDC/OFF lookup, not the bulk FDC importer — tagged
  // "lookup" so it is distinguishable from the importer's "fdc" rows, though
  // only "kroger" rows are ever purged.
  await insertProduct(env.DB, row, "lookup");
  if (size) row.unit_kind = await persistSize(env, gtin, size, Math.floor(Date.now() / 1000));
  return row;
}

/**
 * Spec §1 rule 6 only ever fired on a *miss*, so a product created by the
 * on-miss lookup before that rule existed keeps a name and nothing else and no
 * path revisits it — 6 such rows on production on 2026-08-27 (e.g.
 * 0052000338317 "Gatorade"), each of them the "Not enough data yet" dead end
 * rule 1 forbids. This re-runs the same FDC→OFF backfill for them, guarded so
 * a product that can never be resolved costs at most one pass per hour.
 *
 * Guards are ordered cheapest-first: `unit_kind` is already in memory, so a
 * product that has a size never issues a query at all; everything else the
 * decision needs is one `getProductLookupState` round trip.
 */
async function backfillMissingSize(env: Env, product: ProductRow): Promise<void> {
  if (product.unit_kind) return;

  const state = await getProductLookupState(env.DB, product.gtin);
  // Only rows this route itself created: importer/curated/kroger rows have
  // their own owners, and a row that already has an accepted observation has
  // nothing missing.
  if (!state || state.origin !== "lookup" || state.accepted_observations > 0) return;

  const now = Math.floor(Date.now() / 1000);
  if (now - state.updated_at < BACKFILL_RETRY_SECONDS) return;

  // The attempt is recorded *before* the upstream calls, not after: that way a
  // burst of concurrent requests for the same product, and a lookup that
  // throws, both still cost one pass rather than one per request.
  await touchProduct(env.DB, product.gtin, now);

  const { size } = await lookupProduct(env, product.gtin);
  if (size) product.unit_kind = await persistSize(env, product.gtin, size, now);
}
