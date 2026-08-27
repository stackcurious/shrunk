import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { bytesToBase64 } from "../src/appstore/root";
import { newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const DEVICE_ID = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
const TOKEN = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const OTHER_DEVICE_ID = "11111111-2222-3333-4444-555555555555";
const EXPIRES_MS = Date.UTC(2026, 8, 26);

function testEnv(chain: TestChain) {
  return { ...env, APPSTORE_ROOT_CA_B64: bytesToBase64(chain.rootDer) };
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
});
