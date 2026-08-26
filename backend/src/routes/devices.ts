import { Hono } from "hono";
import { getDevice, replaceWatches, upsertDevice, type WatchInput } from "../db";
import type { Env } from "../env";
import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";

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

  const now = Math.floor(Date.now() / 1000);
  await upsertDevice(
    c.env.DB,
    {
      id,
      apns_token: text(body.apns_token, MAX_TOKEN_LENGTH),
      location_id: text(body.location_id, 32),
      categories: categories(body.categories),
      prefs: prefs(body.prefs),
      app_account_token: text(body.app_account_token, 64),
      transaction_jws: text(body.transaction_jws, 8192),
    },
    now
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
