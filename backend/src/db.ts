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

export async function insertProduct(db: D1Database, row: ProductRow): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  await db
    .prepare(
      "INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(row.gtin, row.name, row.brand, row.category, row.image_url, row.unit_kind, now, now)
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

export async function insertObservation(db: D1Database, row: NewObservation): Promise<number> {
  const result = await db
    .prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    .bind(
      row.gtin, row.quantity, row.unit_kind, row.raw_text, row.observed_at,
      row.source, row.source_ref, row.confidence, row.status, Math.floor(Date.now() / 1000)
    )
    .run();
  return Number(result.meta.last_row_id);
}

export async function setObservationStatus(db: D1Database, id: number, status: string): Promise<void> {
  await db.prepare("UPDATE observations SET status = ? WHERE id = ?").bind(status, id).run();
}

export async function getLatestAcceptedObservation(
  db: D1Database, gtin: string, unitKind: string
): Promise<{ id: number; quantity: number } | null> {
  return db
    .prepare(
      "SELECT id, quantity FROM observations WHERE gtin = ? AND unit_kind = ? AND status = 'accepted' ORDER BY observed_at DESC, id DESC LIMIT 1"
    )
    .bind(gtin, unitKind)
    .first<{ id: number; quantity: number }>();
}

export async function getObservationBySubmission(
  db: D1Database, submissionId: string
): Promise<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string } | null> {
  return db
    .prepare(
      "SELECT id, gtin, quantity, unit_kind, status FROM observations WHERE source = 'crowd' AND source_ref = ? LIMIT 1"
    )
    .bind(submissionId)
    .first<{ id: number; gtin: string; quantity: number; unit_kind: string; status: string }>();
}

export async function insertSubmission(db: D1Database, row: Omit<SubmissionRow, "reviewed_at">): Promise<void> {
  await db
    .prepare(
      "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
    )
    .bind(
      row.id, row.device_id, row.gtin, row.photo_key, row.ocr_text,
      row.parsed_quantity, row.parsed_kind, row.status, row.created_at
    )
    .run();
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
