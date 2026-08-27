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

/**
 * I2 — a per-invocation ceiling on (gtin, location) pairs, so an unbounded
 * pair set cannot make one sweep hit D1's invocation limits and truncate
 * silently. Pairs are ordered deterministically (location_id, gtin) and the
 * 400-pair window advances by a full cap's worth each six-hourly tick
 * (`selectSweepPairs`), so a pair set larger than the cap is still swept
 * completely over a handful of runs without a persisted resume cursor.
 */
export const SWEEP_PAIR_CAP = 400;
/** Matches the six-hourly cron cadence (spec §6.2). */
const SWEEP_ROTATION_PERIOD_SECONDS = 6 * 60 * 60;

/**
 * I3 — the `price_snapshots`-derived half of the pair union is bounded to
 * this window; the `watches x devices` half stays unbounded (spec §6.2 names
 * only that as the pair source). Without this, a product scanned once at one
 * store by a user who never watched it gets re-fetched from Kroger and
 * re-snapshotted forever — a quota problem and exactly the "systematically
 * gathering response data" behaviour spec §9 is trying to minimise.
 */
const SNAPSHOT_PAIR_WINDOW_SECONDS = 30 * 24 * 60 * 60;

export interface SweepResult {
  pairs: number;
  snapshots: number;
  sizeDrops: number;
  priceHikes: number;
  /** I2 — count of pairs whose persist/enqueue step threw; the run continues. */
  failures: number;
}

interface SnapshotRow {
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
}

/**
 * Six-hourly Kroger sweep (spec §6.2). The (gtin, location_id) set is the
 * distinct pairs from `watches x devices` — a device only counts once it has a
 * store — unioned with the pairs we already hold snapshots for. Compares the
 * new snapshot with the previous one for the same pair and files
 * `alert_jobs(kind='size_drop' | 'price_hike')`.
 */
export async function runKrogerSweep(env: Env, client: KrogerClient = new KrogerClient(env)): Promise<SweepResult> {
  const result: SweepResult = { pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0, failures: 0 };
  if (env.KROGER_PERSIST !== "on") return result;

  const now = Math.floor(Date.now() / 1000);

  // Spec §6.2 — the sweep follows the watchlists: every product a device
  // watches, at that device's store, plus every pair we already snapshot in
  // the last 30 days (I3 — unbounded here meant sweeping every pair ever
  // snapshotted, forever, even for a product nobody ever watched).
  // Ordered deterministically (I2) so `selectSweepPairs` can cap and rotate.
  const { results: allPairs } = await env.DB
    .prepare(
      `SELECT DISTINCT w.gtin AS gtin, d.location_id AS location_id
       FROM watches w JOIN devices d ON d.id = w.device_id
       WHERE d.location_id IS NOT NULL AND d.location_id <> ''
       UNION
       SELECT DISTINCT gtin AS gtin, location_id AS location_id FROM price_snapshots WHERE observed_at >= ?
       ORDER BY location_id, gtin`
    )
    .bind(now - SNAPSHOT_PAIR_WINDOW_SECONDS)
    .all<{ gtin: string; location_id: string }>();
  const pairs = selectSweepPairs(allPairs, now);
  result.pairs = pairs.length;
  if (pairs.length === 0) return result;

  const byLocation = new Map<string, string[]>();
  for (const pair of pairs) {
    const list = byLocation.get(pair.location_id) ?? [];
    list.push(pair.gtin);
    byLocation.set(pair.location_id, list);
  }

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

        // I2 — one pair's D1 write failing (constraint, transient) must not
        // abort the remaining pairs in this batch, the remaining batches, or
        // the remaining stores. Consistent with the route's own persistence
        // try/catch (routes/kroger.ts) — Kroger never blocks, and neither
        // does our own storage.
        try {
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
        } catch {
          result.failures += 1;
        }
      }
    }
  }

  return result;
}

/**
 * I2 — caps `all` to `SWEEP_PAIR_CAP` pairs for this run. `all` must already
 * be in a stable, deterministic order (the SQL's `ORDER BY location_id,
 * gtin`). When the pair set exceeds the cap, the starting offset advances by
 * one cap's worth of pairs every `SWEEP_ROTATION_PERIOD_SECONDS` (the
 * six-hourly cron cadence) and wraps around, so consecutive runs sweep
 * disjoint windows and the full set is covered over a handful of runs
 * without a persisted resume cursor.
 */
export function selectSweepPairs<T>(all: T[], now: number): T[] {
  if (all.length <= SWEEP_PAIR_CAP) return all;
  const bucket = Math.floor(now / SWEEP_ROTATION_PERIOD_SECONDS);
  const offset = (bucket * SWEEP_PAIR_CAP) % all.length;
  const window: T[] = [];
  for (let i = 0; i < SWEEP_PAIR_CAP; i++) window.push(all[(offset + i) % all.length]);
  return window;
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
