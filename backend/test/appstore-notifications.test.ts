import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { bytesToBase64 } from "../src/appstore/root";
import { newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const TOKEN = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const EXPIRES_MS = Date.UTC(2026, 8, 26); // 2026-09-26T00:00:00Z

/**
 * The env the route sees, with the generated root as its trust anchor.
 * I3: fixtures below are Sandbox transactions (TestFlight/dev), so allow
 * both by default; the environment-allowlist tests override this.
 */
function testEnv(chain: TestChain, overrides: Record<string, unknown> = {}) {
  return {
    ...env,
    APPSTORE_ROOT_CA_B64: bytesToBase64(chain.rootDer),
    APPSTORE_ALLOWED_ENVIRONMENTS: "Sandbox,Production",
    ...overrides,
  };
}

async function notificationJWS(
  chain: TestChain,
  tx: Record<string, unknown>,
  type = "DID_RENEW",
  notificationOverrides: Record<string, unknown> = {},
) {
  const inner = await signTestJWS(chain, tx);
  return signTestJWS(chain, {
    notificationType: type,
    notificationUUID: "0b1b8f4a-1111-2222-3333-444455556666",
    version: "2.0",
    signedDate: Date.now(),
    data: { bundleId: "com.shrunk.app", environment: "Sandbox", signedTransactionInfo: inner },
    ...notificationOverrides,
  });
}

function transaction(overrides: Record<string, unknown> = {}) {
  return {
    bundleId: "com.shrunk.app",
    productId: "com.shrunk.pro.yearly",
    transactionId: "2000000900000001",
    originalTransactionId: "2000000900000001",
    appAccountToken: TOKEN,
    expiresDate: EXPIRES_MS,
    environment: "Sandbox",
    ...overrides,
  };
}

describe("POST /v1/appstore/notifications", () => {
  let chain: TestChain;

  beforeEach(async () => {
    chain = await newTestChain();
    await env.DB.prepare("DELETE FROM devices").run();
    await env.DB.prepare(
      "INSERT INTO devices (id, apns_token, location_id, categories, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, NULL, NULL, '[]', NULL, ?, NULL, 1)",
    ).bind("6F9619FF-8B86-D011-B42D-00CF4FC964FF", TOKEN).run();
  });

  /** `routeEnv` defaults to the test anchor; pass `env` to use Apple's real root. */
  async function post(body: unknown, routeEnv: Record<string, unknown> | typeof env = testEnv(chain)) {
    return app.request(
      "/v1/appstore/notifications",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) },
      routeEnv,
    );
  }

  it("sets pro_until from expiresDate for the matching app account token", async () => {
    const res = await post({ signedPayload: await notificationJWS(chain, transaction()) });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, updated: true, notificationType: "DID_RENEW" });

    const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
      .bind(TOKEN)
      .first<{ pro_until: number }>();
    expect(row?.pro_until).toBe(Math.floor(EXPIRES_MS / 1000));
  });

  it("uses revocationDate when the transaction was refunded", async () => {
    const revokedAt = Date.UTC(2026, 7, 1);
    await post({
      signedPayload: await notificationJWS(chain, transaction({ revocationDate: revokedAt }), "REFUND"),
    });
    const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
      .bind(TOKEN)
      .first<{ pro_until: number }>();
    expect(row?.pro_until).toBe(Math.floor(revokedAt / 1000));
  });

  it("ignores a transaction for another bundle id", async () => {
    const res = await post({
      signedPayload: await notificationJWS(chain, transaction({ bundleId: "com.someone.else" })),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ ok: true, updated: false, reason: "not_applicable" });

    const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
      .bind(TOKEN)
      .first<{ pro_until: number | null }>();
    expect(row?.pro_until).toBeNull();
  });

  it("reports updated:false when no device carries that token yet", async () => {
    const res = await post({
      signedPayload: await notificationJWS(chain, transaction({ appAccountToken: "11111111-2222-3333-4444-555555555555" })),
    });
    expect(await res.json()).toMatchObject({ ok: true, updated: false });
  });

  it("rejects a payload that does not verify against Apple's root", async () => {
    // No APPSTORE_ROOT_CA_B64 => trustAnchor() falls back to the real Apple root.
    const res = await post({ signedPayload: await notificationJWS(chain, transaction()) }, env);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "invalid_signature" });
  });

  it("rejects a body without a signedPayload string", async () => {
    const res = await post({ nope: true });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_body" });
  });

  describe("I3: environment allowlist", () => {
    it("ignores a Sandbox transaction when only Production is allowed (the default)", async () => {
      const res = await post(
        { signedPayload: await notificationJWS(chain, transaction()) },
        testEnv(chain, { APPSTORE_ALLOWED_ENVIRONMENTS: "Production" }),
      );
      expect(res.status).toBe(200);
      expect(await res.json()).toMatchObject({ ok: true, updated: false, reason: "environment_not_allowed" });

      const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
        .bind(TOKEN)
        .first<{ pro_until: number | null }>();
      expect(row?.pro_until).toBeNull();
    });

    it("applies a Production transaction when only Production is allowed", async () => {
      const res = await post(
        { signedPayload: await notificationJWS(chain, transaction({ environment: "Production" })) },
        testEnv(chain, { APPSTORE_ALLOWED_ENVIRONMENTS: "Production" }),
      );
      expect(await res.json()).toMatchObject({ ok: true, updated: true });

      const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
        .bind(TOKEN)
        .first<{ pro_until: number | null }>();
      expect(row?.pro_until).toBe(Math.floor(EXPIRES_MS / 1000));
    });
  });

  describe("I4: notification ordering and idempotency", () => {
    it("a duplicate delivery of the same notification is a no-op", async () => {
      const jws = await notificationJWS(chain, transaction());

      const first = await post({ signedPayload: jws });
      expect(await first.json()).toMatchObject({ ok: true, updated: true });

      const second = await post({ signedPayload: jws });
      expect(await second.json()).toMatchObject({ ok: true, updated: false });

      const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
        .bind(TOKEN)
        .first<{ pro_until: number }>();
      expect(row?.pro_until).toBe(Math.floor(EXPIRES_MS / 1000));
    });

    it("a retried DID_RENEW that arrives after a REFUND (out of order) cannot undo the refund", async () => {
      const refundSignedAt = Date.UTC(2026, 7, 1);
      const revokedAt = Date.UTC(2026, 7, 1, 0, 30);
      const staleRenewSignedAt = Date.UTC(2026, 6, 20); // earlier than the refund's signedDate

      const refundRes = await post({
        signedPayload: await notificationJWS(chain, transaction({ revocationDate: revokedAt }), "REFUND", {
          signedDate: refundSignedAt,
          notificationUUID: "uuid-refund",
        }),
      });
      expect(await refundRes.json()).toMatchObject({ ok: true, updated: true });

      const staleRenewRes = await post({
        signedPayload: await notificationJWS(chain, transaction({ expiresDate: EXPIRES_MS }), "DID_RENEW", {
          signedDate: staleRenewSignedAt,
          notificationUUID: "uuid-stale-renew",
        }),
      });
      expect(await staleRenewRes.json()).toMatchObject({ ok: true, updated: false });

      const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
        .bind(TOKEN)
        .first<{ pro_until: number }>();
      expect(row?.pro_until).toBe(Math.floor(revokedAt / 1000)); // still refunded, not restored
    });

    it("an in-order sequence of distinct notifications still applies each one", async () => {
      const t1 = Date.UTC(2026, 6, 1);
      const t2 = Date.UTC(2026, 7, 1);
      const laterExpiresMs = EXPIRES_MS + 86_400_000;

      await post({
        signedPayload: await notificationJWS(chain, transaction({ expiresDate: EXPIRES_MS }), "DID_RENEW", {
          signedDate: t1,
          notificationUUID: "uuid-seq-1",
        }),
      });
      const secondRes = await post({
        signedPayload: await notificationJWS(chain, transaction({ expiresDate: laterExpiresMs }), "DID_RENEW", {
          signedDate: t2,
          notificationUUID: "uuid-seq-2",
        }),
      });
      expect(await secondRes.json()).toMatchObject({ ok: true, updated: true });

      const row = await env.DB.prepare("SELECT pro_until FROM devices WHERE app_account_token = ?")
        .bind(TOKEN)
        .first<{ pro_until: number }>();
      expect(row?.pro_until).toBe(Math.floor(laterExpiresMs / 1000));
    });
  });
});
