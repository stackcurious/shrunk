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

  // I4 — Apple does not guarantee delivery order and retries a failed
  // delivery for up to three days, so a stale/duplicate notification must
  // not clobber a more recent one (e.g. a retried DID_RENEW landing after a
  // REFUND must not restore Pro). Both guards live in the UPDATE's WHERE
  // clause so the check-and-write is one atomic statement: `updated` stays
  // false, and the row untouched, whenever either guard fails.
  //  - duplicate: this exact notificationUUID was already applied.
  //  - out of order: a notification already applied is signed *after* this one.
  const signedAtSeconds = Math.floor(notification.signedDateMs / 1000);
  const notificationUUID = notification.notificationUUID || null;

  const result = await c.env.DB.prepare(
    `UPDATE devices
       SET pro_until = ?, entitlement_updated_at = ?, last_notification_uuid = ?, updated_at = ?
     WHERE app_account_token = ?
       AND (last_notification_uuid IS NULL OR last_notification_uuid <> ?)
       AND (entitlement_updated_at IS NULL OR entitlement_updated_at < ?)`,
  )
    .bind(
      proUntil,
      signedAtSeconds,
      notificationUUID,
      Math.floor(now.getTime() / 1000),
      tx.appAccountToken.toLowerCase(),
      notificationUUID,
      signedAtSeconds,
    )
    .run();

  return c.json({
    ok: true,
    updated: (result.meta.changes ?? 0) > 0,
    notificationType: notification.notificationType,
  });
});
