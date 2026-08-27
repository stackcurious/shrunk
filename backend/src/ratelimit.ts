/** Spec §6.6 — one device may not burn the shared 10k/day Kroger quota. */
export const KROGER_HOURLY_LIMIT = 60;

/**
 * Phase-3 review I4 — a per-device cap alone fails closed only if the
 * identity behind it is unspoofable. `X-Device-Id` is a client-supplied
 * header, so a rotated header defeats KROGER_HOURLY_LIMIT entirely (~167
 * spoofed ids exhaust the shared 10,000/day Kroger quota in minutes). This
 * budget is checked ahead of the per-device one, keyed `rl:kroger:global:
 * <bucket>` (the literal deviceId "global" — never a valid UUID, so it can't
 * collide with a real device's bucket).
 */
export const KROGER_GLOBAL_HOURLY_LIMIT = 400;

/** Phase-2 fix wave I4 — the only unauthenticated write endpoint gets a cap too. */
export const OBSERVATIONS_HOURLY_LIMIT = 30;

/**
 * Fixed-window counter in KV, one key per device per hour per `purpose`. The
 * purpose keeps unrelated quotas from sharing a bucket — without it, a
 * device's Kroger proxy calls and its crowd submissions would draw down the
 * same counter and each feature could starve the other's allowance.
 *
 * The read-then-write is not atomic: a device racing itself can slip a
 * couple of calls over the line. That is acceptable — the counter exists to
 * stop runaway clients, not to bill anyone.
 */
export async function hitRateLimit(
  kv: KVNamespace,
  deviceId: string,
  limit: number = KROGER_HOURLY_LIMIT,
  purpose: string = "kroger",
): Promise<{ allowed: boolean; count: number }> {
  const bucket = Math.floor(Date.now() / 1000 / 3600);
  const key = `rl:${purpose}:${deviceId}:${bucket}`;
  const current = Number((await kv.get(key)) ?? "0");
  if (current >= limit) return { allowed: false, count: current };
  await kv.put(key, String(current + 1), { expirationTtl: 3600 });
  return { allowed: true, count: current + 1 };
}

/** RFC 4122-shaped: 8-4-4-4-12 hex, case-insensitive (Swift's `UUID().uuidString` is uppercase). */
const DEVICE_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * I4 — `X-Device-Id` must be the UUID the app actually sends
 * (`DeviceIdentity.current`, Shrunk/Services/DeviceIdentity.swift). Rejecting
 * anything else closes two holes at once: an unbounded string used to push
 * `rl:kroger:<id>:<bucket>` past KV's 512-byte key limit (a 500, not a 429),
 * and an empty header being treated as a "present" id that collapses every
 * caller without one into a single shared bucket.
 */
export function isValidDeviceId(value: string): boolean {
  return DEVICE_ID_PATTERN.test(value);
}
