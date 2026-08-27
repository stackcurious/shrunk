-- Spec §1 rule 6 (docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md):
-- an on-miss /v1/product/{gtin} lookup that falls through FDC to Open Food
-- Facts now writes an accepted observation from OFF's `quantity` field too,
-- tagged source='off'. 0001_init.sql's CHECK only allowed
-- ('fdc','curated','crowd','kroger') — production D1 already has data (377,855
-- observation rows on 2026-08-27), so this cannot be an in-place edit of 0001
-- the way the pre-launch migrations were amended (0002-0006's comments).
-- SQLite has no `ALTER TABLE ... ALTER CHECK`, so this is the standard
-- rebuild: new table with the widened CHECK, copy every row (explicit ids, so
-- AUTOINCREMENT's sequence carries over), drop, rename, recreate both indexes
-- 0001/0002 put on it.
--
-- Verified against the live schema before writing (`SELECT sql FROM
-- sqlite_master WHERE tbl_name='observations'`): the columns below are
-- production's exactly, `obs_gtin`/`obs_source_ref` are the only other objects
-- on the table (no triggers, no views), nothing else references `observations`
-- by foreign key, and no observation row is an orphan — so the copy cannot
-- trip the `REFERENCES products(gtin)` constraint that is enforced during it.
--
-- Re-runnability: wrangler only records a migration once it succeeds, so a
-- half-applied file has to be safe to re-run. `IF NOT EXISTS` on the scratch
-- table and the two indexes handles a failure anywhere except the one-statement
-- window between DROP and RENAME. The guarded DELETE covers that window too, on
-- purpose: it names `observations`, so if a previous run had already dropped it
-- the statement fails to prepare — refusing to run rather than deleting the
-- copy that is by then the only one. Recovery from that state is the single
-- `ALTER TABLE observations_new RENAME TO observations;` below, by hand.
CREATE TABLE IF NOT EXISTS observations_new (
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

DELETE FROM observations_new WHERE EXISTS (SELECT 1 FROM observations);

INSERT INTO observations_new (id, gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at)
  SELECT id, gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at FROM observations;

DROP TABLE observations;
ALTER TABLE observations_new RENAME TO observations;

CREATE INDEX IF NOT EXISTS obs_gtin ON observations(gtin, status, observed_at);
CREATE INDEX IF NOT EXISTS obs_source_ref ON observations(source, source_ref);
