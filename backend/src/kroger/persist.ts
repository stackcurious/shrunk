import { insertProduct } from "../db";
import type { Env } from "../env";
import { parsePackageWeight } from "../normalize";
import type { LiveProduct } from "./map";

/** Spec §5.1 — two sizes within 1% are the same size. */
const SAME_SIZE_TOLERANCE = 0.01;

/**
 * Kroger-derived writes. Everything this function touches is removable by
 * `POST /v1/admin/purge-kroger`, and it is only ever called when
 * `KROGER_PERSIST === "on"` (spec §9).
 */
export async function persistKrogerProduct(
  env: Env,
  gtin: string,
  locationId: string,
  live: LiveProduct,
  now: number = Math.floor(Date.now() / 1000),
): Promise<void> {
  // observations.gtin references products.gtin — make sure the row exists.
  // INSERT OR IGNORE, so an FDC/curated row keeps its own name and category.
  await insertProduct(env.DB, {
    gtin,
    name: live.description,
    brand: live.brand,
    category: live.category,
    image_url: live.image_url,
    unit_kind: live.unit_kind,
  });

  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(gtin, locationId, live.regular, live.promo, live.per_unit_estimate, live.size, live.stock_level, now)
    .run();

  // "each" alone carries no quantity — no observation (spec §5.2).
  if (live.quantity === null || live.unit_kind === null) return;

  const latest = await env.DB.prepare(
    "SELECT quantity FROM observations WHERE gtin = ? AND status = 'accepted' AND unit_kind = ? ORDER BY observed_at DESC, id DESC LIMIT 1",
  )
    .bind(gtin, live.unit_kind)
    .first<{ quantity: number }>();

  if (latest && latest.quantity > 0 && Math.abs(live.quantity - latest.quantity) / latest.quantity <= SAME_SIZE_TOLERANCE) {
    return; // same size we already know — nothing new to record
  }

  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, 'kroger', ?, 0.8, 'accepted', ?)",
  )
    .bind(gtin, live.quantity, live.unit_kind, live.size, now, locationId, now)
    .run();
}

/** Comparable $/unit for one snapshot row, or null when we cannot derive one. */
export function snapshotPerUnit(row: {
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
}): number | null {
  if (row.per_unit_estimate !== null && row.per_unit_estimate > 0) return row.per_unit_estimate;
  const price = row.promo !== null && row.promo > 0 ? row.promo : row.regular;
  if (price === null || price <= 0) return null;
  const parsed = row.size_raw ? parsePackageWeight(row.size_raw) : null;
  if (!parsed || parsed.quantity <= 0) return null;
  return price / parsed.quantity;
}
