/** Spec §6.6 — one device may not burn the shared 10k/day Kroger quota. */
export const KROGER_HOURLY_LIMIT = 60;

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

/** Rate-limit identity. Contains no barcode and no search term. */
export function deviceKey(req: Request): string {
  return req.headers.get("x-device-id") ?? req.headers.get("cf-connecting-ip") ?? "anonymous";
}
