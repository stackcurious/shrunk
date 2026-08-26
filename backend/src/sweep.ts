import type { Env } from "./env";
import { KROGER_BATCH_LIMIT, KrogerClient, type KrogerProduct } from "./kroger/client";
import { gtinFromKroger, krogerProductId } from "./kroger/ids";
import { toLiveProduct, type LiveProduct } from "./kroger/map";
import { persistKrogerProduct, snapshotPerUnit } from "./kroger/persist";
import { parsePackageWeight } from "./normalize";

/** Spec §3 — Pro alerts fire at a 5% per-unit price rise. Exactly +5% alerts. */
const PRICE_HIKE_THRESHOLD = 0.05;
/** Spec §5.1 — within 1% is the same size. */
const SIZE_DROP_TOLERANCE = 0.01;

export interface SweepResult {
  pairs: number;
  snapshots: number;
  sizeDrops: number;
  priceHikes: number;
}

interface SnapshotRow {
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
}

/**
 * Six-hourly Kroger sweep (spec §6.2). Phase 3 has no `watches`/`devices`
 * tables — they arrive in Phase 4 — so the sweep re-checks every
 * (gtin, location_id) pair we already hold a snapshot for. Phase 4 swaps that
 * single query for `watches x devices` and leaves the rest of this file alone.
 */
export async function runKrogerSweep(env: Env, client: KrogerClient = new KrogerClient(env)): Promise<SweepResult> {
  const result: SweepResult = { pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0 };
  if (env.KROGER_PERSIST !== "on") return result;

  const { results: pairs } = await env.DB.prepare("SELECT DISTINCT gtin, location_id FROM price_snapshots").all<{
    gtin: string;
    location_id: string;
  }>();
  result.pairs = pairs.length;
  if (pairs.length === 0) return result;

  const byLocation = new Map<string, string[]>();
  for (const pair of pairs) {
    const list = byLocation.get(pair.location_id) ?? [];
    list.push(pair.gtin);
    byLocation.set(pair.location_id, list);
  }

  const now = Math.floor(Date.now() / 1000);

  for (const [locationId, gtins] of byLocation) {
    for (let offset = 0; offset < gtins.length; offset += KROGER_BATCH_LIMIT) {
      const ids = gtins
        .slice(offset, offset + KROGER_BATCH_LIMIT)
        .map(krogerProductId)
        .filter((id): id is string => id !== null);
      if (ids.length === 0) continue;

      let products: KrogerProduct[];
      try {
        products = (await client.products(ids, locationId)).data;
      } catch {
        continue; // Kroger unreachable for this batch — try again in six hours
      }

      for (const raw of products) {
        const gtin = gtinFromKroger(raw.upc ?? raw.productId);
        if (!gtin) continue;
        const live = toLiveProduct(raw);

        const previous = await env.DB.prepare(
          "SELECT regular, promo, per_unit_estimate, size_raw FROM price_snapshots WHERE gtin = ? AND location_id = ? ORDER BY observed_at DESC, id DESC LIMIT 1",
        )
          .bind(gtin, locationId)
          .first<SnapshotRow>();

        await persistKrogerProduct(env, gtin, locationId, live, now);
        result.snapshots += 1;
        if (!previous) continue;

        if (isSizeDrop(previous.size_raw, live)) {
          await enqueue(env, "size_drop", gtin, live.brand, locationId, { previous_size: previous.size_raw, size: live.size }, now);
          result.sizeDrops += 1;
        }

        const before = snapshotPerUnit(previous);
        const after = snapshotPerUnit({
          regular: live.regular,
          promo: live.promo,
          per_unit_estimate: live.per_unit_estimate,
          size_raw: live.size,
        });
        if (before !== null && after !== null && before > 0 && (after - before) / before >= PRICE_HIKE_THRESHOLD) {
          await enqueue(env, "price_hike", gtin, live.brand, locationId, { previous_per_unit: before, per_unit: after }, now);
          result.priceHikes += 1;
        }
      }
    }
  }

  return result;
}

/** A real shrink: same unit kind, more than 1% smaller than last time. */
function isSizeDrop(previousSizeRaw: string | null, live: LiveProduct): boolean {
  if (live.quantity === null || live.unit_kind === null || !previousSizeRaw) return false;
  const before = parsePackageWeight(previousSizeRaw);
  if (!before || before.unitKind !== live.unit_kind || before.quantity <= 0) return false;
  return (before.quantity - live.quantity) / before.quantity > SIZE_DROP_TOLERANCE;
}

async function enqueue(
  env: Env,
  kind: "size_drop" | "price_hike",
  gtin: string,
  brand: string,
  locationId: string,
  payload: unknown,
  now: number,
): Promise<void> {
  await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
  )
    .bind(kind, gtin, brand, locationId, JSON.stringify(payload), now)
    .run();
}
