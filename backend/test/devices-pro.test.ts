import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { bytesToBase64 } from "../src/appstore/root";
import { newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const DEVICE_ID = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
const TOKEN = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const OTHER_DEVICE_ID = "11111111-2222-3333-4444-555555555555";
const EXPIRES_MS = Date.UTC(2026, 8, 26);

// I3: fixtures below are Sandbox transactions (TestFlight/dev, per the
// README's guidance) — allow both so this file stays about JWS/rebind
// behaviour; the environment-allowlist test overrides this explicitly.
function testEnv(chain: TestChain, overrides: Record<string, unknown> = {}) {
  return {
    ...env,
    APPSTORE_ROOT_CA_B64: bytesToBase64(chain.rootDer),
    APPSTORE_ALLOWED_ENVIRONMENTS: "Sandbox,Production",
    ...overrides,
  };
}

function transaction(overrides: Record<string, unknown> = {}) {
  return {
    bundleId: "com.shrunk.app",
    productId: "com.shrunk.pro.monthly",
    transactionId: "2000000900000002",
    originalTransactionId: "2000000900000002",
    appAccountToken: TOKEN,
    expiresDate: EXPIRES_MS,
    environment: "Sandbox",
    ...overrides,
  };
}

// I1: X-Device-Id is now required and must match body.device_id — every real
// call site already sends it, so derive it from the body like ShrunkAPIClient does.
async function postDevice(body: Record<string, unknown>, routeEnv: typeof env) {
  return app.request(
    "/v1/devices",
    {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Device-Id": String(body.device_id ?? "") },
      body: JSON.stringify(body),
    },
    routeEnv,
  );
}

// R40: devices.id is now stored canonicalized (lowercase), regardless of
// which case the request used — lowercase the lookup key too.
async function deviceRow(id: string = DEVICE_ID) {
  return env.DB.prepare("SELECT pro_until, app_account_token FROM devices WHERE id = ?")
    .bind(id.toLowerCase())
    .first<{ pro_until: number | null; app_account_token: string | null }>();
}

/**
 * R44: makes upsertDevice's *entitlement* write (db.ts's two
 * `UPDATE devices SET pro_until ...` statements) fail every time, without
 * touching anything else — simulates the narrow cross-request race the
 * try/catch in db.ts guards against. Built the same way as
 * observations.test.ts's `brokenPhotos`: real bound methods, not a spread
 * (D1Database's methods live on its prototype, not as own properties).
 */
function dbFailingEntitlementWrite(realDB: typeof env.DB): typeof env.DB {
  const FAIL = Symbol("fail");
  const prepare = realDB.prepare.bind(realDB);
  const batch = realDB.batch.bind(realDB);
  return {
    prepare(sql: string) {
      const stmt = prepare(sql);
      if (!sql.startsWith("UPDATE devices SET pro_until")) return stmt;
      const bind = stmt.bind.bind(stmt);
      return Object.assign(stmt, {
        bind: (...args: unknown[]) => Object.assign(bind(...args), { [FAIL]: true }),
      });
    },
    batch: (statements: D1PreparedStatement[]) => {
      if (statements.some((s) => (s as unknown as Record<symbol, boolean>)[FAIL])) {
        return Promise.reject(new Error("simulated entitlement write failure"));
      }
      return batch(statements);
    },
  } as unknown as typeof env.DB;
}

describe("POST /v1/devices — subscription verification", () => {
  let chain: TestChain;

  beforeEach(async () => {
    chain = await newTestChain();
    await env.DB.prepare("DELETE FROM devices").run();
  });

  it("sets pro_until and the lowercased app account token from a valid JWS, and never persists the JWS itself (R34)", async () => {
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await deviceRow()).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });

    const jwsColumn = await env.DB.prepare("SELECT transaction_jws FROM devices WHERE id = ?")
      .bind(DEVICE_ID.toLowerCase())   // R42: devices.id is stored canonicalized (lowercase)
      .first<{ transaction_jws: string | null }>();
    expect(jwsColumn!.transaction_jws).toBeNull();
  });

  it("leaves an existing pro_until untouched when the JWS does not verify (spec §8)", async () => {
    const jws = await signTestJWS(chain, transaction());
    await postDevice({ device_id: DEVICE_ID, transaction_jws: jws }, testEnv(chain));

    // Same JWS, but the route now verifies against Apple's real root and fails.
    const res = await postDevice({ device_id: DEVICE_ID, transaction_jws: jws }, env);
    expect(res.status).toBe(200);
    expect(await deviceRow()).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
  });

  it("grants nothing for a foreign bundle id", async () => {
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction({ bundleId: "com.someone.else" })) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await deviceRow()).toEqual({ pro_until: null, app_account_token: null });
  });

  it("upserts a device with no transaction at all", async () => {
    const res = await postDevice({ device_id: DEVICE_ID, location_id: "01400943", categories: ["snacks"] }, env);
    expect(res.status).toBe(200);
    expect(await deviceRow()).toEqual({ pro_until: null, app_account_token: null });
  });

  it("C1: rebinds Pro to the posting device when a verified appAccountToken names a different device, and clears the old row", async () => {
    // DEVICE_ID purchases first — its own token (TOKEN) lands on its row.
    await postDevice({ device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) }, testEnv(chain));
    expect(await deviceRow(DEVICE_ID)).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });

    // The same App Store transaction (same JWS, appAccountToken = TOKEN) is
    // now presented by OTHER_DEVICE_ID — a reinstall/new-device scenario.
    const res = await postDevice(
      { device_id: OTHER_DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: true });

    // The entitlement moved: OTHER_DEVICE_ID now carries it...
    expect(await deviceRow(OTHER_DEVICE_ID)).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
    // ...and DEVICE_ID's old row lost it, so only one row is ever Pro for this token.
    expect(await deviceRow(DEVICE_ID)).toEqual({ pro_until: null, app_account_token: null });
  });

  it("C1: does not grant Pro when the verified appAccountToken isn't a device-id-shaped value", async () => {
    const res = await postDevice(
      { device_id: OTHER_DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction({ appAccountToken: "not-a-device-id" })) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });
    expect(await deviceRow(OTHER_DEVICE_ID)).toEqual({ pro_until: null, app_account_token: null });
  });

  it("R44: the original device can re-sync its own token after another device rebinds it, without erroring", async () => {
    // A purchases.
    await postDevice({ device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) }, testEnv(chain));
    expect(await deviceRow(DEVICE_ID)).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });

    // B rebinds — the reinstall/new-device scenario C1 exists for.
    await postDevice({ device_id: OTHER_DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) }, testEnv(chain));
    expect(await deviceRow(OTHER_DEVICE_ID)).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
    expect(await deviceRow(DEVICE_ID)).toEqual({ pro_until: null, app_account_token: null });

    // A re-syncs its own still-valid receipt (appAccountToken === its own
    // id) — the bug: the old rebind logic skipped the clear whenever the
    // token equalled the posting device's own id, so this collided with
    // devices_account_unique (B still held the token) and threw a 500.
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: true });

    // Exactly one row holds the token now: A.
    expect(await deviceRow(DEVICE_ID)).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
    const holders = await env.DB.prepare("SELECT id FROM devices WHERE app_account_token = ?")
      .bind(TOKEN)
      .all<{ id: string }>();
    expect(holders.results).toEqual([{ id: DEVICE_ID.toLowerCase() }]);

    // B's next ordinary sync (no JWS) now reports pro:false.
    const bRes = await postDevice({ device_id: OTHER_DEVICE_ID }, testEnv(chain));
    expect(await bRes.json()).toEqual({ ok: true, pro: false });
  });

  it("R44: an entitlement-write failure still persists the apns token and watches, and reports pro:false", async () => {
    const routeEnv = { ...testEnv(chain), DB: dbFailingEntitlementWrite(env.DB) };
    const res = await postDevice(
      {
        device_id: DEVICE_ID,
        apns_token: "a1b2c3",
        watches: [{ gtin: "0028400642255", brand: "Gatorade" }],
        transaction_jws: await signTestJWS(chain, transaction()),
      },
      routeEnv,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });

    // Entitlement never landed...
    expect(await deviceRow()).toEqual({ pro_until: null, app_account_token: null });
    // ...but everything else in the same sync did.
    const device = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = ?")
      .bind(DEVICE_ID.toLowerCase())
      .first<{ apns_token: string | null }>();
    expect(device?.apns_token).toBe("a1b2c3");
    const watchRows = await env.DB.prepare("SELECT gtin FROM watches WHERE device_id = ?")
      .bind(DEVICE_ID.toLowerCase())
      .all<{ gtin: string }>();
    expect(watchRows.results.map((w) => w.gtin)).toEqual(["0028400642255"]);
  });

  it("sets a past pro_until for an expired-but-signature-valid receipt, and reports pro:false", async () => {
    const pastMs = Date.UTC(2020, 0, 1);
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction({ expiresDate: pastMs })) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });
    expect(await deviceRow()).toEqual({ pro_until: Math.floor(pastMs / 1000), app_account_token: TOKEN });
  });

  it("I3: grants nothing for a Sandbox transaction when only Production is allowed (the default)", async () => {
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain, { APPSTORE_ALLOWED_ENVIRONMENTS: "Production" }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });
    expect(await deviceRow()).toEqual({ pro_until: null, app_account_token: null });
  });

  it("I3: grants Pro for a Production transaction when only Production is allowed", async () => {
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction({ environment: "Production" })) },
      testEnv(chain, { APPSTORE_ALLOWED_ENVIRONMENTS: "Production" }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: true });
    expect(await deviceRow()).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
  });

  async function entitlementUpdatedAt(id: string = DEVICE_ID) {
    const row = await env.DB.prepare("SELECT entitlement_updated_at FROM devices WHERE id = ?")
      .bind(id.toLowerCase())
      .first<{ entitlement_updated_at: number | null }>();
    return row?.entitlement_updated_at ?? null;
  }

  it("Minor 2: a verified sync sets entitlement_updated_at from the transaction's own signedDate", async () => {
    const signedDateMs = Date.UTC(2026, 7, 20);
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction({ signedDate: signedDateMs })) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await entitlementUpdatedAt()).toBe(Math.floor(signedDateMs / 1000));
  });

  it("Minor 2: falls back to the sync's own now when the transaction carries no signedDate", async () => {
    const before = Math.floor(Date.now() / 1000);
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    const updatedAt = await entitlementUpdatedAt();
    expect(updatedAt).not.toBeNull();
    expect(updatedAt!).toBeGreaterThanOrEqual(before);
    expect(updatedAt!).toBeLessThanOrEqual(Math.floor(Date.now() / 1000));
  });

  it("Minor 2: an unverified sync (no JWS) leaves entitlement_updated_at untouched", async () => {
    const res = await postDevice({ device_id: DEVICE_ID, location_id: "01400943" }, env);
    expect(res.status).toBe(200);
    expect(await entitlementUpdatedAt()).toBeNull();
  });
});
