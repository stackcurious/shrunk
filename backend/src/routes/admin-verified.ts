import { Hono } from "hono";
import { insertAlertJob } from "../db";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";

export const adminVerifiedRoute = new Hono<{ Bindings: Env }>();

// Constant-time string comparison to prevent timing attacks on bearer token
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Publishes a verified case: files the alert job the five-minute drain turns
 * into pushes for everyone watching that product or brand (spec §3, §6.2).
 */
adminVerifiedRoute.post("/v1/admin/verified-case", async (c) => {
  const secret = c.env.ADMIN_SECRET ?? "";
  const header = c.req.header("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok = secret.length > 0 && header.startsWith(prefix) && constantTimeEqual(header.slice(prefix.length), secret);
  if (!ok) {
    return c.json({ error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = (await c.req.json()) as Record<string, unknown>;
  } catch {
    return c.json({ error: "invalid_case" }, 400);
  }

  const gtin = normalizeGTIN(typeof body.gtin === "string" ? body.gtin : null);
  const brandRaw = typeof body.brand === "string" ? body.brand.trim() : "";
  const brand = brandRaw && brandRaw.length <= 120 ? brandRaw : null;
  if (!gtin && !brand) return c.json({ error: "invalid_case" }, 400);

  await insertAlertJob(c.env.DB, {
    kind: "verified_case",
    gtin: gtin as string,          // insertAlertJob binds NULL for a null gtin
    brand,
    location_id: null,
    payload: JSON.stringify({ source: "curated" }),
    created_at: Math.floor(Date.now() / 1000),
  });

  return c.json({ ok: true });
});
