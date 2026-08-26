-- Phase 4 (spec §5). Only new objects here — no earlier table is recreated.
CREATE TABLE devices (
  id                TEXT PRIMARY KEY,   -- app-generated UUID
  apns_token        TEXT,               -- APNs hex token (or FCM registration token)
  location_id       TEXT,               -- the user's Kroger store
  categories        TEXT,               -- JSON array of canonical category names
  prefs             TEXT,               -- JSON object of per-kind toggles, e.g. {"digest":false}
  pro_until         INTEGER,            -- unix seconds; NULL = not Pro. Phase 5 writes this.
  app_account_token TEXT,               -- UUID passed to the StoreKit purchase
  transaction_jws   TEXT,               -- stored raw in Phase 4; Phase 5 verifies it
  updated_at        INTEGER NOT NULL
);
CREATE INDEX devices_pro ON devices(pro_until);
CREATE INDEX devices_account ON devices(app_account_token);

CREATE TABLE watches (
  device_id     TEXT NOT NULL,
  gtin          TEXT NOT NULL,
  brand         TEXT,
  alert_enabled INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (device_id, gtin)
);
CREATE INDEX watches_gtin ON watches(gtin, alert_enabled);
CREATE INDEX watches_brand ON watches(brand, alert_enabled);

-- Resume cursor for the every-5-minute drain: how many recipient rows of this
-- job have already been processed (spec §6.2 caps a run at 40 pushes).
ALTER TABLE alert_jobs ADD COLUMN sent_count INTEGER NOT NULL DEFAULT 0;
