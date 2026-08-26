CREATE TABLE products (
  gtin        TEXT PRIMARY KEY,
  name        TEXT NOT NULL DEFAULT '',
  brand       TEXT NOT NULL DEFAULT '',
  category    TEXT NOT NULL DEFAULT '',
  image_url   TEXT,
  unit_kind   TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE observations (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  gtin        TEXT NOT NULL REFERENCES products(gtin),
  quantity    REAL NOT NULL,
  unit_kind   TEXT NOT NULL CHECK (unit_kind IN ('mass','volume','count')),
  raw_text    TEXT,
  observed_at INTEGER NOT NULL,
  source      TEXT NOT NULL CHECK (source IN ('fdc','curated','crowd','kroger')),
  source_ref  TEXT,
  confidence  REAL NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('accepted','pending','rejected')),
  created_at  INTEGER NOT NULL
);
CREATE INDEX obs_gtin ON observations(gtin, status, observed_at);

CREATE TABLE price_snapshots (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  gtin               TEXT NOT NULL,
  location_id        TEXT NOT NULL,
  regular            REAL,
  promo              REAL,
  per_unit_estimate  REAL,
  size_raw           TEXT,
  stock_level        TEXT,
  observed_at        INTEGER NOT NULL
);
CREATE INDEX ps_gtin_loc ON price_snapshots(gtin, location_id, observed_at);
