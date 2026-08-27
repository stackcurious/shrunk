export interface ProductRow {
  gtin: string;
  name: string;
  brand: string;
  category: string;
  image_url: string | null;
  unit_kind: string | null;
}

export interface ObservationRow {
  quantity: number;
  unit_kind: string;
  raw_text: string | null;
  observed_at: number;
  source: string;
  source_ref: string | null;
  confidence: number;
}

export interface PriceSnapshotRow {
  location_id: string;
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
  stock_level: string | null;
  observed_at: number;
}

export async function getProduct(db: D1Database, gtin: string): Promise<ProductRow | null> {
  return db
    .prepare("SELECT gtin, name, brand, category, image_url, unit_kind FROM products WHERE gtin = ?")
    .bind(gtin)
    .first<ProductRow>();
}

export async function getAcceptedObservations(db: D1Database, gtin: string): Promise<ObservationRow[]> {
  const { results } = await db
    .prepare(
      "SELECT quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence FROM observations WHERE gtin = ? AND status = 'accepted' ORDER BY observed_at ASC, id ASC"
    )
    .bind(gtin)
    .all<ObservationRow>();
  return results;
}

export async function getRecentSnapshots(db: D1Database, gtin: string, locationId: string, limit = 12): Promise<PriceSnapshotRow[]> {
  const { results } = await db
    .prepare(
      "SELECT location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at FROM price_snapshots WHERE gtin = ? AND location_id = ? ORDER BY observed_at DESC LIMIT ?"
    )
    .bind(gtin, locationId, limit)
    .all<PriceSnapshotRow>();
  return results;
}

/**
 * `origin` records which path first created the row (spec §9 / phase-3 review
 * C1) — `fdc` (importer or FDC-import default), `lookup` (on-miss FDC/OFF
 * fallback in `/v1/product`), `kroger`, or `curated`. `INSERT OR IGNORE` means
 * only the very first insert for a gtin sets it.
 */
export async function insertProduct(db: D1Database, row: ProductRow, origin: string = "fdc"): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await db
    .prepare(
      "INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, origin, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(row.gtin, row.name, row.brand, row.category, row.image_url, row.unit_kind, origin, now, now)
    .run();
}

export interface SubmissionRow {
  id: string;
  device_id: string;
  gtin: string;
  photo_key: string | null;
  ocr_text: string | null;
  parsed_quantity: number;
  parsed_kind: string;
  status: string;
  created_at: number;
  reviewed_at: number | null;
}

export interface PendingSubmissionRow extends SubmissionRow {
  name: string;
  brand: string;
}

export interface NewObservation {
  gtin: string;
  quantity: number;
  unit_kind: string;
  raw_text: string | null;
  observed_at: number;
  source: string;
  source_ref: string | null;
  confidence: number;
  status: string;
}

export interface NewAlertJob {
  kind: string;
  gtin: string;
  brand: string | null;
  location_id: string | null;
  payload: string;
  created_at: number;
}

/**
 * Statement builder (I1) so a caller can batch this insert with another one
 * in a single `db.batch([...])` — D1's batch is an implicit transaction, so
 * either both rows land or neither does.
 */
export function buildInsertObservation(db: D1Database, row: NewObservation): D1PreparedStatement {
  return db
    .prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(
      row.gtin, row.quantity, row.unit_kind, row.raw_text, row.observed_at,
      row.source, row.source_ref, row.confidence, row.status, Math.floor(Date.now() / 1000)
    );
}

export async function insertObservation(db: D1Database, row: NewObservation): Promise<number> {
  const result = await buildInsertObservation(db, row).run();
  return Number(result.meta.last_row_id);
}

export async function setObservationStatus(db: D1Database, id: number, status: string): Promise<void> {
  await db.prepare("UPDATE observations SET status = ? WHERE id = ?").bind(status, id).run();
}

export async function getLatestAcceptedObservation(
  db: D1Database, gtin: string, unitKind: string
): Promise<{ id: number; quantity: number; observed_at: number } | null> {
  return db
    .prepare(
      "SELECT id, quantity, observed_at FROM observations WHERE gtin = ? AND unit_kind = ? AND status = 'accepted' ORDER BY observed_at DESC, id DESC LIMIT 1"
    )
    .bind(gtin, unitKind)
    .first<{ id: number; quantity: number; observed_at: number }>();
}

export async function getObservationBySubmission(
  db: D1Database, submissionId: string
): Promise<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string; observed_at: number } | null> {
  return db
    .prepare(
      "SELECT id, gtin, quantity, unit_kind, status, observed_at FROM observations WHERE source = 'crowd' AND source_ref = ? LIMIT 1"
    )
    .bind(submissionId)
    .first<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string; observed_at: number }>();
}

/** Statement builder (I1) — see buildInsertObservation. */
export function buildInsertSubmission(db: D1Database, row: Omit<SubmissionRow, "reviewed_at">): D1PreparedStatement {
  return db
    .prepare(
      "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
    )
    .bind(
      row.id, row.device_id, row.gtin, row.photo_key, row.ocr_text,
      row.parsed_quantity, row.parsed_kind, row.status, row.created_at
    );
}

export async function insertSubmission(db: D1Database, row: Omit<SubmissionRow, "reviewed_at">): Promise<void> {
  await buildInsertSubmission(db, row).run();
}

export async function getSubmission(db: D1Database, id: string): Promise<SubmissionRow | null> {
  return db
    .prepare(
      "SELECT id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at FROM submissions WHERE id = ?"
    )
    .bind(id)
    .first<SubmissionRow>();
}

export async function listPendingSubmissions(db: D1Database, limit = 100): Promise<PendingSubmissionRow[]> {
  const { results } = await db
    .prepare(
      `SELECT s.id, s.device_id, s.gtin, s.photo_key, s.ocr_text, s.parsed_quantity, s.parsed_kind,
              s.status, s.created_at, s.reviewed_at,
              COALESCE(p.name, '') AS name, COALESCE(p.brand, '') AS brand
       FROM submissions s LEFT JOIN products p ON p.gtin = s.gtin
       WHERE s.status = 'pending'
       ORDER BY s.created_at ASC
       LIMIT ?`
    )
    .bind(limit)
    .all<PendingSubmissionRow>();
  return results;
}

export async function markSubmissionReviewed(
  db: D1Database, id: string, status: string, reviewedAt: number
): Promise<void> {
  // photo_key is cleared alongside the R2 delete so the row can never point at
  // an object that no longer exists.
  await db
    .prepare("UPDATE submissions SET status = ?, reviewed_at = ?, photo_key = NULL WHERE id = ?")
    .bind(status, reviewedAt, id)
    .run();
}

/**
 * I1: clears photo_key without touching status or reviewed_at — used when an
 * R2 put fails after the submission row already exists, so the row stays
 * `pending` and adjudicable rather than pointing at an object that was never
 * written.
 */
export async function clearSubmissionPhotoKey(db: D1Database, id: string): Promise<void> {
  await db.prepare("UPDATE submissions SET photo_key = NULL WHERE id = ?").bind(id).run();
}

export async function insertAlertJob(db: D1Database, job: NewAlertJob): Promise<void> {
  await db
    .prepare(
      "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at) VALUES (?, ?, ?, ?, ?, ?, NULL)"
    )
    .bind(job.kind, job.gtin, job.brand, job.location_id, job.payload, job.created_at)
    .run();
}

export async function setProductUnitKindIfMissing(
  db: D1Database, gtin: string, unitKind: string, now: number
): Promise<void> {
  await db
    .prepare("UPDATE products SET unit_kind = ?, updated_at = ? WHERE gtin = ? AND unit_kind IS NULL")
    .bind(unitKind, now, gtin)
    .run();
}

// ---------------------------------------------------------------------------
// Phase 4 — devices, watches (spec §5)
// ---------------------------------------------------------------------------

export interface DeviceRow {
  id: string;
  apns_token: string | null;
  location_id: string | null;
  categories: string | null;
  prefs: string | null;
  pro_until: number | null;
  app_account_token: string | null;
}

/**
 * Every field except `id` is optional: an omitted field keeps its stored
 * value, because `upsertDevice`'s `ON CONFLICT` `COALESCE`s each column and
 * COALESCE only skips a real NULL. `location_id: ""` and `categories: []`
 * are the explicit-clear spellings (I3, `routes/devices.ts`'s `locationId`/
 * `categories` helpers) — both bind as non-NULL values (`""`, `"[]"`), so
 * COALESCE writes them instead of preserving the prior value.
 */
export interface DeviceUpsert {
  id: string;
  apns_token?: string | null;
  location_id?: string | null;
  categories?: string[] | null;
  prefs?: Record<string, boolean> | null;
}

export interface WatchInput {
  gtin: string;
  brand: string | null;
  alert_enabled: boolean;
}

/**
 * Upserts a device row. `pro_until` / `app_account_token` are written only
 * when the caller passes `verified` — a transaction JWS that verified
 * against the App Store trust anchor *and* whose appAccountToken names a
 * real device id (spec §8, C1). This is the only place besides the
 * notifications route's own direct `UPDATE` (`routes/appstore.ts`) that
 * writes `pro_until`, so the "an unverified sync never downgrades or clears
 * a subscriber" invariant lives here, once, via the `ON CONFLICT` `COALESCE`.
 *
 * C1 — rebind: `verified.appAccountToken` is Apple's permanent
 * per-subscription identifier, baked into the purchase and unchangeable —
 * it does not necessarily equal `row.id`, the device posting *today* (a
 * reinstall mints a new device id; the original App Store transaction still
 * carries the old one). When it differs, the entitlement is moved rather
 * than dropped: whichever row currently holds that token is cleared first,
 * in the same D1 batch (atomic) as the upsert that then writes the token
 * onto the posting row — so a reader never observes two rows holding the
 * same `app_account_token`, and `0006_*.sql`'s unique partial index makes
 * that invariant durable. See routes/devices.ts for why this can't be used
 * to steal someone else's subscription.
 *
 * devices.transaction_jws is intentionally never written since R34; a later
 * migration drops it.
 */
export async function upsertDevice(
  db: D1Database,
  row: DeviceUpsert,
  now: number,
  verified?: { proUntil: number; appAccountToken: string } | null
): Promise<void> {
  const statements: D1PreparedStatement[] = [];

  if (verified && verified.appAccountToken !== row.id) {
    statements.push(
      db
        .prepare(
          "UPDATE devices SET pro_until = NULL, app_account_token = NULL, updated_at = ? WHERE app_account_token = ?"
        )
        .bind(now, verified.appAccountToken)
    );
  }

  statements.push(
    db
      .prepare(
        `INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           apns_token        = COALESCE(excluded.apns_token, devices.apns_token),
           location_id       = COALESCE(excluded.location_id, devices.location_id),
           categories        = COALESCE(excluded.categories, devices.categories),
           prefs             = COALESCE(excluded.prefs, devices.prefs),
           pro_until         = COALESCE(excluded.pro_until, devices.pro_until),
           app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
           updated_at        = excluded.updated_at`
      )
      .bind(
        row.id,
        row.apns_token ?? null,
        row.location_id ?? null,
        row.categories ? JSON.stringify(row.categories) : null,
        row.prefs ? JSON.stringify(row.prefs) : null,
        verified?.proUntil ?? null,
        verified?.appAccountToken ?? null,
        now
      )
  );

  await db.batch(statements);
}

export async function getDevice(db: D1Database, id: string): Promise<DeviceRow | null> {
  return db
    .prepare(
      "SELECT id, apns_token, location_id, categories, prefs, pro_until, app_account_token FROM devices WHERE id = ?"
    )
    .bind(id)
    .first<DeviceRow>();
}

/** The watch list is replace-only: the app owns it and posts the whole set. */
export async function replaceWatches(db: D1Database, deviceId: string, watches: WatchInput[]): Promise<void> {
  const statements: D1PreparedStatement[] = [
    db.prepare("DELETE FROM watches WHERE device_id = ?").bind(deviceId),
  ];
  for (const watch of watches) {
    statements.push(
      db
        .prepare("INSERT OR REPLACE INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, ?, ?)")
        .bind(deviceId, watch.gtin, watch.brand, watch.alert_enabled ? 1 : 0)
    );
  }
  await db.batch(statements);
}

export async function listWatches(db: D1Database, deviceId: string): Promise<WatchInput[]> {
  const { results } = await db
    .prepare("SELECT gtin, brand, alert_enabled FROM watches WHERE device_id = ? ORDER BY gtin")
    .bind(deviceId)
    .all<{ gtin: string; brand: string | null; alert_enabled: number }>();
  return results.map((r) => ({ gtin: r.gtin, brand: r.brand, alert_enabled: r.alert_enabled === 1 }));
}

/**
 * The newest accepted observation of the same kind strictly *before* the one
 * identified by (observedAt, id). Used by the feed and the digest to decide
 * whether an observation is a shrink (spec §5.1).
 */
export async function previousAcceptedQuantity(
  db: D1Database,
  gtin: string,
  unitKind: string,
  observedAt: number,
  id: number
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT quantity FROM observations
       WHERE gtin = ? AND unit_kind = ? AND status = 'accepted'
         AND (observed_at < ? OR (observed_at = ? AND id < ?))
       ORDER BY observed_at DESC, id DESC LIMIT 1`
    )
    .bind(gtin, unitKind, observedAt, observedAt, id)
    .first<{ quantity: number }>();
  return row ? row.quantity : null;
}

/**
 * Batched form of `previousAcceptedQuantity` (Important #2 — the digest was
 * issuing one D1 round trip per weekly observation row, up to
 * `OBSERVATION_LIMIT` of them). Fetches every accepted observation for the
 * candidates' gtins in a single query, then resolves each candidate's
 * "newest strictly-earlier same-(gtin, unit_kind) observation" in memory —
 * same ordering and tie-break (`observed_at DESC, id DESC`, strictly before
 * by `(observedAt, id)`) as the single-row version, just not one query per
 * candidate.
 */
export async function previousAcceptedQuantities(
  db: D1Database,
  candidates: Array<{ gtin: string; unitKind: string; observedAt: number; id: number }>
): Promise<Map<number, number>> {
  const result = new Map<number, number>();
  if (candidates.length === 0) return result;

  const gtins = [...new Set(candidates.map((c) => c.gtin))];
  const placeholders = gtins.map(() => "?").join(",");
  const { results } = await db
    .prepare(
      `SELECT id, gtin, unit_kind, quantity, observed_at FROM observations
       WHERE status = 'accepted' AND gtin IN (${placeholders})
       ORDER BY gtin, unit_kind, observed_at DESC, id DESC`
    )
    .bind(...gtins)
    .all<{ id: number; gtin: string; unit_kind: string; quantity: number; observed_at: number }>();

  // Grouped by (gtin, unit_kind) so each candidate's lookup below is a scan
  // of only its own product's history, already sorted newest-first.
  const byKey = new Map<string, Array<{ id: number; quantity: number; observed_at: number }>>();
  for (const row of results) {
    const key = `${row.gtin} ${row.unit_kind}`;
    const list = byKey.get(key);
    if (list) list.push(row);
    else byKey.set(key, [row]);
  }

  for (const candidate of candidates) {
    const list = byKey.get(`${candidate.gtin} ${candidate.unitKind}`);
    const previous = list?.find(
      (row) => row.observed_at < candidate.observedAt || (row.observed_at === candidate.observedAt && row.id < candidate.id)
    );
    if (previous) result.set(candidate.id, previous.quantity);
  }

  return result;
}

// ---------------------------------------------------------------------------
// R39 — device erasure (privacy policy: "email us your Device ID and we
// erase everything tied to it")
// ---------------------------------------------------------------------------

export interface EraseDeviceResult {
  devices: number;
  watches: number;
  submissions: number;
  photos: number;
}

/**
 * Deletes every row that identifies this device: its `watches`, its own
 * `devices` row, and its `submissions` (plus, first, the R2 object behind
 * any of its still-*pending* submissions — an accepted/rejected submission
 * already had `photo_key` cleared and its object deleted by admin review,
 * `markSubmissionReviewed`/`routes/admin.ts`, so this only ever finds a
 * pending one's photo).
 *
 * `observations`/`products`/`price_snapshots` are aggregated product data,
 * not personal to a device, and are never touched here. `alert_jobs` rows
 * are keyed by gtin/brand/location_id only (migrations 0002/0003) — nothing
 * on that table identifies a device, so there is nothing to delete there.
 *
 * R40/R42 — every write path canonicalizes (`canonicalDeviceId`, trim +
 * lowercase) before storing a device id, and `deviceId` here is expected to
 * already be canonical (the route does the same before calling in).
 * Matching is a plain `=`, not `lower(column) = ?`: a `lower()` call on the
 * column is non-sargable and, more importantly, would be one more place that
 * has to agree with every other device-id lookup/join in the codebase (e.g.
 * the alert drain's `ORDER BY d.id` resume cursor) about what "matches"
 * means. Migration 0005 backfills any row written before canonicalization
 * existed, so plain equality is correct everywhere, including here — this
 * function makes no special allowance for non-canonical storage.
 *
 * Idempotent: a device with nothing left to delete returns all zeros.
 */
export async function eraseDevice(db: D1Database, r2: R2Bucket, deviceId: string): Promise<EraseDeviceResult> {
  // R2 first, D1 batch second — deliberately, not incidentally. If the
  // process dies between the two steps, the submissions row (and its
  // photo_key) is still there, so a retry re-discovers the same photo and
  // re-issues r2.delete() — a harmless no-op against an already-deleted key,
  // per this function's documented idempotency. Doing it the other way
  // round would be unsafe for an erasure endpoint: once the D1 batch deletes
  // the submissions row, nothing on a retry would ever find that photo_key
  // again, so a crash after the D1 delete but before the R2 delete would
  // leak the photo forever while the caller believes it erased everything.
  const { results: pendingPhotos } = await db
    .prepare("SELECT photo_key FROM submissions WHERE device_id = ? AND status = 'pending' AND photo_key IS NOT NULL")
    .bind(deviceId)
    .all<{ photo_key: string }>();

  for (const row of pendingPhotos) {
    await r2.delete(row.photo_key);
  }

  const [watchesResult, devicesResult, submissionsResult] = await db.batch([
    db.prepare("DELETE FROM watches WHERE device_id = ?").bind(deviceId),
    db.prepare("DELETE FROM devices WHERE id = ?").bind(deviceId),
    db.prepare("DELETE FROM submissions WHERE device_id = ?").bind(deviceId),
  ]);

  return {
    devices: devicesResult.meta.changes ?? 0,
    watches: watchesResult.meta.changes ?? 0,
    submissions: submissionsResult.meta.changes ?? 0,
    photos: pendingPhotos.length,
  };
}
