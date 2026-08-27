import { APPLE_ROOT_CA_G3_DER, base64ToBytes, bytesEqual } from "./root";
import { ecdsaDerToRaw, importPublicKey, parseCertificate, type Certificate } from "./x509";

export const SHRUNK_BUNDLE_ID = "com.shrunk.app";

/** JWSTransactionDecodedPayload, narrowed to the fields Shrunk uses. */
export interface DecodedTransaction {
  bundleId: string;
  productId: string;
  transactionId: string;
  originalTransactionId: string;
  appAccountToken: string | null;
  expiresDateMs: number | null;    // Apple sends milliseconds
  revocationDateMs: number | null;
  environment: string;
  /** Minor 2 — falls back to the verification instant if absent. */
  signedDateMs: number;
}

/** responseBodyV2DecodedPayload, narrowed to the fields Shrunk uses. */
export interface DecodedNotification {
  notificationType: string;
  subtype: string | null;
  notificationUUID: string;
  bundleId: string;
  signedTransactionInfo: string | null;
  /** I4 — Apple sends this in ms; falls back to the verification instant if absent. */
  signedDateMs: number;
}

function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return base64ToBytes(padded + "=".repeat((4 - (padded.length % 4)) % 4));
}

function decodeJSON(segment: string): unknown | null {
  try {
    return JSON.parse(new TextDecoder().decode(base64UrlToBytes(segment)));
  } catch {
    return null;
  }
}

/**
 * Verifies an Apple JWS end to end and returns its decoded payload, or null.
 *
 * Pure: no D1, no fetch, no Env, no secrets. `rootDer` is the trust anchor —
 * Apple's root in production, a generated root in tests.
 *
 * Checks, in order: three segments; ES256 header with an x5c chain; every
 * certificate parses; the last certificate is byte-for-byte the trusted root;
 * every certificate is inside its validity window at `now`; each certificate's
 * issuer Name matches its parent's subject Name and its signature verifies
 * under the parent's key; the JWS signature verifies under the leaf's key.
 */
export async function verifyAndDecodePayload<T>(
  jws: string,
  now: Date,
  rootDer: Uint8Array = APPLE_ROOT_CA_G3_DER,
): Promise<T | null> {
  const parts = jws.split(".");
  if (parts.length !== 3) return null;

  const header = decodeJSON(parts[0]) as { alg?: string; x5c?: string[] } | null;
  if (!header || header.alg !== "ES256") return null;
  if (!Array.isArray(header.x5c) || header.x5c.length < 2) return null;

  let chain: Certificate[];
  try {
    chain = header.x5c.map((certificate) => parseCertificate(base64ToBytes(certificate)));
  } catch {
    return null;
  }

  if (!bytesEqual(chain[chain.length - 1].der, rootDer)) return null;

  for (const certificate of chain) {
    if (now < certificate.notBefore || now > certificate.notAfter) return null;
  }

  let leafKey: CryptoKey | null = null;
  for (let i = 0; i < chain.length - 1; i++) {
    const child = chain[i];
    const parent = chain[i + 1];
    if (!bytesEqual(child.issuer, parent.subject)) return null;
    const parentKey = await importPublicKey(parent);
    const signature = ecdsaDerToRaw(child.signatureDer, parent.curve === "P-384" ? 48 : 32);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: child.sigHash },
      parentKey,
      signature,
      new Uint8Array(child.tbs),
    );
    if (!ok) return null;
    if (i === 0) leafKey = await importPublicKey(child);
  }
  if (!leafKey) return null;

  const signature = base64UrlToBytes(parts[2]);
  if (signature.length !== 64) return null; // ES256 is always r||s over P-256
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    signature,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  if (!valid) return null;

  return decodeJSON(parts[1]) as T | null;
}

export async function verifyAndDecode(
  jws: string,
  now: Date,
  rootDer: Uint8Array = APPLE_ROOT_CA_G3_DER,
): Promise<DecodedTransaction | null> {
  const payload = await verifyAndDecodePayload<Record<string, unknown>>(jws, now, rootDer);
  if (!payload) return null;

  const { bundleId, productId, transactionId, originalTransactionId, environment } = payload;
  if (typeof bundleId !== "string" || typeof productId !== "string" || typeof transactionId !== "string") {
    return null;
  }

  return {
    bundleId,
    productId,
    transactionId,
    originalTransactionId: typeof originalTransactionId === "string" ? originalTransactionId : transactionId,
    appAccountToken: typeof payload.appAccountToken === "string" ? payload.appAccountToken : null,
    expiresDateMs: typeof payload.expiresDate === "number" ? payload.expiresDate : null,
    revocationDateMs: typeof payload.revocationDate === "number" ? payload.revocationDate : null,
    environment: typeof environment === "string" ? environment : "Production",
    signedDateMs: typeof payload.signedDate === "number" ? payload.signedDate : now.getTime(),
  };
}

export async function verifyAndDecodeNotification(
  jws: string,
  now: Date,
  rootDer: Uint8Array = APPLE_ROOT_CA_G3_DER,
): Promise<DecodedNotification | null> {
  const payload = await verifyAndDecodePayload<Record<string, any>>(jws, now, rootDer);
  if (!payload || typeof payload.notificationType !== "string") return null;
  const data = (payload.data ?? {}) as Record<string, unknown>;
  return {
    notificationType: payload.notificationType,
    subtype: typeof payload.subtype === "string" ? payload.subtype : null,
    notificationUUID: typeof payload.notificationUUID === "string" ? payload.notificationUUID : "",
    bundleId: typeof data.bundleId === "string" ? data.bundleId : "",
    signedTransactionInfo: typeof data.signedTransactionInfo === "string" ? data.signedTransactionInfo : null,
    signedDateMs: typeof payload.signedDate === "number" ? payload.signedDate : now.getTime(),
  };
}
