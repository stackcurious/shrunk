-- Phase-5 fix wave (final review C1/I4).
--
-- C1: db.ts's rebind logic (upsertDevice) depends on "exactly one devices
-- row holds a given app_account_token" — routes/appstore.ts updates
-- entitlement by that column, not by id, so if two rows ever held the same
-- token a renewal/refund notification would silently double-apply.
-- 0003_devices_watches.sql's `devices_account` is a plain (non-unique) index
-- and never enforced that. Replace it with a unique partial index — partial
-- because most devices have never verified a transaction and app_account_token
-- is NULL for them; SQLite's UNIQUE index does not consider NULLs equal to
-- each other by default, but the WHERE clause makes that explicit and keeps
-- the index small. No production data exists yet (the Worker is not
-- deployed), so there is nothing to collide.
DROP INDEX IF EXISTS devices_account;
CREATE UNIQUE INDEX devices_account_unique ON devices(app_account_token) WHERE app_account_token IS NOT NULL;

-- I4: ordering/idempotency metadata for /v1/appstore/notifications.
-- `entitlement_updated_at` is the signedDate (unix seconds) of the
-- notification that last wrote pro_until for this device; a notification
-- whose own signedDate is not newer than this is a retry or an out-of-order
-- delivery and must not overwrite pro_until. `last_notification_uuid` makes
-- an exact-duplicate delivery (Apple retries for up to 3 days) a no-op too.
ALTER TABLE devices ADD COLUMN entitlement_updated_at INTEGER;
ALTER TABLE devices ADD COLUMN last_notification_uuid TEXT;
