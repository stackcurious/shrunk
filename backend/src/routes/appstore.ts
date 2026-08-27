import { Hono } from "hono";
import type { Env } from "../env";
import { allowedAppstoreEnvironments, proUntilSeconds, trustAnchor } from "../appstore/entitlement";
import { verifyAndDecode, verifyAndDecodeNotification } from "../appstore/jws";

export const appstoreRoute = new Hono<{ Bindings: Env }>();

/**
 * App Store Server Notifications V2 (spec §6.1). Apple retries any non-2xx, so
 * only a genuinely unverifiable payload returns an error status; notifications
 * we simply have nothing to do with return 200 with `updated: false`.
 */
appstoreRoute.post("/v1/appstore/notifications", async (c) => {
  let body: { signedPayload?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid_body" }, 400);
  }
  if (typeof body.signedPayload !== "string") return c.json({ error: "invalid_body" }, 400);

  const now = new Date();
  const root = trustAnchor(c.env);
  const notification = await verifyAndDecodeNotification(body.signedPayload, now, root);
  if (!notification) {
    console.warn("appstore: notification signature did not verify");
    return c.json({ error: "invalid_signature" }, 401);
  }
  if (!notification.signedTransactionInfo) {
    return c.json({ ok: true, updated: false, reason: "no_transaction", notificationType: notification.notificationType });
  }

  const tx = await verifyAndDecode(notification.signedTransactionInfo, now, root);
  if (!tx) {
    console.warn("appstore: transaction signature did not verify", notification.notificationUUID);
    return c.json({ error: "invalid_signature" }, 401);
  }

  // I3 — an environment this Worker doesn't accept (Sandbox in production,
  // by default) is ignored entirely: no Pro grant, no state written.
  // See appstore/entitlement.ts.
  if (!allowedAppstoreEnvironments(c.env).has(tx.environment)) {
    return c.json({
      ok: true,
      updated: false,
      reason: "environment_not_allowed",
      notificationType: notification.notificationType,
    });
  }

  const proUntil = proUntilSeconds(tx);
  if (proUntil == null || !tx.appAccountToken) {
    return c.json({ ok: true, updated: false, reason: "not_applicable", notificationType: notification.notificationType });
  }

  const result = await c.env.DB.prepare(
    "UPDATE devices SET pro_until = ?, updated_at = ? WHERE app_account_token = ?",
  )
    .bind(proUntil, Math.floor(now.getTime() / 1000), tx.appAccountToken.toLowerCase())
    .run();

  return c.json({
    ok: true,
    updated: (result.meta.changes ?? 0) > 0,
    notificationType: notification.notificationType,
  });
});
