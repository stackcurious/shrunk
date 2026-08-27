import { Hono } from "hono";
import { getDevice, replaceWatches, type WatchInput } from "../db";
import type { Env } from "../env";
import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";
import { entitlementFromJWS, trustAnchor } from "../appstore/entitlement";

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

  const rawWatches = body.watches;
  if (Array.isArray(rawWatches) && rawWatches.length > MAX_WATCHES) {
    return c.json({ error: "too_many_watches" }, 400);
  }

  const transactionJws = text(body.transaction_jws, 8192);

  // Spec §8: a verification failure must not disturb the device's existing
  // entitlement — the app's own StoreKit entitlement governs the UI, and the
  // next upsert retries. Only a verified, correctly-scoped transaction writes.
  const entitlement = await entitlementFromJWS(transactionJws, new Date(), trustAnchor(c.env));
  if (!entitlement && transactionJws) {
    console.warn("devices: transaction_jws did not verify for", id);
  }

  const now = Math.floor(Date.now() / 1000);
  const cats = categories(body.categories);
  const prf = prefs(body.prefs);

  await c.env.DB.prepare(
    `INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       apns_token        = COALESCE(excluded.apns_token, devices.apns_token),
       location_id       = COALESCE(excluded.location_id, devices.location_id),
       categories        = COALESCE(excluded.categories, devices.categories),
       prefs             = COALESCE(excluded.prefs, devices.prefs),
       pro_until         = COALESCE(excluded.pro_until, devices.pro_until),
       app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
       transaction_jws   = COALESCE(excluded.transaction_jws, devices.transaction_jws),
       updated_at        = excluded.updated_at`
  )
    .bind(
      id,
      text(body.apns_token, MAX_TOKEN_LENGTH),
      text(body.location_id, 32),
      cats ? JSON.stringify(cats) : null,
      prf ? JSON.stringify(prf) : null,
      entitlement?.proUntil ?? null,
      entitlement?.appAccountToken ?? null,
      transactionJws,
      now
    )
    .run();

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
