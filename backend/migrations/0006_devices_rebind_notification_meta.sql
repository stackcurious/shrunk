-- Phase-5 fix wave (final review C1).
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
