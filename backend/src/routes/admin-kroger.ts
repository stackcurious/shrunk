import { Hono } from "hono";
import type { Env } from "../env";

export const adminKrogerRoute = new Hono<{ Bindings: Env }>();

/**
 * Spec §9 — one command removes every Kroger-derived row. Kept independent of
 * the Phase 2 admin review page on purpose: this is the lever we pull if Kroger
 * ever objects, and it must not depend on anything else still working.
 */
adminKrogerRoute.post("/v1/admin/purge-kroger", async (c) => {
  const expected = `Bearer ${c.env.ADMIN_SECRET}`;
  if (!c.env.ADMIN_SECRET || c.req.header("authorization") !== expected) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const snapshots = await c.env.DB.prepare("DELETE FROM price_snapshots").run();
  const observations = await c.env.DB.prepare("DELETE FROM observations WHERE source = 'kroger'").run();

  return c.json({
    deleted: {
      price_snapshots: snapshots.meta.changes ?? 0,
      observations: observations.meta.changes ?? 0,
    },
  });
});
