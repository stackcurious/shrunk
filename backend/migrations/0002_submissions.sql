-- Crowd label submissions (spec §5). `id` is the UUID also written to
-- observations.source_ref, which is how a submission finds its observation.
CREATE TABLE submissions (
  id              TEXT PRIMARY KEY,
  device_id       TEXT NOT NULL,
  gtin            TEXT NOT NULL,
  photo_key       TEXT,
  ocr_text        TEXT,
  parsed_quantity REAL NOT NULL,
  parsed_kind     TEXT NOT NULL CHECK (parsed_kind IN ('mass','volume','count')),
  status          TEXT NOT NULL CHECK (status IN ('accepted','pending','rejected')),
  created_at      INTEGER NOT NULL,
  reviewed_at     INTEGER
);
CREATE INDEX sub_status ON submissions(status, created_at);

-- Queued pushes (spec §5). The cron that drains this arrives in Phase 4; this
-- phase only ever writes kind='size_drop'. No CHECK on `kind` — Phase 4 adds
-- 'price_hike', 'verified_case' and 'digest'.
CREATE TABLE alert_jobs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT NOT NULL,
  gtin        TEXT,
  brand       TEXT,
  location_id TEXT,
  payload     TEXT,
  created_at  INTEGER NOT NULL,
  sent_at     INTEGER
);
CREATE INDEX aj_unsent ON alert_jobs(sent_at, created_at);

-- Phase-2 review I2: admin review (getObservationBySubmission) queries
-- WHERE source = 'crowd' AND source_ref = ?, which obs_gtin(gtin, status,
-- observed_at) cannot serve. Spec §1 puts ~1.7M rows in `observations` after
-- the FDC import, so this table would be full-scanned on every accept/reject.
-- This migration has not been applied to production (wrangler.toml still
-- carries the placeholder database_id), so amending it in place is free.
CREATE INDEX obs_source_ref ON observations(source, source_ref);
