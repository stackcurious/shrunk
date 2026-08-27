import { Hono } from "hono";
import { getDevice, replaceWatches, upsertDevice, type WatchInput } from "../db";
import type { Env } from "../env";
import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";
import { entitlementFromJWS, trustAnchor } from "../appstore/entitlement";
import { DEVICES_HOURLY_LIMIT, hitRateLimit, isValidDeviceId } from "../ratelimit";

/** Spec §3 says "unlimited items"; 500 is the abuse ceiling, not a product limit. */
export const MAX_WATCHES = 500;
const MAX_CATEGORIES = 32;
const MAX_TOKEN_LENGTH = 400;
const PREF_KEYS = ["sizeDrop", "priceHike", "verifiedCase", "digest"] as const;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export const devicesRoute = new Hono<{ Bindings: Env }>();

devicesRoute.post("/v1/devices", async (c) => {
  let body: Record<string, unknown>;
  try {
    body = (await c.req.json()) as Record<string, unknown>;
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  const id = typeof body.device_id === "string" ? body.device_id.trim() : "";
  if (!UUID_RE.test(id)) return c.json({ error: "invalid_device_id" }, 400);

  // I1 — the route used to trust body.device_id alone, so anyone could mint
  // device rows (and steer the Kroger sweep's pair set via location_id) with
  // no proof they own the id. X-Device-Id must be the UUID the app actually
  // sends (DeviceIdentity.current) and must name *this* device, matching the
  // enforcement already on /v1/kroger/* (routes/kroger.ts).
  const headerDeviceId = (c.req.header("x-device-id") ?? "").trim();
  if (!isValidDeviceId(headerDeviceId) || headerDeviceId.toLowerCase() !== id.toLowerCase()) {
    return c.json({ error: "invalid_device_id" }, 400);
  }

  const { allowed } = await hitRateLimit(c.env.KV, headerDeviceId, DEVICES_HOURLY_LIMIT, "devices");
  if (!allowed) return c.json({ error: "rate_limited" }, 429);

  const rawWatches = body.watches;
  if (Array.isArray(rawWatches) && rawWatches.length > MAX_WATCHES) {
    return c.json({ error: "too_many_watches" }, 400);
  }

  const transactionJws = text(body.transaction_jws, 8192);

  // Spec §8: a verification failure must not disturb the device's existing
  // entitlement — the app's own StoreKit entitlement governs the UI, and the
  // next upsert retries. A transaction whose appAccountToken doesn't match
  // *this* device must not grant Pro either — otherwise one valid receipt
  // could be replayed against any attacker-chosen device_id. Either failure
  // mode writes nothing (upsertDevice leaves pro_until/app_account_token
  // alone when `verified` is null).
  const entitlement = await entitlementFromJWS(transactionJws, new Date(), trustAnchor(c.env));
  const verified = entitlement && entitlement.appAccountToken === id.toLowerCase() ? entitlement : null;
  if (!verified && transactionJws) {
    // Minor #1 — a device id is a stable per-install identifier; log that a
    // verification failed, not which device it was.
    console.warn("devices: transaction_jws did not verify");
  }

  const now = Math.floor(Date.now() / 1000);
  await upsertDevice(
    c.env.DB,
    {
      id,
      apns_token: text(body.apns_token, MAX_TOKEN_LENGTH),
      location_id: text(body.location_id, 32),
      categories: categories(body.categories),
      prefs: prefs(body.prefs),
    },
    now,
    verified
  );

  if (Array.isArray(rawWatches)) {
    await replaceWatches(c.env.DB, id, watches(rawWatches));
  }

  const device = await getDevice(c.env.DB, id);
  const pro = device?.pro_until != null && device.pro_until > now;
  return c.json({ ok: true, pro });
});

function text(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > max) return null;
  return trimmed;
}

function categories(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null;
  const out: string[] = [];
  for (const entry of value.slice(0, MAX_CATEGORIES)) {
    const name = canonicalCategory(text(entry, 64));
    if (name && !out.includes(name)) out.push(name);
  }
  return out;
}

function prefs(value: unknown): Record<string, boolean> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = value as Record<string, unknown>;
  const out: Record<string, boolean> = {};
  for (const key of PREF_KEYS) {
    if (typeof source[key] === "boolean") out[key] = source[key] as boolean;
  }
  return Object.keys(out).length > 0 ? out : null;
}

function watches(value: unknown[]): WatchInput[] {
  const out: WatchInput[] = [];
  const seen = new Set<string>();
  for (const entry of value) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    const gtin = normalizeGTIN(typeof row.gtin === "string" ? row.gtin : null);
    if (!gtin || seen.has(gtin)) continue;
    seen.add(gtin);
    out.push({
      gtin,
      brand: text(row.brand, 120),
      alert_enabled: row.alert_enabled !== false,
    });
  }
  return out;
}
