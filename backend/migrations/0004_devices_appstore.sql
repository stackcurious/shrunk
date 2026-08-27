-- Phase 5 (spec §6.1). devices (including transaction_jws) and watches already
-- exist from Phase 4's 0003_devices_watches.sql. This migration adds only the
-- lookup index the notifications route and /v1/devices use to find a device by
-- its App Store app_account_token.
CREATE INDEX IF NOT EXISTS devices_app_account_token ON devices(app_account_token);
