import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { bytesToBase64 } from "../src/appstore/root";
import { newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const DEVICE_ID = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
const TOKEN = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
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

async function postDevice(body: Record<string, unknown>, routeEnv: typeof env) {
  return app.request(
    "/v1/devices",
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) },
    routeEnv,
  );
}

async function deviceRow() {
  return env.DB.prepare("SELECT pro_until, app_account_token FROM devices WHERE id = ?")
    .bind(DEVICE_ID)
    .first<{ pro_until: number | null; app_account_token: string | null }>();
}

describe("POST /v1/devices — subscription verification", () => {
  let chain: TestChain;

  beforeEach(async () => {
    chain = await newTestChain();
    await env.DB.prepare("DELETE FROM devices").run();
  });

  it("sets pro_until and the lowercased app account token from a valid JWS", async () => {
    const res = await postDevice(
      { device_id: DEVICE_ID, transaction_jws: await signTestJWS(chain, transaction()) },
      testEnv(chain),
    );
    expect(res.status).toBe(200);
    expect(await deviceRow()).toEqual({ pro_until: Math.floor(EXPIRES_MS / 1000), app_account_token: TOKEN });
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
});
