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
