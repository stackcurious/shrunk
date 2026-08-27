import { SHRUNK_BUNDLE_ID, verifyAndDecode, type DecodedTransaction } from "./jws";
import { APPLE_ROOT_CA_G3_DER, base64ToBytes } from "./root";

/** Apple's root in production; a generated root when a test supplies one. */
export function trustAnchor(env: { APPSTORE_ROOT_CA_B64?: string }): Uint8Array {
  return env.APPSTORE_ROOT_CA_B64 ? base64ToBytes(env.APPSTORE_ROOT_CA_B64) : APPLE_ROOT_CA_G3_DER;
}

/**
 * The unix second at which Pro lapses for this transaction, or null when the
 * transaction must not grant anything: a foreign bundle id, or a transaction
 * with no expiry (a non-subscription purchase).
 *
 * A refunded or revoked transaction ends at its revocation date, not its
 * original expiry — otherwise a refund would leave Pro running.
 */
export function proUntilSeconds(tx: DecodedTransaction, bundleId: string = SHRUNK_BUNDLE_ID): number | null {
  if (tx.bundleId !== bundleId) return null;
  if (tx.revocationDateMs != null) return Math.floor(tx.revocationDateMs / 1000);
  if (tx.expiresDateMs == null) return null;
  return Math.floor(tx.expiresDateMs / 1000);
}

export interface VerifiedEntitlement {
  appAccountToken: string; // lowercased
  proUntil: number;        // unix seconds
}

/** Verify a device-supplied transaction JWS. Null means "grant nothing". */
export async function entitlementFromJWS(
  jws: string | null | undefined,
  now: Date,
  rootDer?: Uint8Array,
): Promise<VerifiedEntitlement | null> {
  if (!jws) return null;
  const tx = await verifyAndDecode(jws, now, rootDer);
  if (!tx || !tx.appAccountToken) return null;
  const proUntil = proUntilSeconds(tx);
  if (proUntil == null) return null;
  return { appAccountToken: tx.appAccountToken.toLowerCase(), proUntil };
}
