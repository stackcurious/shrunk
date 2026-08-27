import { beforeAll, describe, expect, it } from "vitest";
import { APPLE_ROOT_CA_G3_DER } from "../src/appstore/root";
import { verifyAndDecode, verifyAndDecodeNotification } from "../src/appstore/jws";
import { base64UrlEncode, newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const NOW = new Date("2026-08-26T00:00:00Z");
const EXPIRES_MS = Date.UTC(2026, 8, 26); // 2026-09-26

function transaction(overrides: Record<string, unknown> = {}) {
  return {
    bundleId: "com.shrunk.app",
    productId: "com.shrunk.pro.yearly",
    transactionId: "2000000900000001",
    originalTransactionId: "2000000900000001",
    appAccountToken: "6f9619ff-8b86-d011-b42d-00cf4fc964ff",
    expiresDate: EXPIRES_MS,
    environment: "Sandbox",
    ...overrides,
  };
}

describe("verifyAndDecode", () => {
  let chain: TestChain;
  beforeAll(async () => {
    chain = await newTestChain();
  });

  it("decodes a transaction signed by a valid chain", async () => {
    const jws = await signTestJWS(chain, transaction());
    const decoded = await verifyAndDecode(jws, NOW, chain.rootDer);
    expect(decoded).toEqual({
      bundleId: "com.shrunk.app",
      productId: "com.shrunk.pro.yearly",
      transactionId: "2000000900000001",
      originalTransactionId: "2000000900000001",
      appAccountToken: "6f9619ff-8b86-d011-b42d-00cf4fc964ff",
      expiresDateMs: EXPIRES_MS,
      revocationDateMs: null,
      environment: "Sandbox",
      // Minor 2 — the payload carries no signedDate, so it falls back to
      // the verification instant.
      signedDateMs: NOW.getTime(),
    });
  });

  it("Minor 2: extracts the transaction's own signedDate when Apple sends one", async () => {
    const signedDateMs = Date.UTC(2026, 7, 20);
    const jws = await signTestJWS(chain, transaction({ signedDate: signedDateMs }));
    const decoded = await verifyAndDecode(jws, NOW, chain.rootDer);
    expect(decoded?.signedDateMs).toBe(signedDateMs);
  });

  it("still decodes a transaction for the wrong bundle id, reporting that bundle id", async () => {
    const jws = await signTestJWS(chain, transaction({ bundleId: "com.someone.else" }));
    const decoded = await verifyAndDecode(jws, NOW, chain.rootDer);
    expect(decoded?.bundleId).toBe("com.someone.else");
  });

  it("rejects a chain that does not end at the trusted root", async () => {
    const jws = await signTestJWS(chain, transaction());
    expect(await verifyAndDecode(jws, NOW, APPLE_ROOT_CA_G3_DER)).toBeNull();
  });

  it("rejects a chain whose certificates have expired", async () => {
    const expired = await newTestChain({
      notBefore: new Date("2019-01-01T00:00:00Z"),
      notAfter: new Date("2021-01-01T00:00:00Z"),
    });
    const jws = await signTestJWS(expired, transaction());
    expect(await verifyAndDecode(jws, NOW, expired.rootDer)).toBeNull();
    // ...and accepts it inside its window, proving expiry is what failed.
    expect(await verifyAndDecode(jws, new Date("2020-06-01T00:00:00Z"), expired.rootDer)).not.toBeNull();
  });

  it("rejects a tampered payload", async () => {
    const jws = await signTestJWS(chain, transaction());
    const [header, , signature] = jws.split(".");
    const forged = base64UrlEncode(
      new TextEncoder().encode(JSON.stringify(transaction({ expiresDate: 9999999999999 }))),
    );
    expect(await verifyAndDecode(`${header}.${forged}.${signature}`, NOW, chain.rootDer)).toBeNull();
  });

  it("rejects a malformed JWS and an unsupported algorithm", async () => {
    expect(await verifyAndDecode("not-a-jws", NOW, chain.rootDer)).toBeNull();
    const rs256 = `${base64UrlEncode(new TextEncoder().encode(JSON.stringify({ alg: "RS256", x5c: [] })))}.e30.e30`;
    expect(await verifyAndDecode(rs256, NOW, chain.rootDer)).toBeNull();
  });
});

describe("verifyAndDecodeNotification", () => {
  it("extracts the notification type and the nested signed transaction", async () => {
    const chain = await newTestChain();
    const inner = await signTestJWS(chain, transaction());
    const jws = await signTestJWS(chain, {
      notificationType: "DID_RENEW",
      subtype: null,
      notificationUUID: "0b1b8f4a-1111-2222-3333-444455556666",
      version: "2.0",
      signedDate: NOW.getTime(),
      data: { bundleId: "com.shrunk.app", environment: "Sandbox", signedTransactionInfo: inner },
    });

    const decoded = await verifyAndDecodeNotification(jws, NOW, chain.rootDer);
    expect(decoded?.notificationType).toBe("DID_RENEW");
    expect(decoded?.bundleId).toBe("com.shrunk.app");
    expect(decoded?.signedTransactionInfo).toBe(inner);
  });
});
