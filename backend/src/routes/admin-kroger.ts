import { Hono } from "hono";
import type { Env } from "../env";

export const adminKrogerRoute = new Hono<{ Bindings: Env }>();

/**
 * Spec §9 — one command removes every Kroger-derived row. Kept independent of
 * the Phase 2 admin review page on purpose: this is the lever we pull if Kroger
 * ever objects, and it must not depend on anything else still working.
 */

// Constant-time string comparison to prevent timing attacks on bearer token
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

adminKrogerRoute.post("/v1/admin/purge-kroger", async (c) => {
  const secret = c.env.ADMIN_SECRET ?? "";
  const header = c.req.header("authorization") ?? "";
  const prefix = "Bearer ";
  const ok = secret.length > 0 && header.startsWith(prefix) && constantTimeEqual(header.slice(prefix.length), secret);
  if (!ok) {
    return c.json({ error: "unauthorized" }, 401);
  }

  // C1: also remove `products` rows that are 100% Kroger-derived — created by
  // `persistKrogerProduct` (origin='kroger') and, by the time this statement
  // runs (D1 batch is sequential within one transaction), left with no
  // remaining observation of any source. A row that still has one — e.g. an
  // FDC observation later landed on a gtin Kroger created first — is kept.
  const results = await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM price_snapshots"),
    c.env.DB.prepare("DELETE FROM observations WHERE source = 'kroger'"),
    c.env.DB.prepare(
      "DELETE FROM products WHERE origin = 'kroger' AND NOT EXISTS (SELECT 1 FROM observations o WHERE o.gtin = products.gtin)",
    ),
  ]);

  return c.json({
    deleted: {
      price_snapshots: results[0].meta.changes ?? 0,
      observations: results[1].meta.changes ?? 0,
      products: results[2].meta.changes ?? 0,
    },
  });
});
