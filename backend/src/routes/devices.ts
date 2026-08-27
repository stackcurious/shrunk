import { Hono } from "hono";
import { getDevice, replaceWatches, upsertDevice, type WatchInput } from "../db";
import type { Env } from "../env";
import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";
import { entitlementFromJWS, trustAnchor } from "../appstore/entitlement";
import { canonicalDeviceId, DEVICES_HOURLY_LIMIT, hitRateLimit, isValidDeviceId } from "../ratelimit";

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

  const rawId = typeof body.device_id === "string" ? body.device_id.trim() : "";
  if (!UUID_RE.test(rawId)) return c.json({ error: "invalid_device_id" }, 400);
  // R40 — canonical (lowercase) form is what gets stored and looked up
  // everywhere, so two requests for the same physical device always land on
  // the same devices.id row regardless of which case the client sent.
  const id = canonicalDeviceId(rawId);

  // I1 — the route used to trust body.device_id alone, so anyone could mint
  // device rows (and steer the Kroger sweep's pair set via location_id) with
  // no proof they own the id. X-Device-Id must be the UUID the app actually
  // sends (DeviceIdentity.current) and must name *this* device, matching the
  // enforcement already on /v1/kroger/* (routes/kroger.ts).
  const headerDeviceId = canonicalDeviceId(c.req.header("x-device-id") ?? "");
  if (!isValidDeviceId(headerDeviceId) || headerDeviceId !== id) {
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
  // next upsert retries (upsertDevice leaves pro_until/app_account_token
  // alone when `verified` is null).
  //
  // C1 (final review) — a verified JWS whose appAccountToken names a
  // *different* device id is no longer discarded; it's a rebind candidate.
  // `entitlement` is non-null only when entitlementFromJWS() walked the JWS's
  // certificate chain up to Apple's pinned root, verified every signature in
  // it, and confirmed Apple's own bundle-id/environment claims — nobody can
  // mint one naming an arbitrary appAccountToken. So the only way to ever
  // possess a JWS carrying some device's token is to already hold that exact
  // purchase's receipt: the legitimate purchaser reinstalling or moving to a
  // new device, which is exactly the case this exists to fix, not an
  // attacker guessing ids. (A JWS is never logged or persisted — R34 — so
  // there's no server-side leak surface either; the narrowest theoretical
  // replay would require capturing someone else's request over TLS or their
  // own device, the same bar as stealing any other bearer credential.)
  // `isValidDeviceId` guards against a malformed/garbage token being treated
  // as a rebind target — it must actually look like a device id.
  const entitlement = await entitlementFromJWS(transactionJws, new Date(), trustAnchor(c.env));
  const verified =
    entitlement && (entitlement.appAccountToken === id || isValidDeviceId(entitlement.appAccountToken))
      ? entitlement
      : null;
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
      location_id: locationId(body.location_id),
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

/**
 * I3 — unlike `text()`, an explicit empty string must survive as `""` (not
 * collapse to `null`) so `upsertDevice`'s `COALESCE(excluded.location_id,
 * devices.location_id)` writes it instead of skipping it: `location_id: ""`
 * means "the shopper cleared their store," and only a real NULL bind means
 * "the key was absent, leave the stored value alone." A key that is absent
 * (`undefined`), the wrong type, or over-length falls through to `null`,
 * which is exactly the existing "leave it alone" behaviour.
 */
function locationId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "") return "";
  return trimmed.length > 32 ? null : trimmed;
}

/**
 * I3 — the empty-array case already distinguishes itself from "absent"
 * without special-casing: `Array.isArray([])` is true, so this returns `[]`
 * (not `null`), and `[]` is truthy in JS, so `upsertDevice`'s `row.categories
 * ? JSON.stringify(row.categories) : null` binds `"[]"` rather than falling
 * through to `null` — `COALESCE` then writes it. `categories: []` clears a
 * device's subscribed categories; an absent key returns `null` here and
 * leaves the stored value untouched, same as always.
 */
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
