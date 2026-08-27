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
  transaction_jws: string | null;
}

/** Every field except `id` is optional: an omitted field keeps its stored value. */
export interface DeviceUpsert {
  id: string;
  apns_token?: string | null;
  location_id?: string | null;
  categories?: string[] | null;
  prefs?: Record<string, boolean> | null;
  app_account_token?: string | null;
  transaction_jws?: string | null;
}

export interface WatchInput {
  gtin: string;
  brand: string | null;
  alert_enabled: boolean;
}

/**
 * Upserts a device row. `pro_until` is written NULL on insert and is *never*
 * in the UPDATE set — Phase 5's JWS verifier owns that column, and a device
 * sync must never downgrade a subscriber (spec §8).
 */
export async function upsertDevice(db: D1Database, row: DeviceUpsert, now: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at)
       VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         apns_token        = COALESCE(excluded.apns_token, devices.apns_token),
         location_id       = COALESCE(excluded.location_id, devices.location_id),
         categories        = COALESCE(excluded.categories, devices.categories),
         prefs             = COALESCE(excluded.prefs, devices.prefs),
         app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
         transaction_jws   = COALESCE(excluded.transaction_jws, devices.transaction_jws),
         updated_at        = excluded.updated_at`
    )
    .bind(
      row.id,
      row.apns_token ?? null,
      row.location_id ?? null,
      row.categories ? JSON.stringify(row.categories) : null,
      row.prefs ? JSON.stringify(row.prefs) : null,
      row.app_account_token ?? null,
      row.transaction_jws ?? null,
      now
    )
    .run();
}

export async function getDevice(db: D1Database, id: string): Promise<DeviceRow | null> {
  return db
    .prepare(
      "SELECT id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws FROM devices WHERE id = ?"
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
