-- R42 — one-time backfill for R40's device-id canonicalization. Every write
-- path now stores device ids as trim+lowercase (`canonicalDeviceId`,
-- src/ratelimit.ts), and every lookup/join/delete in the codebase does a
-- plain `=` match on that assumption (no `lower()` anywhere — see
-- eraseDevice, src/db.ts). This normalizes any row written before that
-- change existed. No production data exists yet (the Worker is not
-- deployed), so this cannot cause a collision; it is written anyway so a
-- preview/dev D1 with pre-R40 rows migrates cleanly. Idempotent — re-running
-- against an already-lowercase database matches zero rows each time.
UPDATE devices SET id = lower(id) WHERE id <> lower(id);
UPDATE watches SET device_id = lower(device_id) WHERE device_id <> lower(device_id);
UPDATE submissions SET device_id = lower(device_id) WHERE device_id <> lower(device_id);
