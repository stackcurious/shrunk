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
