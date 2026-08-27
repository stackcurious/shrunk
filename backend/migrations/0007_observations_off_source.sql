-- Spec §1 rule 6 (docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md):
-- an on-miss /v1/product/{gtin} lookup that falls through FDC to Open Food
-- Facts now writes an accepted observation from OFF's `quantity` field too,
-- tagged source='off'. 0001_init.sql's CHECK only allowed
-- ('fdc','curated','crowd','kroger') — production D1 already has rows under
-- that constraint (spec §0: 371,400 products), so this cannot be an in-place
-- edit of 0001 the way pre-launch migrations were amended (0002-0006's
-- comments). SQLite has no `ALTER TABLE ... ALTER CHECK`, so this is the
-- standard rebuild: new table with the widened CHECK, copy every row
-- (explicit ids preserve the AUTOINCREMENT sequence), drop the old table,
-- rename, then recreate both indexes 0001/0002 put on it.
CREATE TABLE observations_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  gtin        TEXT NOT NULL REFERENCES products(gtin),
  quantity    REAL NOT NULL,
  unit_kind   TEXT NOT NULL CHECK (unit_kind IN ('mass','volume','count')),
  raw_text    TEXT,
  observed_at INTEGER NOT NULL,
  source      TEXT NOT NULL CHECK (source IN ('fdc','off','curated','crowd','kroger')),
  source_ref  TEXT,
  confidence  REAL NOT NULL,
  status      TEXT NOT NULL CHECK (status IN ('accepted','pending','rejected')),
  created_at  INTEGER NOT NULL
);

INSERT INTO observations_new (id, gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at)
  SELECT id, gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at FROM observations;

DROP TABLE observations;
ALTER TABLE observations_new RENAME TO observations;

CREATE INDEX obs_gtin ON observations(gtin, status, observed_at);
CREATE INDEX obs_source_ref ON observations(source, source_ref);
