# Shrunk v2 — Phase 5: Subscriptions, Onboarding Trim, Real Savings Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the lifetime IAP with a two-product auto-renewable subscription whose entitlement is verified server-side from Apple's signed transaction JWS, trim onboarding to four screens, and rebuild the savings dashboard and history-chart gating on observed data instead of invented constants.

**Architecture:** The Worker gains a self-contained App Store JWS verifier (`src/appstore/`) — a minimal DER/X.509 parser plus WebCrypto ECDSA chain verification against an embedded Apple Root CA - G3, with no Apple secrets and no outbound calls. Two entry points feed it: `POST /v1/appstore/notifications` (App Store Server Notifications V2) and the `transaction_jws` already accepted by `POST /v1/devices` (Phase 4). Both write `devices.pro_until` keyed by `app_account_token`. On iOS, `StoreKitService` derives `isPro` from `Transaction.currentEntitlements` over the subscription group, purchases with a stable per-install `appAccountToken`, and pushes the entitlement JWS to the Worker after every purchase, restore, and `Transaction.updates` event. The paywall, onboarding flow, savings dashboard, and history chart are rewritten against that entitlement and against real observations.

**Tech Stack:** TypeScript, Hono 4, Wrangler 4, Cloudflare D1, Vitest with `@cloudflare/vitest-pool-workers`, WebCrypto (ECDSA P-256/P-384) · Swift 5.9 / SwiftUI / StoreKit 2 / StoreKitTest / XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§2 Pricing, §3 Free vs Pro, §5 `devices`, §6.1 `POST /v1/appstore/notifications`, §7 Onboarding / ResultView / Savings dashboard / StoreKitService, §8 subscription verification failure, §10 Testing, §11 week 5).

**Format template:** `docs/superpowers/plans/2026-08-26-shrunk-v2-week1-data-backbone.md` (Phase 1). Phases 2–4 are assumed complete.

## Global Constraints

- **Pricing (spec §2, verbatim):** auto-renewable subscription, `com.shrunk.pro.monthly` **$2.99** and `com.shrunk.pro.yearly` **$14.99** with a **7-day introductory free trial**. The `com.shrunk.pro.lifetime` non-consumable is removed (no purchases exist).
- Both products live in **one subscription group named `Shrunk Pro`**. Entitlement is "any active subscription in the group".
- **Bundle id is `com.shrunk.app`.** A verified transaction for any other bundle id never sets `pro_until`.
- **Free vs Pro (spec §3):** Free = unlimited scans → verdict, size history, current price and cost-per-unit; browse feed; contribute label photos; 3 alternatives per scan. Pro = watchlist alerts, weekly digest, unlimited ranked alternatives, price + size history charts (**free sees the latest before/after only**), real savings dashboard.
- **Savings math (spec §3.5):** `shrink% × current unit price × purchases/yr`, from observed data. No category constants, no household/spend inputs. `SavingsForecast` is deleted.
- **Verification failure (spec §8, verbatim):** "Subscription verification failure on the Worker: device entitlement still governs the UI; Worker logs and retries on the next `/v1/devices` upsert." A failed verification never clears an existing `pro_until` and never fails the `/v1/devices` request.
- **Onboarding (spec §7, verbatim):** "welcome → pick categories → set store (skippable) → paywall with trial. `OnboardingProfile` keeps `categories` and `shopFrequency`; household/spend fields and the analyzing/reveal screens are removed."
- **Paywall (spec §7, verbatim):** "Paywall shows trial, monthly, yearly (yearly preselected, 'save 58%')."
- US only. iOS 17+, Swift 5.9. `project.yml` is the source of truth — run `xcodegen generate` after adding, removing, or renaming any Swift file or target setting.
- iOS tests: `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'`.
- Worker tests: `cd backend && npx vitest run`. Typecheck with `npx tsc --noEmit`.
- The JWS verifier is **pure**: no D1, no `fetch`, no `Env`, no secrets. Apple's root certificate is embedded as a source constant and swapped for a test root through a parameter.
- Commit after every task. Never commit `backend/node_modules`, `backend/.wrangler`, or `*.cer` downloads.

## Preflight (run once, before Task 1)

Phases 2–4 are assumed complete. These commands confirm the interfaces this plan consumes. If one fails, stop and land the missing phase first.

```bash
cd /Users/drao/Projects/shrunk
ls backend/src/routes/devices.ts                       # Phase 4: POST /v1/devices
grep -n "transaction_jws"  backend/src/routes/devices.ts
grep -rn "CREATE TABLE devices" backend/migrations/     # Phase 4: devices table
ls backend/migrations/                                  # note the highest migration number
grep -rn "struct StorePickerView" Shrunk                # Phase 3: store picker view
grep -rn "storeLocationId" Shrunk                       # Phase 3: @AppStorage key
grep -rn "device_id" Shrunk --include=*.swift           # Phase 2: device id helper, if any
grep -n "func syncDevice" Shrunk/Services/ShrunkAPIClient.swift   # Phase 4: may already exist
```

Reconciliation rules:

- **Migration number.** This plan writes `backend/migrations/0005_devices_appstore.sql`. If `0005_` is already taken, use the next unused number and rename every reference to it in Task 3. Phase 4's own migration is `0004_devices_watches.sql`, which already creates `devices` (including `transaction_jws`) and `watches` per spec §5 plus the deviation above — Phase 5's `0005` adds only the `devices_app_account_token` index.
- **`StorePickerView`.** Task 9 constructs it as `StorePickerView(embedded: true)`. If Phase 3 changed its signature, adjust that call site to match; nothing else in this plan depends on its shape.
- **`device_id`.** If Phase 2 already persists a device id **and the stored value is a UUID string**, Task 5 keeps that helper and only adds the alias described there. If Phase 2 stored a non-UUID (e.g. a random hex string), Task 5's `DeviceIdentity` becomes the single source and Phase 2's helper must be pointed at it — `appAccountToken` is a `UUID` and StoreKit accepts nothing else.
- **`syncDevice`.** If Phase 4 already added `ShrunkAPIClient.syncDevice(...)` with more parameters (apns token, location, categories, watches), give every extra parameter a default so `syncDevice(deviceId:transactionJWS:)` stays callable with exactly those two arguments. Task 5 shows the minimal version to write if it does not exist.

## Interface this phase requires from Phase 4

If Phase 4 has not been written yet, it **must** honour this, because Phase 5 tasks 4 and 5 are written against it:

**Deviation from spec §5, deliberate.** `devices` gains a `transaction_jws TEXT` column beyond the spec's printed schema (`id, apns_token, location_id, categories, pro_until, app_account_token, updated_at`), so the Worker can re-verify a previously-stored transaction on a retry (spec §8) without the device re-sending it. Phase 4's migration `backend/migrations/0004_devices_watches.sql` creates `devices` — including this column — and `watches`, both per spec §5 plus this one deviation. Phase 5 does not create or alter either table: its own migration, `0005_devices_appstore.sql` (Task 3), only adds the `devices_app_account_token` index.

- `POST /v1/devices` accepts JSON `{ device_id: string, apns_token?: string|null, location_id?: string|null, categories?: string[], watches?: [...], transaction_jws?: string|null }` and upserts into `devices(id, apns_token, location_id, categories, pro_until, app_account_token, transaction_jws, updated_at)` keyed on `id = device_id`. Phase 4 stores `transaction_jws` raw without verifying it; Phase 5 adds the verification.
- The route module is `backend/src/routes/devices.ts` and exports a Hono sub-app named `devicesRoute`, mounted in `backend/src/index.ts`.
- iOS: `ShrunkAPIClient.syncDevice(deviceId:transactionJWS:)` posts that body and never throws.

## File Structure

```
backend/
  migrations/0005_devices_appstore.sql   devices_app_account_token index only (devices/transaction_jws/watches: Phase 4's 0004)
  src/appstore/asn1.ts                   minimal DER reader (TLV, children, OID, time)
  src/appstore/x509.ts                   certificate parse, ECDSA sig conversion, key import
  src/appstore/root.ts                   Apple Root CA - G3 PEM + DER constant
  src/appstore/jws.ts                    verifyAndDecode / verifyAndDecodeNotification (pure)
  src/appstore/entitlement.ts            proUntilSeconds, entitlementFromJWS
  src/routes/appstore.ts                 POST /v1/appstore/notifications
  src/routes/devices.ts                  MODIFIED — verifies transaction_jws
  src/index.ts                           MODIFIED — mounts appstoreRoute
  test/helpers/mint-cert.ts              self-signed test chain built with WebCrypto
  test/appstore-x509.test.ts             root constant + parser
  test/appstore-jws.test.ts              valid / wrong bundle / expired / tampered
  test/appstore-notifications.test.ts    route
  test/devices-pro.test.ts               /v1/devices sets and refuses to set pro_until

Shrunk/
  Services/DeviceIdentity.swift          MODIFIED (Phase 2) — adds storageKey/currentUUID alias
  Services/ShrunkAPIClient.swift         MODIFIED — syncDevice + DeviceSyncing
  Services/StoreKitService.swift         REWRITTEN — subscriptions, appAccountToken, sync
  Services/SavingsLedger.swift           REWRITTEN — real observed math
  Services/SavingsForecast.swift         DELETED
  Services/WatchlistService.swift        MODIFIED — add(product:record:), price/percent
  Models/OnboardingProfile.swift         MODIFIED — categories + shopFrequency only
  Models/ShrinkAlert.swift               MODIFIED — currentPrice
  Models/WatchedProduct.swift            MODIFIED — lastKnownPrice, lastShrinkPercent
  Resources/Shrunk.storekit              REWRITTEN — subscription group
  Features/Settings/ProPaywallView.swift REWRITTEN — ProPaywallViewModel + ProPaywallContent
  Features/Onboarding/*                  REWRITTEN — four steps
  Features/Dashboard/SavingsDashboardView.swift  REWRITTEN
  Features/Alerts/AlertsFeedView.swift   MODIFIED — new ledger call
  Features/Result/ShrinkHistoryChart.swift  MODIFIED — Pro gating
  Features/Result/ResultView.swift       MODIFIED — chart gating + watchlist add
ShrunkTests/
  DeviceSyncTests.swift          ProEntitlementTests.swift
  StoreKitConfigurationTests.swift (SKTestSession)
  ProPaywallViewModelTests.swift  OnboardingViewModelTests.swift
  SavingsLedgerTests.swift        ShrinkHistoryChartTests.swift
project.yml                      MODIFIED — StoreKitTest.framework + .storekit in test bundle
docs/ASC_SETUP.md                MODIFIED — subscription group, offer, notifications URL
tasks/shrunk_v2_monetization.md  MODIFIED — one superseded line at the top
```

---

### Task 1: Apple Root CA - G3 trust anchor and DER/X.509 parsing

**Files:**
- Create: `backend/src/appstore/asn1.ts`
- Create: `backend/src/appstore/x509.ts`
- Create: `backend/src/appstore/root.ts`
- Test: `backend/test/appstore-x509.test.ts`

**Interfaces:**
- Produces (`asn1.ts`): `TLV { tag; offset; headerLength; length; start; end; next }`, `readTLV(bytes: Uint8Array, offset: number): TLV`, `children(bytes, seq: TLV): TLV[]`, `span(bytes, tlv: TLV): Uint8Array` (element **including** its header), `oidToString(bytes, tlv): string`, `parseTime(bytes, tlv): Date`.
- Produces (`x509.ts`): `Certificate { der; tbs; issuer; subject; spki; notBefore: Date; notAfter: Date; curve: "P-256"|"P-384"; sigHash: "SHA-256"|"SHA-384"; signatureDer: Uint8Array }`, `parseCertificate(der: Uint8Array): Certificate`, `ecdsaDerToRaw(sig: Uint8Array, size: number): Uint8Array`, `importPublicKey(cert: Certificate): Promise<CryptoKey>`.
- Produces (`root.ts`): `APPLE_ROOT_CA_G3_PEM: string`, `APPLE_ROOT_CA_G3_DER: Uint8Array`, `pemToDer(pem: string): Uint8Array`, `base64ToBytes(b64: string): Uint8Array`, `bytesToBase64(bytes: Uint8Array): string`, `bytesEqual(a, b): boolean`.

Why hand-rolled: Workers have no Node `crypto.X509Certificate` and no npm certificate library that runs in workerd without polyfills. The parser below reads exactly the seven TBS fields the verifier needs and nothing else. It was validated against the real Apple Root CA - G3 (P-384 / ECDSA-SHA384, self-signature verifies) before this plan was written.

- [ ] **Step 1: Write the failing test**

`backend/test/appstore-x509.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { APPLE_ROOT_CA_G3_DER, bytesEqual } from "../src/appstore/root";
import { ecdsaDerToRaw, importPublicKey, parseCertificate } from "../src/appstore/x509";

describe("Apple Root CA - G3 constant", () => {
  it("parses as a self-signed P-384 certificate valid until 2039", () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    expect(cert.curve).toBe("P-384");
    expect(cert.sigHash).toBe("SHA-384");
    expect(cert.notBefore.toISOString()).toBe("2014-04-30T18:19:06.000Z");
    expect(cert.notAfter.toISOString()).toBe("2039-04-30T18:19:06.000Z");
    expect(bytesEqual(cert.issuer, cert.subject)).toBe(true);
  });

  it("carries the expected subject common name", () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    expect(new TextDecoder().decode(cert.subject)).toContain("Apple Root CA - G3");
  });

  it("verifies its own signature", async () => {
    const cert = parseCertificate(APPLE_ROOT_CA_G3_DER);
    const key = await importPublicKey(cert);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: cert.sigHash },
      key,
      ecdsaDerToRaw(cert.signatureDer, 48),
      new Uint8Array(cert.tbs),
    );
    expect(ok).toBe(true);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/appstore-x509.test.ts`
Expected: FAIL — `Cannot find module '../src/appstore/root'`.

- [ ] **Step 3: Write the DER reader**

`backend/src/appstore/asn1.ts`:

```ts
/**
 * The smallest DER reader that can walk an X.509 certificate. Only the
 * constructs Apple's certificate chain uses are supported; anything else
 * throws, and the caller turns a throw into "not verified".
 */
export interface TLV {
  tag: number;
  offset: number;        // index of the tag byte
  headerLength: number;  // tag + length bytes
  length: number;        // content length
  start: number;         // index of the first content byte
  end: number;           // one past the last content byte
  next: number;          // one past the whole element
}

export function readTLV(bytes: Uint8Array, offset: number): TLV {
  if (offset + 2 > bytes.length) throw new Error("asn1: truncated header");
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let headerLength = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new Error("asn1: unsupported length form");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[offset + 2 + i];
    headerLength = 2 + count;
  }
  const start = offset + headerLength;
  const end = start + length;
  if (end > bytes.length) throw new Error("asn1: truncated content");
  return { tag, offset, headerLength, length, start, end, next: end };
}

export function children(bytes: Uint8Array, seq: TLV): TLV[] {
  const out: TLV[] = [];
  let offset = seq.start;
  while (offset < seq.end) {
    const tlv = readTLV(bytes, offset);
    out.push(tlv);
    offset = tlv.next;
  }
  return out;
}

/** The element including its tag and length bytes — what signatures cover. */
export function span(bytes: Uint8Array, tlv: TLV): Uint8Array {
  return bytes.subarray(tlv.offset, tlv.next);
}

export function oidToString(bytes: Uint8Array, tlv: TLV): string {
  const content = bytes.subarray(tlv.start, tlv.end);
  if (content.length === 0) throw new Error("asn1: empty oid");
  const parts: number[] = [Math.floor(content[0] / 40), content[0] % 40];
  let value = 0;
  for (let i = 1; i < content.length; i++) {
    value = value * 128 + (content[i] & 0x7f);
    if (!(content[i] & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function isoDate(year: number, rest: string): Date {
  const mm = rest.slice(0, 2);
  const dd = rest.slice(2, 4);
  const hh = rest.slice(4, 6);
  const mi = rest.slice(6, 8);
  const ss = rest.slice(8, 10) || "00";
  const parsed = new Date(`${String(year).padStart(4, "0")}-${mm}-${dd}T${hh}:${mi}:${ss}Z`);
  if (Number.isNaN(parsed.getTime())) throw new Error("asn1: bad time");
  return parsed;
}

/** UTCTime (0x17, YYMMDDhhmmssZ) and GeneralizedTime (0x18, YYYYMMDDhhmmssZ). */
export function parseTime(bytes: Uint8Array, tlv: TLV): Date {
  const text = new TextDecoder().decode(bytes.subarray(tlv.start, tlv.end));
  if (tlv.tag === 0x17) {
    const yy = Number(text.slice(0, 2));
    // RFC 5280: 00-49 => 20xx, 50-99 => 19xx.
    return isoDate(yy >= 50 ? 1900 + yy : 2000 + yy, text.slice(2));
  }
  if (tlv.tag === 0x18) return isoDate(Number(text.slice(0, 4)), text.slice(4));
  throw new Error("asn1: unsupported time tag");
}
```

- [ ] **Step 4: Write the certificate parser**

`backend/src/appstore/x509.ts`:

```ts
import { children, oidToString, parseTime, readTLV, span } from "./asn1";

const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";

export interface Certificate {
  der: Uint8Array;
  tbs: Uint8Array;          // tbsCertificate including its header — the signed bytes
  issuer: Uint8Array;       // raw issuer Name, compared byte-for-byte against a parent's subject
  subject: Uint8Array;
  spki: Uint8Array;         // SubjectPublicKeyInfo, importable straight into WebCrypto
  notBefore: Date;
  notAfter: Date;
  curve: "P-256" | "P-384"; // this certificate's own key
  sigHash: "SHA-256" | "SHA-384"; // hash used by whoever signed this certificate
  signatureDer: Uint8Array; // DER SEQUENCE { INTEGER r, INTEGER s }
}

/**
 * Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
 * TBSCertificate ::= SEQUENCE { [0] version, serialNumber, signature, issuer,
 *                               validity, subject, subjectPublicKeyInfo, ... }
 */
export function parseCertificate(der: Uint8Array): Certificate {
  const cert = readTLV(der, 0);
  const top = children(der, cert);
  if (top.length < 3) throw new Error("x509: malformed certificate");
  const [tbsTLV, sigAlgTLV, sigTLV] = top;

  const sigAlgOID = oidToString(der, children(der, sigAlgTLV)[0]);
  const sigHash =
    sigAlgOID === OID_ECDSA_SHA384 ? "SHA-384" :
    sigAlgOID === OID_ECDSA_SHA256 ? "SHA-256" : null;
  if (!sigHash) throw new Error(`x509: unsupported signature algorithm ${sigAlgOID}`);

  // signatureValue is a BIT STRING whose first content byte is the unused-bit count.
  const signatureDer = der.subarray(sigTLV.start + 1, sigTLV.end);

  const tbs = children(der, tbsTLV);
  let i = tbs[0].tag === 0xa0 ? 1 : 0; // skip [0] EXPLICIT version when present
  i++;                                  // serialNumber
  i++;                                  // inner AlgorithmIdentifier
  const issuer = span(der, tbs[i++]);
  const validityTLV = tbs[i++];
  const subject = span(der, tbs[i++]);
  const spkiTLV = tbs[i++];
  if (!spkiTLV) throw new Error("x509: missing subjectPublicKeyInfo");

  const [notBeforeTLV, notAfterTLV] = children(der, validityTLV);

  // SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier { OID ecPublicKey,
  //                                     OID namedCurve }, BIT STRING }
  const curveOID = oidToString(der, children(der, children(der, spkiTLV)[0])[1]);
  const curve =
    curveOID === OID_P384 ? "P-384" :
    curveOID === OID_P256 ? "P-256" : null;
  if (!curve) throw new Error(`x509: unsupported curve ${curveOID}`);

  return {
    der,
    tbs: span(der, tbsTLV),
    issuer,
    subject,
    spki: span(der, spkiTLV),
    notBefore: parseTime(der, notBeforeTLV),
    notAfter: parseTime(der, notAfterTLV),
    curve,
    sigHash,
    signatureDer,
  };
}

function leftPad(value: Uint8Array, size: number): Uint8Array {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start++;
  const trimmed = value.subarray(start);
  if (trimmed.length > size) throw new Error("x509: ecdsa integer too large");
  const padded = new Uint8Array(size);
  padded.set(trimmed, size - trimmed.length);
  return padded;
}

/**
 * X.509 stores ECDSA signatures as DER SEQUENCE { r, s }; WebCrypto wants the
 * fixed-width r||s concatenation. `size` is the field size of the *signing*
 * key's curve: 32 for P-256, 48 for P-384.
 */
export function ecdsaDerToRaw(sig: Uint8Array, size: number): Uint8Array {
  const seq = readTLV(sig, 0);
  const [r, s] = children(sig, seq);
  const out = new Uint8Array(size * 2);
  out.set(leftPad(sig.subarray(r.start, r.end), size), 0);
  out.set(leftPad(sig.subarray(s.start, s.end), size), size);
  return out;
}

export function importPublicKey(cert: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "spki",
    new Uint8Array(cert.spki),
    { name: "ECDSA", namedCurve: cert.curve },
    false,
    ["verify"],
  );
}
```

- [ ] **Step 5: Fetch Apple's root certificate and write the constant**

Apple's root is real-world data — download it rather than trusting anything typed from memory:

```bash
cd /tmp
curl -sSO https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
openssl x509 -inform DER -in AppleRootCA-G3.cer -noout -subject -issuer -dates -fingerprint -sha256
```

Expected output (all four lines must match exactly; if they do not, stop — you have the wrong file):

```
subject=CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US
issuer=CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US
notBefore=Apr 30 18:19:06 2014 GMT
notAfter=Apr 30 18:19:06 2039 GMT
sha256 Fingerprint=63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
```

`backend/src/appstore/root.ts` — the PEM below is that exact certificate; `openssl x509 -inform DER -in AppleRootCA-G3.cer -outform PEM` reproduces it byte for byte:

```ts
/**
 * Apple Root CA - G3 — the trust anchor for every App Store Server Notification
 * and every signed transaction JWS.
 *
 *   source:   https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
 *   subject:  CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US
 *   validity: 2014-04-30T18:19:06Z .. 2039-04-30T18:19:06Z
 *   key:      ECDSA P-384, self-signed with ECDSA-SHA384
 *   sha256:   63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 */
export const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

export function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function pemToDer(pem: string): Uint8Array {
  return base64ToBytes(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, ""));
}

/** Constant-time-ish byte comparison; length differences short-circuit. */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export const APPLE_ROOT_CA_G3_DER = pemToDer(APPLE_ROOT_CA_G3_PEM);
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd backend && npx vitest run test/appstore-x509.test.ts && npx tsc --noEmit`
Expected: `3 passed`; typecheck clean.

- [ ] **Step 7: Commit**

```bash
rm -f /tmp/AppleRootCA-G3.cer
git add backend/src/appstore/asn1.ts backend/src/appstore/x509.ts backend/src/appstore/root.ts backend/test/appstore-x509.test.ts
git commit -m "feat(backend): DER/X.509 parsing and the Apple Root CA - G3 trust anchor"
```

---

### Task 2: `verifyAndDecode` and a self-signed test chain

**Files:**
- Create: `backend/src/appstore/jws.ts`
- Create: `backend/test/helpers/mint-cert.ts`
- Test: `backend/test/appstore-jws.test.ts`

**Interfaces:**
- Consumes: `parseCertificate`, `ecdsaDerToRaw`, `importPublicKey` (Task 1, `x509.ts`); `APPLE_ROOT_CA_G3_DER`, `base64ToBytes`, `bytesToBase64`, `bytesEqual` (Task 1, `root.ts`).
- Produces (`jws.ts`):
  - `SHRUNK_BUNDLE_ID = "com.shrunk.app"`
  - `DecodedTransaction { bundleId: string; productId: string; transactionId: string; originalTransactionId: string; appAccountToken: string | null; expiresDateMs: number | null; revocationDateMs: number | null; environment: string }`
  - `DecodedNotification { notificationType: string; subtype: string | null; notificationUUID: string; bundleId: string; signedTransactionInfo: string | null }`
  - `verifyAndDecodePayload<T>(jws: string, now: Date, rootDer?: Uint8Array): Promise<T | null>`
  - `verifyAndDecode(jws: string, now: Date, rootDer?: Uint8Array): Promise<DecodedTransaction | null>`
  - `verifyAndDecodeNotification(jws: string, now: Date, rootDer?: Uint8Array): Promise<DecodedNotification | null>`
- Produces (`test/helpers/mint-cert.ts`): `TestChain { rootDer: Uint8Array; leafPrivateKey: CryptoKey; x5c: string[] }`, `newTestChain(opts?: { notBefore?: Date; notAfter?: Date }): Promise<TestChain>`, `signTestJWS(chain: TestChain, payload: unknown): Promise<string>`, `base64UrlEncode(bytes: Uint8Array): string`.

`verifyAndDecode` is pure: no D1, no `fetch`, no `Env`. It returns a `Promise` only because WebCrypto is async. `rootDer` defaults to Apple's root and is overridden with the test root — that single parameter is what makes the whole verifier testable without Apple sandbox secrets.

**Deviation from spec §10, deliberate.** The spec asks for "JWS verification with an Apple sandbox transaction". A real sandbox JWS cannot live in the repo — it is signed by a leaf certificate that expires, it carries a real transaction id, and capturing one requires a signed build on a device before any of this code exists. So the automated coverage uses a generated chain that exercises the identical code path, and the Apple sandbox transaction is verified **once, end to end, in the Phase 5 exit criteria**: a sandbox purchase on a device must land a future `pro_until` in D1, which only happens if a genuine Apple-signed JWS verified against the pinned real root.

**How the test chain is built (no Apple secrets, nothing checked in):** the test generates three ECDSA P-256 key pairs with `crypto.subtle.generateKey` and hand-encodes three minimal X.509 v3 certificates in DER — root (self-signed), intermediate (signed by root), leaf (signed by intermediate) — each with a `CN` Name, a UTCTime validity window, and the WebCrypto-exported SPKI. `signTestJWS` then signs `base64url(header).base64url(payload)` with the leaf private key and puts `[leaf, intermediate, root]` base64 DER in the header's `x5c`, exactly as Apple does. Passing `chain.rootDer` as the trust anchor makes the chain verify; passing Apple's real root makes the same JWS fail. No extensions are emitted (no basicConstraints, no keyUsage) — the verifier does not read them, and adding them would be untested code.

- [ ] **Step 1: Write the test-chain helper**

`backend/test/helpers/mint-cert.ts`:

```ts
import { bytesToBase64 } from "../../src/appstore/root";

// AlgorithmIdentifier for ecdsa-with-SHA256: SEQUENCE { OID 1.2.840.10045.4.3.2 }
const ALG_ID_ECDSA_SHA256 = new Uint8Array([0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]);
// OID 2.5.4.3 (id-at-commonName), already TLV-encoded
const OID_COMMON_NAME = new Uint8Array([0x06, 0x03, 0x55, 0x04, 0x03]);

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function encodeLength(length: number): Uint8Array {
  if (length < 0x80) return new Uint8Array([length]);
  const bytes: number[] = [];
  let n = length;
  while (n > 0) {
    bytes.unshift(n & 0xff);
    n >>= 8;
  }
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function tlv(tag: number, content: Uint8Array): Uint8Array {
  return concat(new Uint8Array([tag]), encodeLength(content.length), content);
}

function integer(value: number): Uint8Array {
  const bytes: number[] = [];
  let n = value;
  do {
    bytes.unshift(n & 0xff);
    n = Math.floor(n / 256);
  } while (n > 0);
  if (bytes[0] & 0x80) bytes.unshift(0); // keep it positive
  return tlv(0x02, new Uint8Array(bytes));
}

function utcTime(date: Date): Uint8Array {
  const p = (n: number) => String(n).padStart(2, "0");
  const text =
    `${p(date.getUTCFullYear() % 100)}${p(date.getUTCMonth() + 1)}${p(date.getUTCDate())}` +
    `${p(date.getUTCHours())}${p(date.getUTCMinutes())}${p(date.getUTCSeconds())}Z`;
  return tlv(0x17, new TextEncoder().encode(text));
}

/** Name ::= SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String cn } } } */
function nameDER(cn: string): Uint8Array {
  const attribute = tlv(0x30, concat(OID_COMMON_NAME, tlv(0x0c, new TextEncoder().encode(cn))));
  return tlv(0x30, tlv(0x31, attribute));
}

/** WebCrypto emits r||s; X.509 wants DER SEQUENCE { INTEGER r, INTEGER s }. */
function rawToDerEcdsa(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const asInteger = (value: Uint8Array) => {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start++;
    const trimmed = value.subarray(start);
    return tlv(0x02, trimmed[0] & 0x80 ? concat(new Uint8Array([0]), trimmed) : trimmed);
  };
  return tlv(0x30, concat(asInteger(raw.subarray(0, half)), asInteger(raw.subarray(half))));
}

interface MintOptions {
  subjectCN: string;
  issuerCN: string;
  subjectPublicKey: CryptoKey;
  issuerPrivateKey: CryptoKey;
  notBefore: Date;
  notAfter: Date;
  serial: number;
}

async function mintCert(options: MintOptions): Promise<Uint8Array> {
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", options.subjectPublicKey));
  const tbs = tlv(
    0x30,
    concat(
      tlv(0xa0, integer(2)), // [0] EXPLICIT version, v3
      integer(options.serial),
      ALG_ID_ECDSA_SHA256,
      nameDER(options.issuerCN),
      tlv(0x30, concat(utcTime(options.notBefore), utcTime(options.notAfter))),
      nameDER(options.subjectCN),
      spki,
    ),
  );
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, options.issuerPrivateKey, tbs),
  );
  const signatureBits = tlv(0x03, concat(new Uint8Array([0x00]), rawToDerEcdsa(rawSignature)));
  return tlv(0x30, concat(tbs, ALG_ID_ECDSA_SHA256, signatureBits));
}

export interface TestChain {
  rootDer: Uint8Array;
  leafPrivateKey: CryptoKey;
  /** [leaf, intermediate, root], base64 DER — the shape Apple puts in the JWS header. */
  x5c: string[];
}

export async function newTestChain(opts: { notBefore?: Date; notAfter?: Date } = {}): Promise<TestChain> {
  const notBefore = opts.notBefore ?? new Date("2020-01-01T00:00:00Z");
  const notAfter = opts.notAfter ?? new Date("2035-01-01T00:00:00Z");
  const generate = () =>
    crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;

  const root = await generate();
  const intermediate = await generate();
  const leaf = await generate();

  const rootDer = await mintCert({
    subjectCN: "Shrunk Test Root", issuerCN: "Shrunk Test Root",
    subjectPublicKey: root.publicKey, issuerPrivateKey: root.privateKey,
    notBefore, notAfter, serial: 1,
  });
  const intermediateDer = await mintCert({
    subjectCN: "Shrunk Test Intermediate", issuerCN: "Shrunk Test Root",
    subjectPublicKey: intermediate.publicKey, issuerPrivateKey: root.privateKey,
    notBefore, notAfter, serial: 2,
  });
  const leafDer = await mintCert({
    subjectCN: "Shrunk Test Leaf", issuerCN: "Shrunk Test Intermediate",
    subjectPublicKey: leaf.publicKey, issuerPrivateKey: intermediate.privateKey,
    notBefore, notAfter, serial: 3,
  });

  return {
    rootDer,
    leafPrivateKey: leaf.privateKey,
    x5c: [bytesToBase64(leafDer), bytesToBase64(intermediateDer), bytesToBase64(rootDer)],
  };
}

export function base64UrlEncode(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function signTestJWS(chain: TestChain, payload: unknown): Promise<string> {
  const header = base64UrlEncode(new TextEncoder().encode(JSON.stringify({ alg: "ES256", x5c: chain.x5c })));
  const body = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      chain.leafPrivateKey,
      new TextEncoder().encode(`${header}.${body}`),
    ),
  );
  return `${header}.${body}.${base64UrlEncode(signature)}`;
}
```

- [ ] **Step 2: Write the failing tests**

`backend/test/appstore-jws.test.ts`:

```ts
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
    });
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/appstore-jws.test.ts`
Expected: FAIL — `Cannot find module '../src/appstore/jws'`.

- [ ] **Step 4: Implement the verifier**

`backend/src/appstore/jws.ts`:

```ts
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
}

/** responseBodyV2DecodedPayload, narrowed to the fields Shrunk uses. */
export interface DecodedNotification {
  notificationType: string;
  subtype: string | null;
  notificationUUID: string;
  bundleId: string;
  signedTransactionInfo: string | null;
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
  };
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/appstore-jws.test.ts && npx tsc --noEmit`
Expected: `7 passed`; typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add backend/src/appstore/jws.ts backend/test/helpers/mint-cert.ts backend/test/appstore-jws.test.ts
git commit -m "feat(backend): verify App Store JWS chains against a pinned Apple root"
```

---

### Task 3: `POST /v1/appstore/notifications`

**Files:**
- Create: `backend/migrations/0005_devices_appstore.sql`
- Create: `backend/src/appstore/entitlement.ts`
- Create: `backend/src/routes/appstore.ts`
- Modify: `backend/src/env.ts` (one optional binding)
- Modify: `backend/src/index.ts` (mount `appstoreRoute`)
- Test: `backend/test/appstore-notifications.test.ts`

**Interfaces:**
- Consumes: `verifyAndDecode`, `verifyAndDecodeNotification`, `SHRUNK_BUNDLE_ID`, `DecodedTransaction` (Task 2); `base64ToBytes`, `APPLE_ROOT_CA_G3_DER` (Task 1).
- Produces (`entitlement.ts`):
  - `proUntilSeconds(tx: DecodedTransaction, bundleId?: string): number | null`
  - `VerifiedEntitlement { appAccountToken: string; proUntil: number }`
  - `entitlementFromJWS(jws: string | null | undefined, now: Date, rootDer?: Uint8Array): Promise<VerifiedEntitlement | null>`
  - `trustAnchor(env: { APPSTORE_ROOT_CA_B64?: string }): Uint8Array`
- Produces: `Env.APPSTORE_ROOT_CA_B64?: string` in `src/env.ts`.
- Produces: `appstoreRoute` (Hono sub-app) exported from `src/routes/appstore.ts`.
- Produces: the index `devices_app_account_token` on `devices(app_account_token)`. `devices` (including `transaction_jws`) and `watches` are already created by Phase 4's migration `0004_devices_watches.sql`; Phase 5 creates or alters neither table.

**Token casing rule (applies to Tasks 3, 4 and 5):** Apple emits `appAccountToken` as a lowercase UUID; `UUID.uuidString` on iOS is uppercase. Every write and every lookup of `devices.app_account_token` lowercases the value first, so the two always meet.

**How the routes get tested without Apple's signing keys:** `verifyAndDecode` takes the trust anchor as a parameter (Task 2), but a route has to get that anchor from somewhere. It reads one optional binding, `APPSTORE_ROOT_CA_B64`, which is **unset in `wrangler.toml` and therefore unset in production** — `trustAnchor()` then falls back to Apple's real root. Tests pass a generated root through the third argument of `app.request(path, init, env)`. This is a deliberate seam in production code rather than module mocking: `vi.spyOn` on an ES module namespace is not reliable inside workerd.

- [ ] **Step 1: Write the migration**

`backend/migrations/0005_devices_appstore.sql` — Phase 4's `0004_devices_watches.sql` already creates `devices` (including `transaction_jws`, the deviation noted above) and `watches`, both per spec §5. This migration adds only the one thing Phase 5 itself needs and Phase 4 has no reason to have created — the lookup index the notifications route and `/v1/devices` use to find a device by its App Store `app_account_token`:

```sql
CREATE INDEX IF NOT EXISTS devices_app_account_token ON devices(app_account_token);
```

- [ ] **Step 2: Write the failing tests**

`backend/test/appstore-notifications.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { bytesToBase64 } from "../src/appstore/root";
import { newTestChain, signTestJWS, type TestChain } from "./helpers/mint-cert";

const TOKEN = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const EXPIRES_MS = Date.UTC(2026, 8, 26); // 2026-09-26T00:00:00Z

/** The env the route sees, with the generated root as its trust anchor. */
function testEnv(chain: TestChain) {
  return { ...env, APPSTORE_ROOT_CA_B64: bytesToBase64(chain.rootDer) };
}

async function notificationJWS(chain: TestChain, tx: Record<string, unknown>, type = "DID_RENEW") {
  const inner = await signTestJWS(chain, tx);
  return signTestJWS(chain, {
    notificationType: type,
    notificationUUID: "0b1b8f4a-1111-2222-3333-444455556666",
    version: "2.0",
    signedDate: Date.now(),
    data: { bundleId: "com.shrunk.app", environment: "Sandbox", signedTransactionInfo: inner },
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
  async function post(body: unknown, routeEnv: Record<string, unknown> = testEnv(chain)) {
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
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/appstore-notifications.test.ts`
Expected: FAIL — `no such table: devices` or a 404 from Hono's default handler.

- [ ] **Step 4: Implement the entitlement helper and the route**

`backend/src/env.ts` — add one optional binding to the existing `Env` interface (leave the rest untouched):

```ts
  /**
   * Test-only trust anchor: base64 DER of a root certificate that replaces
   * Apple Root CA - G3. Never set in `wrangler.toml`, so production always
   * verifies against Apple.
   */
  APPSTORE_ROOT_CA_B64?: string;
```

`backend/src/appstore/entitlement.ts`:

```ts
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
```

`backend/src/routes/appstore.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";
import { proUntilSeconds, trustAnchor } from "../appstore/entitlement";
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
```

`backend/src/index.ts` — add the import and the mount alongside the existing routes (leave every other line untouched):

```ts
import { appstoreRoute } from "./routes/appstore";
// ...
app.route("/", appstoreRoute);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/appstore-notifications.test.ts && npx tsc --noEmit`
Expected: `6 passed`; typecheck clean.

- [ ] **Step 6: Apply the migration locally and to the deployed database**

```bash
cd backend
npx wrangler d1 migrations apply shrunk --local
npx wrangler d1 migrations apply shrunk --remote
npx wrangler d1 execute shrunk --remote --command "PRAGMA table_info(devices);"
```
Expected: the last command lists `id, apns_token, location_id, categories, pro_until, app_account_token, transaction_jws, updated_at` — all of it from Phase 4's `0004_devices_watches.sql`; `0005` only adds the `devices_app_account_token` index and touches no columns. If `transaction_jws` is missing, Phase 4 was implemented against the spec's printed schema without the deviation noted above — land that fix in a new migration (e.g. `0006_devices_backfill_transaction_jws.sql` containing `ALTER TABLE devices ADD COLUMN transaction_jws TEXT;`), never by hand-editing an already-applied migration file.

- [ ] **Step 7: Commit**

```bash
git add backend/migrations/0005_devices_appstore.sql backend/src/appstore/entitlement.ts backend/src/routes/appstore.ts backend/src/env.ts backend/src/index.ts backend/test/appstore-notifications.test.ts
git commit -m "feat(backend): App Store Server Notifications V2 keep pro_until fresh"
```

---

### Task 4: `/v1/devices` verifies the transaction JWS

**Files:**
- Modify: `backend/src/routes/devices.ts` (Phase 4)
- Test: `backend/test/devices-pro.test.ts`

**Interfaces:**
- Consumes: `entitlementFromJWS(jws, now, rootDer?)` → `{ appAccountToken, proUntil } | null` and `trustAnchor(env)` (Task 3).
- Produces: no new exports. `POST /v1/devices` gains this contract — when `transaction_jws` verifies **and** its bundle id is `com.shrunk.app`, the upsert writes `pro_until` and `app_account_token`; otherwise it writes neither and leaves whatever the row already had (spec §8).

- [ ] **Step 1: Write the failing tests**

`backend/test/devices-pro.test.ts`:

```ts
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

async function postDevice(body: Record<string, unknown>, routeEnv: Record<string, unknown>) {
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/devices-pro.test.ts`
Expected: FAIL — the first test's `pro_until` is `null` because Phase 4 stores the JWS without verifying it.

- [ ] **Step 3: Add verification to the route**

In `backend/src/routes/devices.ts`, add the import at the top:

```ts
import { entitlementFromJWS, trustAnchor } from "../appstore/entitlement";
```

Then, inside the `POST /v1/devices` handler, **after the JSON body has been parsed and before the `INSERT INTO devices ... ON CONFLICT` statement runs**, insert this block:

```ts
  // Spec §8: a verification failure must not disturb the device's existing
  // entitlement — the app's own StoreKit entitlement governs the UI, and the
  // next upsert retries. Only a verified, correctly-scoped transaction writes.
  const entitlement = await entitlementFromJWS(body.transaction_jws, new Date(), trustAnchor(c.env));
  if (!entitlement && body.transaction_jws) {
    console.warn("devices: transaction_jws did not verify for", body.device_id);
  }
```

and make the upsert write `pro_until` / `app_account_token` only when `entitlement` is non-null. With SQLite's `COALESCE` on the excluded value this needs no branching — bind `entitlement?.proUntil ?? null` and `entitlement?.appAccountToken ?? null`, and use these two lines in the `ON CONFLICT ... DO UPDATE SET` clause so a null never overwrites a real value:

```sql
  pro_until         = COALESCE(excluded.pro_until, devices.pro_until),
  app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
```

Merge only the two `COALESCE` lines and the `entitlement`-derived bind values (`entitlement?.proUntil ?? null`, `entitlement?.appAccountToken ?? null`) into Phase 4's existing prepared statement and bind list — do not paste the block below over Phase 4's statement if its local variable names differ. For reference only, here is what the complete statement looks like once merged (merge this with whatever other columns Phase 4 upserts — `apns_token`, `location_id`, `categories`, `transaction_jws`):

```ts
  await c.env.DB.prepare(
    `INSERT INTO devices (id, apns_token, location_id, categories, pro_until, app_account_token, transaction_jws, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       apns_token        = COALESCE(excluded.apns_token, devices.apns_token),
       location_id       = COALESCE(excluded.location_id, devices.location_id),
       categories        = COALESCE(excluded.categories, devices.categories),
       pro_until         = COALESCE(excluded.pro_until, devices.pro_until),
       app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
       transaction_jws   = COALESCE(excluded.transaction_jws, devices.transaction_jws),
       updated_at        = excluded.updated_at`,
  )
    .bind(
      deviceId,
      apnsToken ?? null,
      locationId ?? null,
      categories ? JSON.stringify(categories) : null,
      entitlement?.proUntil ?? null,
      entitlement?.appAccountToken ?? null,
      body.transaction_jws ?? null,
      Math.floor(Date.now() / 1000),
    )
    .run();
```

- [ ] **Step 4: Run the whole backend suite to verify it passes**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: every suite green, including Phase 1–4 tests and `devices-pro.test.ts` (4 passed).

- [ ] **Step 5: Deploy and smoke-test the notifications endpoint**

```bash
cd backend && npx wrangler deploy
curl -s -X POST https://shrunk-api.<account>.workers.dev/v1/appstore/notifications \
  -H 'Content-Type: application/json' -d '{"signedPayload":"garbage"}' -w '\n%{http_code}\n'
```
Expected: `{"error":"invalid_signature"}` and `401`. Note the deployed origin — Task 12 writes it into `docs/ASC_SETUP.md`.

- [ ] **Step 6: Commit**

```bash
git add backend/src/routes/devices.ts backend/test/devices-pro.test.ts
git commit -m "feat(backend): /v1/devices verifies the transaction JWS before granting Pro"
```

---

### Task 5: `DeviceIdentity` and `ShrunkAPIClient.syncDevice`

**Files:**
- Modify: `Shrunk/Services/DeviceIdentity.swift` (Phase 2 already created this file — append an extension, do not replace it)
- Modify: `Shrunk/Services/ShrunkAPIClient.swift`
- Test: `ShrunkTests/DeviceSyncTests.swift`

**Interfaces:**
- Produces: `extension DeviceIdentity { static var storageKey: String { key }; static var currentUUID: UUID }` — an alias layered over Phase 2's `key`/`current: String` (`Shrunk/Services/DeviceIdentity.swift`), so the one persisted install id can also be read as a `UUID` for StoreKit's `appAccountToken`. It is simultaneously the `device_id` sent to `/v1/devices` and the `appAccountToken` passed to StoreKit, which is what lets the Worker match an App Store notification to a device row.
- Produces: `protocol DeviceSyncing: Sendable { @discardableResult func syncDevice(deviceId: String, transactionJWS: String) async -> Bool }`, with `extension ShrunkAPIClient: DeviceSyncing`.
- Produces: `ShrunkAPIClient.syncDevice(deviceId:transactionJWS:) async -> Bool` — `POST {baseURL}/v1/devices`, JSON body `{"device_id": ..., "transaction_jws": ...}`, returns `true` on a 2xx. **Never throws** (spec §8: a sync failure must not disturb the UI).
- Consumes: `ShrunkAPIClient.init(baseURL:session:)` and its `baseURL` / `session` properties (Phase 1, Task 11).

If the Preflight found a Phase 4 `syncDevice` with extra parameters, keep it and give every extra parameter a default; only the two-argument call has to compile. If Phase 2 already stores a UUID device id under a different key, set `DeviceIdentity.storageKey` to that key instead of adding a second identity.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/DeviceSyncTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class DeviceIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
        super.tearDown()
    }

    func test_storageKey_aliasesKey() {
        XCTAssertEqual(DeviceIdentity.storageKey, DeviceIdentity.key)
    }

    func test_currentUUID_isStableAcrossCalls() {
        let first = DeviceIdentity.currentUUID
        let second = DeviceIdentity.currentUUID
        XCTAssertEqual(first, second)
    }

    func test_currentUUID_matchesCurrentAsAUUID() {
        // Phase 2's `current` always mints UUID().uuidString, so the two never diverge.
        XCTAssertEqual(DeviceIdentity.currentUUID.uuidString, DeviceIdentity.current)
    }

    func test_currentUUID_reusesAPersistedUUID() {
        let stored = UUID()
        UserDefaults.standard.set(stored.uuidString, forKey: DeviceIdentity.key)
        XCTAssertEqual(DeviceIdentity.currentUUID, stored)
    }
}

final class SyncDeviceTests: XCTestCase {
    private var client: ShrunkAPIClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!,
                                 session: URLSession(configuration: config))
    }

    func test_syncDevice_postsTheDeviceIdAndJWS() async {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.method = request.httpMethod
            captured.url = request.url?.absoluteString
            captured.body = request.bodyData()
            return (200, Data(#"{"ok":true}"#.utf8))
        }

        let synced = await client.syncDevice(deviceId: "ABC-123", transactionJWS: "aaa.bbb.ccc")

        XCTAssertTrue(synced)
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.url, "https://api.test/v1/devices")
        let json = try! JSONSerialization.jsonObject(with: captured.body ?? Data()) as! [String: String]
        XCTAssertEqual(json["device_id"], "ABC-123")
        XCTAssertEqual(json["transaction_jws"], "aaa.bbb.ccc")
    }

    func test_syncDevice_returnsFalseOnServerError() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let synced = await client.syncDevice(deviceId: "ABC-123", transactionJWS: "aaa.bbb.ccc")
        XCTAssertFalse(synced)
    }
}

/// Reference box so the URLProtocol closure can hand values back to the test.
final class CapturedRequest: @unchecked Sendable {
    var method: String?
    var url: String?
    var body: Data?
}

extension URLRequest {
    /// `URLProtocol` strips `httpBody` for streamed uploads; read the stream instead.
    func bodyData() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

`StubURLProtocol` already exists in `ShrunkTests/ShrunkAPIClientTests.swift` (Phase 1, Task 11) — do not redeclare it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/DeviceIdentityTests -only-testing:ShrunkTests/SyncDeviceTests -quiet 2>&1 | tail -20
```
Expected: compile error `type 'DeviceIdentity' has no member 'storageKey'` (Phase 2's `DeviceIdentity` already exists; this task only adds the alias).

- [ ] **Step 3: Extend Phase 2's `DeviceIdentity` — do not replace it**

Phase 2 (`docs/superpowers/plans/2026-08-26-shrunk-v2-phase2-crowd-observations.md`, Task 7) already ships `Shrunk/Services/DeviceIdentity.swift` with `static let key = "device_id"` and `static var current: String`, minting `UUID().uuidString` into `@AppStorage("device_id")`. Leave that file's existing `enum DeviceIdentity` untouched and append this extension below it:

`Shrunk/Services/DeviceIdentity.swift`:

```swift
extension DeviceIdentity {
    /// Alias for Phase 5's naming; both refer to the one persisted install id.
    static var storageKey: String { key }

    /// `current` as a `UUID` — what StoreKit's `appAccountToken` requires.
    /// `current` is always minted as `UUID().uuidString` (Phase 2), so the
    /// fallback below never fires in practice; if it ever did, it re-mints
    /// and persists a fresh UUID under the same key so `current` and
    /// `currentUUID` can never diverge.
    static var currentUUID: UUID {
        if let uuid = UUID(uuidString: current) { return uuid }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: key)
        return fresh
    }
}
```

- [ ] **Step 4: Add `syncDevice` to `ShrunkAPIClient`**

Append to `Shrunk/Services/ShrunkAPIClient.swift`, inside the `actor ShrunkAPIClient` body:

```swift
    /// Upserts this device on the Worker and hands over the signed transaction
    /// so the server can refresh `pro_until`.
    ///
    /// Deliberately non-throwing (spec §8): the device's own StoreKit
    /// entitlement governs the UI, and the Worker retries verification on the
    /// next upsert, so a failed sync is a no-op from the app's point of view.
    @discardableResult
    func syncDevice(deviceId: String, transactionJWS: String) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            DeviceSyncBody(device_id: deviceId, transaction_jws: transactionJWS)
        )

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status)
        } catch {
            return false
        }
    }
```

and at file scope:

```swift
private struct DeviceSyncBody: Encodable {
    let device_id: String
    let transaction_jws: String
}

/// Lets `StoreKitService` be tested without a network stack.
protocol DeviceSyncing: Sendable {
    @discardableResult
    func syncDevice(deviceId: String, transactionJWS: String) async -> Bool
}

extension ShrunkAPIClient: DeviceSyncing {}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the command from Step 2.
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Services/DeviceIdentity.swift Shrunk/Services/ShrunkAPIClient.swift ShrunkTests/DeviceSyncTests.swift
git commit -m "feat(ios): stable device UUID and /v1/devices entitlement sync"
```

---

### Task 6: `StoreKitService` becomes a subscription service

**Files:**
- Modify: `Shrunk/Services/StoreKitService.swift` (full rewrite of the file)
- Test: `ShrunkTests/ProEntitlementTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentity.currentUUID`, `DeviceSyncing`, `ShrunkAPIClient.shared` (Task 5).
- Produces:
  - `enum ShrunkProProduct { static let monthly = "com.shrunk.pro.monthly"; static let yearly = "com.shrunk.pro.yearly"; static let all: [String] }`
  - `enum ProEntitlement { struct Snapshot: Equatable { let productID: String; let expirationDate: Date?; let revocationDate: Date? }; static func isActive(_ snapshots: [Snapshot], now: Date) -> Bool }`
  - `StoreKitService` (`@MainActor`, `ObservableObject`) with `init(syncer: DeviceSyncing = ShrunkAPIClient.shared)`, `static let shared`, published `isProUser`, `monthlyProduct`, `yearlyProduct`, `isTrialEligible`, `purchaseInProgress`, `loadError`; methods `bootstrap()`, `loadProducts()`, `refreshTrialEligibility()`, `purchase(_ product: Product) async throws`, `restore()`, `refreshEntitlements()`, `syncEntitlement()`.
- Removed: `StoreKitService.proProductID`, `StoreKitService.product`, `StoreKitService.displayPrice`, `purchase()` (the no-argument overload). Two views call those — `ProPaywallView` and the `PaywallStep` inside `OnboardingContainerView`. Step 4 below patches both so the app still compiles at the end of this task; Tasks 8 and 9 then replace those files wholesale.
- `isProUser` keeps its name so `SettingsView`, `AlertsFeedView`, `WatchlistView`, `AlternativesView`, and `ResultView` need no change.

`ProEntitlement.isActive` is split out as a free function so entitlement derivation is unit-testable without StoreKit; `refreshEntitlements()` only maps `Transaction.currentEntitlements` into snapshots and calls it.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/ProEntitlementTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class ProEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ productID: String,
        expires: TimeInterval? = 86_400,
        revoked: TimeInterval? = nil
    ) -> ProEntitlement.Snapshot {
        ProEntitlement.Snapshot(
            productID: productID,
            expirationDate: expires.map { now.addingTimeInterval($0) },
            revocationDate: revoked.map { now.addingTimeInterval($0) }
        )
    }

    func test_noEntitlements_isNotPro() {
        XCTAssertFalse(ProEntitlement.isActive([], now: now))
    }

    func test_activeMonthly_isPro() {
        XCTAssertTrue(ProEntitlement.isActive([snapshot(ShrunkProProduct.monthly)], now: now))
    }

    func test_activeYearly_isPro() {
        XCTAssertTrue(ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly)], now: now))
    }

    func test_expiredSubscription_isNotPro() {
        XCTAssertFalse(ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly, expires: -1)], now: now))
    }

    func test_revokedSubscription_isNotPro() {
        XCTAssertFalse(
            ProEntitlement.isActive([snapshot(ShrunkProProduct.yearly, revoked: -3600)], now: now)
        )
    }

    func test_retiredLifetimeSKU_doesNotGrantPro() {
        // com.shrunk.pro.lifetime is removed (spec §2); a stray entitlement for
        // it must not keep an old build's users on Pro through this service.
        XCTAssertFalse(
            ProEntitlement.isActive([snapshot("com.shrunk.pro.lifetime", expires: nil)], now: now)
        )
    }

    func test_anyActiveMemberOfTheGroupIsEnough() {
        let mixed = [
            snapshot(ShrunkProProduct.monthly, expires: -10),
            snapshot(ShrunkProProduct.yearly, expires: 60)
        ]
        XCTAssertTrue(ProEntitlement.isActive(mixed, now: now))
    }

    func test_productIDs_matchTheSpec() {
        XCTAssertEqual(ShrunkProProduct.monthly, "com.shrunk.pro.monthly")
        XCTAssertEqual(ShrunkProProduct.yearly, "com.shrunk.pro.yearly")
        XCTAssertEqual(ShrunkProProduct.all, ["com.shrunk.pro.yearly", "com.shrunk.pro.monthly"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ProEntitlementTests -quiet 2>&1 | tail -20
```
Expected: compile error `cannot find 'ProEntitlement' in scope`.

- [ ] **Step 3: Rewrite `StoreKitService.swift`**

Replace the whole file with:

```swift
import Foundation
import StoreKit

/// The two products in the "Shrunk Pro" subscription group (spec §2).
/// Yearly first: it is the preselected plan on the paywall.
enum ShrunkProProduct {
    static let monthly = "com.shrunk.pro.monthly"
    static let yearly  = "com.shrunk.pro.yearly"
    static let all: [String] = [yearly, monthly]
}

/// Entitlement derivation, split out of `StoreKitService` so it can be unit
/// tested without StoreKit. Pro means: any non-revoked, unexpired subscription
/// in the Shrunk Pro group.
enum ProEntitlement {
    struct Snapshot: Equatable {
        let productID: String
        let expirationDate: Date?
        let revocationDate: Date?
    }

    static func isActive(_ snapshots: [Snapshot], now: Date) -> Bool {
        snapshots.contains { snapshot in
            guard ShrunkProProduct.all.contains(snapshot.productID) else { return false }
            guard snapshot.revocationDate == nil else { return false }
            guard let expiration = snapshot.expirationDate else { return true }
            return expiration > now
        }
    }
}

@MainActor
final class StoreKitService: ObservableObject {
    static let shared = StoreKitService()

    @Published var isProUser: Bool = false
    @Published private(set) var monthlyProduct: Product?
    @Published private(set) var yearlyProduct: Product?
    @Published private(set) var isTrialEligible: Bool = true
    @Published private(set) var purchaseInProgress: Bool = false
    @Published private(set) var loadError: String?

    private let syncer: DeviceSyncing
    private var transactionListener: Task<Void, Never>?

    init(syncer: DeviceSyncing = ShrunkAPIClient.shared) {
        self.syncer = syncer
    }

    deinit {
        transactionListener?.cancel()
    }

    func bootstrap() async {
        if transactionListener == nil {
            transactionListener = listenForTransactions()
        }
        await loadProducts()
        await refreshEntitlements()
        await refreshTrialEligibility()
        await syncEntitlement()
    }

    // MARK: - Loading

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ShrunkProProduct.all)
            monthlyProduct = fetched.first { $0.id == ShrunkProProduct.monthly }
            yearlyProduct  = fetched.first { $0.id == ShrunkProProduct.yearly }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The 7-day free trial is an introductory offer on the yearly product and
    /// is offered once per subscription group, so eligibility is a group-level
    /// question. Defaults to `true` while products are still loading — the
    /// paywall reads better optimistic than pessimistic, and StoreKit is the
    /// authority at purchase time either way.
    func refreshTrialEligibility() async {
        guard let groupID = yearlyProduct?.subscription?.subscriptionGroupID else { return }
        isTrialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        purchaseInProgress = true
        defer { purchaseInProgress = false }

        // The appAccountToken is how the Worker links an App Store Server
        // Notification back to this install's `devices` row (spec §5).
        let result = try await product.purchase(options: [.appAccountToken(DeviceIdentity.currentUUID)])
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
            await refreshTrialEligibility()
            await syncEntitlement()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            loadError = error.localizedDescription
        }
        await refreshEntitlements()
        await refreshTrialEligibility()
        await syncEntitlement()
    }

    // MARK: - Entitlement

    func refreshEntitlements() async {
        var snapshots: [ProEntitlement.Snapshot] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            snapshots.append(
                ProEntitlement.Snapshot(
                    productID: transaction.productID,
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate
                )
            )
        }
        isProUser = ProEntitlement.isActive(snapshots, now: Date())
    }

    /// Hands the current entitlement's signed JWS to the Worker so it can
    /// refresh `pro_until`. No entitlement means nothing to sync — the Worker
    /// keeps whatever it has until an App Store notification says otherwise.
    func syncEntitlement() async {
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ShrunkProProduct.all.contains(transaction.productID) else { continue }
            jws = result.jwsRepresentation
            break
        }
        guard let jws else { return }
        await syncer.syncDevice(deviceId: DeviceIdentity.currentUUID.uuidString, transactionJWS: jws)
    }

    // MARK: - Internals

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshEntitlements()
                    await self.refreshTrialEligibility()
                    await self.syncEntitlement()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:         throw StoreKitError.unverifiedTransaction
        case .verified(let safe): return safe
        }
    }
}

enum StoreKitError: LocalizedError {
    case unverifiedTransaction
    case productNotLoaded

    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction: return "We couldn't verify your purchase with the App Store."
        case .productNotLoaded:      return "We're still loading the store. Try again in a moment."
        }
    }
}
```

- [ ] **Step 4: Keep the two paywall call sites compiling**

These four edits are a bridge — Task 8 rewrites `ProPaywallView.swift` and Task 9 rewrites `OnboardingContainerView.swift` — but without them the app target does not build and neither this task's tests nor Task 7's can run.

In `Shrunk/Features/Settings/ProPaywallView.swift`:

```swift
        .task {
            if storeKit.yearlyProduct == nil {
                await storeKit.loadProducts()
            }
        }
```

```swift
            ShrunkButton(
                "Unlock for \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")",
                icon: "lock.open.fill",
                isLoading: purchaseInProgress
            ) {
```

```swift
    private func runPurchase() async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        guard let product = storeKit.yearlyProduct else {
            purchaseError = StoreKitError.productNotLoaded.errorDescription
            return
        }
        do {
            try await storeKit.purchase(product)
        } catch {
            purchaseError = error.localizedDescription
        }
    }
```

In `Shrunk/Features/Onboarding/OnboardingContainerView.swift`, inside `PaywallStep` change the button title to `"Unlock for \(storeKit.yearlyProduct?.displayPrice ?? "$14.99")"`, and replace `runPurchase()` on `OnboardingContainerView` with:

```swift
    @MainActor
    private func runPurchase() async {
        guard let product = storeKit.yearlyProduct else { return }
        do {
            try await storeKit.purchase(product)
        } catch {
            // Errors surface inside PaywallStep via storeKit.loadError.
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the command from Step 2, then confirm the whole app still builds:

```bash
xcodebuild build -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: `Executed 8 tests, with 0 failures`, and `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Services/StoreKitService.swift Shrunk/Features/Settings/ProPaywallView.swift Shrunk/Features/Onboarding/OnboardingContainerView.swift ShrunkTests/ProEntitlementTests.swift
git commit -m "feat(ios): StoreKitService drives Pro from the subscription group"
```

---

### Task 7: StoreKit configuration file and the `SKTestSession` walkthrough

**Files:**
- Modify: `Shrunk/Resources/Shrunk.storekit` (full rewrite)
- Modify: `project.yml` (link `StoreKitTest.framework`, ship the config into the test bundle)
- Test: `ShrunkTests/StoreKitConfigurationTests.swift`

**Interfaces:**
- Consumes: `ShrunkProProduct`, `StoreKitService.init(syncer:)`, `purchase(_:)`, `refreshEntitlements()`, `isProUser`, `loadProducts()` (Task 6); `DeviceSyncing` (Task 5).
- Produces: a `Shrunk Pro` subscription group containing `com.shrunk.pro.yearly` (P1Y, $14.99, 7-day free introductory offer, group level 1) and `com.shrunk.pro.monthly` (P1M, $2.99, group level 2). The lifetime non-consumable is gone.
- Produces: `ShrunkTests` links `StoreKitTest.framework` and bundles `Shrunk.storekit`, so `SKTestSession(configurationFileNamed: "Shrunk")` resolves.

This is the spec §10 requirement "StoreKit configuration file for trial/monthly/yearly", and the test is what proves the file is well-formed — a malformed `.storekit` fails at `SKTestSession` construction, not at build time.

- [ ] **Step 1: Wire the test target**

In `project.yml`, add to the `ShrunkTests` target's `sources` and `dependencies` blocks — keep Phase 2's `fixtures/package_weights.json` resource entry, which `NetContentParserTests` needs — so the whole target reads:

```yaml
  ShrunkTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: ShrunkTests
      - path: fixtures/package_weights.json
        type: file
        buildPhase: resources
      - path: Shrunk/Resources/Shrunk.storekit
        buildPhase: resources
    dependencies:
      - target: Shrunk
      - sdk: StoreKitTest.framework
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.shrunk.app.tests
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/Shrunk.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Shrunk
        BUNDLE_LOADER: $(TEST_HOST)
```

Leave the `schemes:` block alone — `run.storeKitConfiguration` already points at the same file, which is what makes the app usable in the simulator outside tests.

- [ ] **Step 2: Write the failing test**

`ShrunkTests/StoreKitConfigurationTests.swift`:

```swift
import XCTest
import StoreKit
import StoreKitTest
@testable import Shrunk

/// Records what `StoreKitService` sends to the Worker without touching the network.
final class SpyDeviceSyncer: DeviceSyncing, @unchecked Sendable {
    private(set) var deviceIds: [String] = []
    private(set) var jwsValues: [String] = []

    @discardableResult
    func syncDevice(deviceId: String, transactionJWS: String) async -> Bool {
        deviceIds.append(deviceId)
        jwsValues.append(transactionJWS)
        return true
    }
}

@MainActor
final class StoreKitConfigurationTests: XCTestCase {
    private var session: SKTestSession!
    private var spy: SpyDeviceSyncer!
    private var service: StoreKitService!

    override func setUp() async throws {
        try await super.setUp()
        session = try SKTestSession(configurationFileNamed: "Shrunk")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        spy = SpyDeviceSyncer()
        service = StoreKitService(syncer: spy)
        await service.loadProducts()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        try await super.tearDown()
    }

    // MARK: - Trial

    func test_configuration_exposesBothPlansInOneGroup() async throws {
        let monthly = try XCTUnwrap(service.monthlyProduct)
        let yearly = try XCTUnwrap(service.yearlyProduct)

        XCTAssertEqual(monthly.id, "com.shrunk.pro.monthly")
        XCTAssertEqual(yearly.id, "com.shrunk.pro.yearly")
        XCTAssertEqual(monthly.displayPrice, "$2.99")
        XCTAssertEqual(yearly.displayPrice, "$14.99")
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(yearly.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(
            monthly.subscription?.subscriptionGroupID,
            yearly.subscription?.subscriptionGroupID
        )
    }

    func test_yearly_offersASevenDayFreeTrialToANewCustomer() async throws {
        let yearly = try XCTUnwrap(service.yearlyProduct)
        let offer = try XCTUnwrap(yearly.subscription?.introductoryOffer)

        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .week)
        XCTAssertEqual(offer.period.value, 1)
        XCTAssertNil(service.monthlyProduct?.subscription?.introductoryOffer)

        await service.refreshTrialEligibility()
        XCTAssertTrue(service.isTrialEligible)
    }

    // MARK: - Active

    func test_purchasingYearly_makesTheUserProAndSyncsTheJWS() async throws {
        let yearly = try XCTUnwrap(service.yearlyProduct)

        try await service.purchase(yearly)

        XCTAssertTrue(service.isProUser)
        XCTAssertEqual(spy.deviceIds.last, DeviceIdentity.currentUUID.uuidString)
        let jws = try XCTUnwrap(spy.jwsValues.last)
        XCTAssertEqual(jws.split(separator: ".").count, 3, "expected a three-segment JWS")
    }

    func test_purchasingMonthly_alsoGrantsPro() async throws {
        let monthly = try XCTUnwrap(service.monthlyProduct)
        try await service.purchase(monthly)
        XCTAssertTrue(service.isProUser)
    }

    // MARK: - Expired

    func test_expiredSubscription_dropsProAndConsumesTheTrial() async throws {
        let yearly = try XCTUnwrap(service.yearlyProduct)
        try await service.purchase(yearly)
        XCTAssertTrue(service.isProUser)

        try session.expireSubscription(productIdentifier: ShrunkProProduct.yearly)
        await service.refreshEntitlements()
        XCTAssertFalse(service.isProUser)

        await service.refreshTrialEligibility()
        XCTAssertFalse(service.isTrialEligible, "the introductory offer is used once per group")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/StoreKitConfigurationTests -quiet 2>&1 | tail -30
```
Expected: failures reporting `service.monthlyProduct` is nil — the configuration file still contains only the lifetime non-consumable.

- [ ] **Step 4: Rewrite the StoreKit configuration file**

`Shrunk/Resources/Shrunk.storekit`:

```json
{
  "identifier" : "D6839475-8E1B-41E8-8E82-C2737ACEFB5A",
  "nonRenewingSubscriptions" : [],
  "products" : [],
  "settings" : {
    "_applicationInternalID" : "0",
    "_developerTeamID" : "",
    "_failTransactionsEnabled" : false,
    "_lastSynchronizedDate" : 0,
    "_locale" : "en_US",
    "_storefront" : "USA",
    "_storeKitErrors" : []
  },
  "subscriptionGroups" : [
    {
      "id" : "21598301",
      "localizations" : [],
      "name" : "Shrunk Pro",
      "subscriptions" : [
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "14.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "5A1C0F42",
          "introductoryOffer" : {
            "displayPrice" : "0.00",
            "internalID" : "7B3E9D18",
            "paymentMode" : "free",
            "subscriptionPeriod" : "P1W"
          },
          "localizations" : [
            {
              "description" : "Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.",
              "displayName" : "Shrunk Pro Yearly",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.shrunk.pro.yearly",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Shrunk Pro Yearly",
          "subscriptionGroupID" : "21598301",
          "type" : "RecurringSubscription"
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "2.99",
          "familyShareable" : false,
          "groupNumber" : 2,
          "internalID" : "9C4D2A77",
          "introductoryOffer" : null,
          "localizations" : [
            {
              "description" : "Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.",
              "displayName" : "Shrunk Pro Monthly",
              "locale" : "en_US"
            }
          ],
          "productID" : "com.shrunk.pro.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Shrunk Pro Monthly",
          "subscriptionGroupID" : "21598301",
          "type" : "RecurringSubscription"
        }
      ]
    }
  ],
  "version" : {
    "major" : 4,
    "minor" : 0
  }
}
```

Notes for whoever opens this in Xcode later: `groupNumber` is the group *level* — yearly at 1 outranks monthly at 2, so monthly → yearly is an upgrade and yearly → monthly a downgrade, matching what App Store Connect will be configured with in Task 12. Xcode rewrites `internalID` and the group `id` when it edits the file; that is harmless, and the values above are only placeholders for Xcode's own bookkeeping. What must never drift are the two `productID`s, the two `displayPrice`s, the two `recurringSubscriptionPeriod`s, and the yearly `introductoryOffer`.

- [ ] **Step 5: Run the test to verify it passes**

Run the command from Step 3.
Expected: `Executed 5 tests, with 0 failures`.

If `SKTestSession(configurationFileNamed: "Shrunk")` throws `SKTestSession.Error.configurationFileNotFound`, the resource did not reach the test bundle — re-run `xcodegen generate` and confirm `Shrunk.storekit` appears under the ShrunkTests target's Copy Bundle Resources phase in `Shrunk.xcodeproj`.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Resources/Shrunk.storekit project.yml ShrunkTests/StoreKitConfigurationTests.swift
git commit -m "feat(ios): StoreKit configuration for the Shrunk Pro subscription group"
```

---

### Task 8: Paywall rewrite — trial, two plans, yearly preselected

**Files:**
- Modify: `Shrunk/Features/Settings/ProPaywallView.swift` (full rewrite; gains `ProPaywallViewModel` and `ProPaywallContent`)
- Test: `ShrunkTests/ProPaywallViewModelTests.swift`

**Interfaces:**
- Consumes: `StoreKitService.monthlyProduct`, `.yearlyProduct`, `.isTrialEligible`, `.loadProducts()`, `.refreshTrialEligibility()`, `.purchase(_:)`, `.restore()`, `.isProUser` (Task 6); `StoreKitError.productNotLoaded` (Task 6).
- Produces:
  - `ProPaywallViewModel` (`@MainActor`, `ObservableObject`): `enum Plan: String, CaseIterable, Identifiable { case yearly, monthly }`; `@Published var selectedPlan: Plan = .yearly`; `private(set) var monthlyDisplayPrice: String`, `yearlyDisplayPrice: String`, `savingsBadge: String?`, `isTrialEligible: Bool`; `func apply(monthlyDisplayPrice: String?, monthlyPrice: Decimal?, yearlyDisplayPrice: String?, yearlyPrice: Decimal?, isTrialEligible: Bool)`; `static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int?`; computed `trialAppliesToSelection`, `ctaTitle`, `fineprint`.
  - `ProPaywallContent(skipTitle:onSkip:)` — the paywall body, reused by `ProPaywallView` (sheet, with a close button) and by the onboarding paywall step in Task 9.
  - `ProPaywallView` — unchanged call sites: it is still constructed as `ProPaywallView()` from `SettingsView`, `AlertsFeedView`, `WatchlistView`, and `ResultView`.
- Deleted: the `SavingsForecast` payback banner, `@AppStorage("shrunk.onboarding_profile")` in this file, and the "Pay once. Yours forever." / "One-time payment. No subscription. No auto-renew." copy.

The view model takes plain `String`/`Decimal` values rather than `Product`, because `Product` cannot be constructed in a unit test. `ProPaywallContent.load()` is the only place that reaches into `StoreKitService` for them.

**Copy.** Spec-mandated: the savings badge reads **"Save 58%"** (spec §7: "yearly preselected, 'save 58%'"). $2.99 × 12 = $35.88 against $14.99 is a 58.2% saving, so the badge is computed, not hard-coded, and the test pins it to 58. Terms and privacy reuse the URLs already in `SettingsView`: `https://stackcurious.com/shrunk/terms` and `https://stackcurious.com/shrunk/privacy`.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/ProPaywallViewModelTests.swift`:

```swift
import XCTest
@testable import Shrunk

@MainActor
final class ProPaywallViewModelTests: XCTestCase {

    private func loaded(isTrialEligible: Bool = true) -> ProPaywallViewModel {
        let vm = ProPaywallViewModel()
        vm.apply(
            monthlyDisplayPrice: "$2.99", monthlyPrice: Decimal(string: "2.99"),
            yearlyDisplayPrice: "$14.99", yearlyPrice: Decimal(string: "14.99"),
            isTrialEligible: isTrialEligible
        )
        return vm
    }

    // MARK: - Savings

    func test_savingsPercent_matchesTheSpecsFiftyEight() {
        XCTAssertEqual(
            ProPaywallViewModel.savingsPercent(
                monthlyPrice: Decimal(string: "2.99")!,
                yearlyPrice: Decimal(string: "14.99")!
            ),
            58
        )
    }

    func test_savingsPercent_isNilWhenYearlyIsNotCheaper() {
        XCTAssertNil(
            ProPaywallViewModel.savingsPercent(monthlyPrice: 1, yearlyPrice: 24)
        )
    }

    func test_savingsBadge_readsSave58() {
        XCTAssertEqual(loaded().savingsBadge, "Save 58%")
    }

    // MARK: - Selection

    func test_yearlyIsPreselected() {
        XCTAssertEqual(ProPaywallViewModel().selectedPlan, .yearly)
        XCTAssertEqual(loaded().selectedPlan, .yearly)
    }

    func test_defaultPricesBeforeStoreKitLoads() {
        let vm = ProPaywallViewModel()
        XCTAssertEqual(vm.monthlyDisplayPrice, "$2.99")
        XCTAssertEqual(vm.yearlyDisplayPrice, "$14.99")
    }

    func test_applyKeepsDefaultsWhenStoreKitReturnsNothing() {
        let vm = ProPaywallViewModel()
        vm.apply(monthlyDisplayPrice: nil, monthlyPrice: nil,
                 yearlyDisplayPrice: nil, yearlyPrice: nil, isTrialEligible: true)
        XCTAssertEqual(vm.monthlyDisplayPrice, "$2.99")
        XCTAssertEqual(vm.yearlyDisplayPrice, "$14.99")
        XCTAssertEqual(vm.savingsBadge, "Save 58%")
    }

    func test_applyUsesStoreKitPricesForOtherStorefronts() {
        let vm = ProPaywallViewModel()
        vm.apply(monthlyDisplayPrice: "€3.49", monthlyPrice: Decimal(string: "3.49"),
                 yearlyDisplayPrice: "€19.99", yearlyPrice: Decimal(string: "19.99"),
                 isTrialEligible: true)
        XCTAssertEqual(vm.monthlyDisplayPrice, "€3.49")
        XCTAssertEqual(vm.yearlyDisplayPrice, "€19.99")
        XCTAssertEqual(vm.savingsBadge, "Save 52%")
    }

    // MARK: - CTA and fineprint

    func test_trialCTA_onlyAppliesToYearly() {
        let vm = loaded()
        XCTAssertTrue(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Start 7-day free trial")

        vm.selectedPlan = .monthly
        XCTAssertFalse(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $2.99/month")
    }

    func test_ineligibleUserSeesAPlainYearlyCTA() {
        let vm = loaded(isTrialEligible: false)
        XCTAssertFalse(vm.trialAppliesToSelection)
        XCTAssertEqual(vm.ctaTitle, "Subscribe for $14.99/year")
    }

    func test_fineprintNamesThePriceAfterTheTrial() {
        let vm = loaded()
        XCTAssertEqual(vm.fineprint, "7 days free, then $14.99/year. Cancel anytime in Settings.")

        vm.selectedPlan = .monthly
        XCTAssertEqual(vm.fineprint, "$2.99/month. Cancel anytime in Settings.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ProPaywallViewModelTests -quiet 2>&1 | tail -20
```
Expected: compile error `cannot find 'ProPaywallViewModel' in scope`.

- [ ] **Step 3: Rewrite `ProPaywallView.swift`**

Replace the whole file with:

```swift
import SwiftUI
import StoreKit

// MARK: - View model

@MainActor
final class ProPaywallViewModel: ObservableObject {
    enum Plan: String, CaseIterable, Identifiable {
        case yearly, monthly
        var id: String { rawValue }
    }

    /// Yearly is preselected (spec §7).
    @Published var selectedPlan: Plan = .yearly

    /// Spec prices, shown until StoreKit answers so the paywall never flashes
    /// an empty button. StoreKit is authoritative once `apply` runs.
    @Published private(set) var monthlyDisplayPrice: String = "$2.99"
    @Published private(set) var yearlyDisplayPrice: String = "$14.99"
    @Published private(set) var savingsBadge: String? = "Save 58%"
    @Published private(set) var isTrialEligible: Bool = true

    func apply(
        monthlyDisplayPrice: String?,
        monthlyPrice: Decimal?,
        yearlyDisplayPrice: String?,
        yearlyPrice: Decimal?,
        isTrialEligible: Bool
    ) {
        if let monthlyDisplayPrice { self.monthlyDisplayPrice = monthlyDisplayPrice }
        if let yearlyDisplayPrice { self.yearlyDisplayPrice = yearlyDisplayPrice }
        self.isTrialEligible = isTrialEligible

        if let monthlyPrice, let yearlyPrice,
           let percent = Self.savingsPercent(monthlyPrice: monthlyPrice, yearlyPrice: yearlyPrice) {
            savingsBadge = "Save \(percent)%"
        } else if monthlyPrice != nil || yearlyPrice != nil {
            savingsBadge = nil
        }
    }

    /// How much cheaper a year of `yearly` is than twelve months of `monthly`.
    /// $2.99 × 12 = $35.88 vs $14.99 → 58%.
    static func savingsPercent(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        let annualized = monthlyPrice * 12
        guard annualized > 0, yearlyPrice < annualized else { return nil }
        let ratio = (annualized - yearlyPrice) / annualized
        let percent = NSDecimalNumber(decimal: ratio).doubleValue * 100
        return Int(percent.rounded())
    }

    /// The trial rides on the yearly product only.
    var trialAppliesToSelection: Bool {
        isTrialEligible && selectedPlan == .yearly
    }

    var ctaTitle: String {
        if trialAppliesToSelection { return "Start 7-day free trial" }
        return selectedPlan == .yearly
            ? "Subscribe for \(yearlyDisplayPrice)/year"
            : "Subscribe for \(monthlyDisplayPrice)/month"
    }

    var fineprint: String {
        if trialAppliesToSelection {
            return "7 days free, then \(yearlyDisplayPrice)/year. Cancel anytime in Settings."
        }
        return selectedPlan == .yearly
            ? "\(yearlyDisplayPrice)/year. Cancel anytime in Settings."
            : "\(monthlyDisplayPrice)/month. Cancel anytime in Settings."
    }
}

// MARK: - Sheet

struct ProPaywallView: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProPaywallContent()
                .background(Color.paper.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(Color.ink)
                                .frame(width: 32, height: 32)
                                .background(Color.mist)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .onChange(of: storeKit.isProUser) { _, isPro in
            if isPro { dismiss() }
        }
    }
}

// MARK: - Shared body

/// The paywall itself. Used as a sheet by `ProPaywallView` and inline as the
/// final onboarding step, where `skipTitle`/`onSkip` add the free-tier exit.
struct ProPaywallContent: View {
    @EnvironmentObject private var storeKit: StoreKitService
    @Environment(\.openURL) private var openURL
    @StateObject private var vm = ProPaywallViewModel()

    private let skipTitle: String?
    private let onSkip: (() -> Void)?

    @State private var purchaseError: String?
    @State private var purchaseInProgress: Bool = false

    init(skipTitle: String? = nil, onSkip: (() -> Void)? = nil) {
        self.skipTitle = skipTitle
        self.onSkip = onSkip
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ShrunkTheme.Spacing.lg) {
                hero
                    .padding(.top, ShrunkTheme.Spacing.md)
                if vm.isTrialEligible {
                    trialCallout
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
                planPicker
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                valueProps
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                ctaSection
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                legal
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }
            .padding(.bottom, ShrunkTheme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
        .alert(
            "Couldn't complete purchase",
            isPresented: Binding(get: { purchaseError != nil }, set: { if !$0 { purchaseError = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(purchaseError ?? "") }
        )
    }

    private func load() async {
        if storeKit.yearlyProduct == nil || storeKit.monthlyProduct == nil {
            await storeKit.loadProducts()
        }
        await storeKit.refreshTrialEligibility()
        vm.apply(
            monthlyDisplayPrice: storeKit.monthlyProduct?.displayPrice,
            monthlyPrice: storeKit.monthlyProduct?.price,
            yearlyDisplayPrice: storeKit.yearlyProduct?.displayPrice,
            yearlyPrice: storeKit.yearlyProduct?.price,
            isTrialEligible: storeKit.isTrialEligible
        )
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 110, height: 110)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 4) {
                Text("Shrunk Pro")
                    .font(.shrunkDisplay)
                    .foregroundStyle(Color.ink)
                Text("Catch every shrink on the shelf you actually shop.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Trial callout

    private var trialCallout: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.verdictGoodTint)
                    .frame(width: 44, height: 44)
                Image(systemName: "gift.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.verdictGood)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Your first 7 days are free")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Color.ink)
                Text("On the yearly plan. Cancel any time before it ends and you pay nothing.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.verdictGood.opacity(0.25), lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    // MARK: Plans

    private var planPicker: some View {
        VStack(spacing: 10) {
            planRow(
                plan: .yearly,
                title: "Yearly",
                price: "\(vm.yearlyDisplayPrice)/year",
                caption: vm.isTrialEligible ? "7 days free, then billed yearly" : "Billed once a year",
                badge: vm.savingsBadge
            )
            planRow(
                plan: .monthly,
                title: "Monthly",
                price: "\(vm.monthlyDisplayPrice)/month",
                caption: "Billed every month",
                badge: nil
            )
        }
    }

    private func planRow(plan: ProPaywallViewModel.Plan, title: String, price: String, caption: String, badge: String?) -> some View {
        let isSelected = vm.selectedPlan == plan
        return Button {
            vm.selectedPlan = plan
        } label: {
            HStack(spacing: ShrunkTheme.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.shrunkRed : Color.smokeSoft)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Color.ink)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.verdictGood)
                                .clipShape(Capsule())
                        }
                    }
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
                Spacer(minLength: 0)
                Text(price)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            .padding(ShrunkTheme.Spacing.md)
            .background(isSelected ? Color.shrunkRedLight : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? Color.shrunkRed : Color.borderSoft,
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .shrunkElevation(isSelected ? ShrunkTheme.Elevation.card : ShrunkTheme.Elevation.whisper)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Value props

    private var valueProps: some View {
        VStack(spacing: 8) {
            valueRow(icon: "bell.badge.fill", color: .shrunkRed,
                     title: "Watchlist alerts",
                     body: "Push the moment a watched product shrinks or its price per unit jumps 5%.")
            valueRow(icon: "calendar.badge.clock", color: .verdictWarn,
                     title: "Weekly digest",
                     body: "What shrank this week in the categories you buy.")
            valueRow(icon: "list.bullet.rectangle.fill", color: .verdictGood,
                     title: "Every alternative, ranked",
                     body: "Cheapest per unit, in stock, at your store — not just the first three.")
            valueRow(icon: "chart.xyaxis.line", color: .shrunkRedDark,
                     title: "Full size and price history",
                     body: "Every observation we hold, not just the latest before and after.")
            valueRow(icon: "shield.checkered", color: .verdictGood,
                     title: "Real savings dashboard",
                     body: "What each shrink actually costs you a year, from observed sizes and prices.")
        }
    }

    private func valueRow(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
    }

    // MARK: CTA

    private var ctaSection: some View {
        VStack(spacing: 10) {
            ShrunkButton(vm.ctaTitle, icon: "lock.open.fill", isLoading: purchaseInProgress) {
                Task { await buy() }
            }
            if let skipTitle, let onSkip {
                Button(skipTitle) { onSkip() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoke)
            }
        }
    }

    private func buy() async {
        let product = vm.selectedPlan == .yearly ? storeKit.yearlyProduct : storeKit.monthlyProduct
        guard let product else {
            purchaseError = StoreKitError.productNotLoaded.errorDescription
            return
        }
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await storeKit.purchase(product)
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: Legal

    private var legal: some View {
        VStack(spacing: 8) {
            Button("Restore purchases") {
                Task { await storeKit.restore() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.smoke)

            HStack(spacing: 16) {
                Button("Terms") {
                    if let url = URL(string: "https://stackcurious.com/shrunk/terms") { openURL(url) }
                }
                Button("Privacy") {
                    if let url = URL(string: "https://stackcurious.com/shrunk/privacy") { openURL(url) }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.smoke)

            Text(vm.fineprint)
                .font(.system(size: 11))
                .foregroundStyle(Color.smokeSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Independent. No brand pays us. Ever.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
        }
        .padding(.top, ShrunkTheme.Spacing.sm)
    }
}

#Preview {
    ProPaywallView()
        .environmentObject(StoreKitService.shared)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the command from Step 2.
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Look at it**

Run the app on the simulator (the scheme's StoreKit configuration supplies the prices), open Settings → the Pro row, and confirm: yearly is preselected with a green **Save 58%** badge, the trial callout is above the plans, the CTA reads "Start 7-day free trial", tapping Monthly changes the CTA to "Subscribe for $2.99/month", and Restore/Terms/Privacy are all present.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Features/Settings/ProPaywallView.swift ShrunkTests/ProPaywallViewModelTests.swift
git commit -m "feat(ios): subscription paywall with trial, two plans and yearly preselected"
```

---

### Task 9: Onboarding trimmed to four steps

**Files:**
- Modify: `Shrunk/Models/OnboardingProfile.swift`
- Modify: `Shrunk/Features/Onboarding/OnboardingViewModel.swift` (full rewrite)
- Modify: `Shrunk/Features/Onboarding/OnboardingContainerView.swift` (full rewrite)
- Delete: `Shrunk/Services/SavingsForecast.swift`
- Test: `ShrunkTests/OnboardingViewModelTests.swift`

**Interfaces:**
- Consumes: `ProPaywallContent(skipTitle:onSkip:)` (Task 8); `StorePickerView(embedded:)` (Phase 3); `StoreKitService.isProUser` (Task 6).
- Produces: `OnboardingViewModel.Step` with exactly four cases — `welcome`, `categories`, `store`, `paywall`; `@Published var step`, `@Published var profile`; `canAdvance`, `progressFraction`, `advance()`, `back()`, `skipStore()`, `toggleCategory(_:)`, `selectFrequency(_:)`.
- Produces: `OnboardingProfile { var categories: Set<GroceryCategory>; var shopFrequency: ShopFrequency }` — `shopFrequency` is now **non-optional, defaulting to `.biweekly`**, and `encoded()`/`decoded(_:)` keep working.
- Deleted: `HouseholdSize`, `OnboardingProfile.householdSize`, `.monthlySpend`, `.defaultSpend`, `.minSpend`, `.maxSpend`, `GroceryCategory.basketShare`, `GroceryCategory.shrinkRate`, `SavingsForecast`, and the `problem`/`household`/`frequency`/`spend`/`socialProof`/`analyzing`/`reveal` steps with their views.
- `GroceryCategory` itself stays: it is the category set the user picks and the one synced to `/v1/devices`.

`SavingsForecast` can only be deleted here, because `SavingsForecast.compute` reads `profile.monthlySpend`. Task 8 already removed the paywall's use of it; this task removes the last two (`OnboardingViewModel.forecast` and `RevealStep`/`PaywallStep`).

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/OnboardingViewModelTests.swift`:

```swift
import XCTest
@testable import Shrunk

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    func test_flowIsExactlyFourSteps() {
        XCTAssertEqual(OnboardingViewModel.Step.allCases.count, 4)
        XCTAssertEqual(
            OnboardingViewModel.Step.allCases,
            [.welcome, .categories, .store, .paywall]
        )
    }

    func test_startsOnWelcomeAndWalksToThePaywall() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.step, .welcome)
        vm.advance()
        XCTAssertEqual(vm.step, .categories)
        vm.toggleCategory(.snacks)
        vm.advance()
        XCTAssertEqual(vm.step, .store)
        vm.advance()
        XCTAssertEqual(vm.step, .paywall)
        vm.advance()
        XCTAssertEqual(vm.step, .paywall, "the paywall is the last step")
    }

    func test_backWalksTheOtherWayAndStopsAtWelcome() {
        let vm = OnboardingViewModel()
        vm.advance()
        vm.back()
        XCTAssertEqual(vm.step, .welcome)
        vm.back()
        XCTAssertEqual(vm.step, .welcome)
    }

    func test_categoriesStepRequiresAtLeastOneCategory() {
        let vm = OnboardingViewModel()
        vm.advance()
        XCTAssertFalse(vm.canAdvance)
        vm.toggleCategory(.dairy)
        XCTAssertTrue(vm.canAdvance)
        vm.toggleCategory(.dairy)
        XCTAssertFalse(vm.canAdvance)
    }

    func test_storeStepIsSkippable() {
        let vm = OnboardingViewModel()
        vm.advance()
        vm.toggleCategory(.drinks)
        vm.advance()
        XCTAssertEqual(vm.step, .store)
        XCTAssertTrue(vm.canAdvance, "the store step never blocks")
        vm.skipStore()
        XCTAssertEqual(vm.step, .paywall)
    }

    func test_shopFrequencyDefaultsToBiweeklyAndIsSettable() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.profile.shopFrequency, .biweekly)
        vm.selectFrequency(.weekly)
        XCTAssertEqual(vm.profile.shopFrequency, .weekly)
    }

    func test_progressFractionRunsZeroToOne() {
        let vm = OnboardingViewModel()
        XCTAssertEqual(vm.progressFraction, 0, accuracy: 0.001)
        vm.step = .paywall
        XCTAssertEqual(vm.progressFraction, 1, accuracy: 0.001)
    }
}

final class OnboardingProfileTests: XCTestCase {

    func test_emptyProfileDefaultsToBiweeklyAndNoCategories() {
        XCTAssertEqual(OnboardingProfile.empty.shopFrequency, .biweekly)
        XCTAssertTrue(OnboardingProfile.empty.categories.isEmpty)
    }

    func test_roundTripsThroughJSON() {
        var profile = OnboardingProfile.empty
        profile.categories = [.snacks, .paper]
        profile.shopFrequency = .monthly

        let decoded = OnboardingProfile.decoded(profile.encoded())
        XCTAssertEqual(decoded.categories, [.snacks, .paper])
        XCTAssertEqual(decoded.shopFrequency, .monthly)
    }

    func test_decodesAnOldProfileThatStillCarriesRemovedFields() {
        // Installs from before this phase have household/spend keys in
        // UserDefaults; they must decode, not reset the user to zero.
        let legacy = #"{"householdSize":"threeFour","shopFrequency":"weekly","categories":["dairy"],"monthlySpend":650}"#
        let decoded = OnboardingProfile.decoded(legacy)
        XCTAssertEqual(decoded.categories, [.dairy])
        XCTAssertEqual(decoded.shopFrequency, .weekly)
    }

    func test_decodesAProfileWithNoFrequencyAtAll() {
        let decoded = OnboardingProfile.decoded("{}")
        XCTAssertEqual(decoded.shopFrequency, .biweekly)
        XCTAssertTrue(decoded.categories.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/OnboardingViewModelTests \
  -only-testing:ShrunkTests/OnboardingProfileTests -quiet 2>&1 | tail -20
```
Expected: failures on `Step.allCases.count` (10, not 4) and `cannot find 'welcome' in scope`.

- [ ] **Step 3: Trim `OnboardingProfile.swift`**

Replace the whole file with:

```swift
import Foundation

enum ShopFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly, biweekly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly:    return "Every week"
        case .biweekly:  return "Every 2 weeks"
        case .monthly:   return "Once a month"
        }
    }

    var shortLabel: String {
        switch self {
        case .weekly:    return "Weekly"
        case .biweekly:  return "Every 2 wks"
        case .monthly:   return "Monthly"
        }
    }

    var icon: String {
        switch self {
        case .weekly:    return "calendar"
        case .biweekly:  return "calendar.badge.clock"
        case .monthly:   return "calendar.circle"
        }
    }
}

/// The categories a user picks in onboarding. Synced to `/v1/devices` so the
/// weekly digest can be filtered (spec §6.2).
enum GroceryCategory: String, Codable, CaseIterable, Identifiable {
    case snacks, drinks, dairy, cleaning, personal, paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .snacks:    return "Snacks"
        case .drinks:    return "Drinks"
        case .dairy:     return "Dairy"
        case .cleaning:  return "Cleaning"
        case .personal:  return "Personal"
        case .paper:     return "Paper"
        }
    }

    var icon: String {
        switch self {
        case .snacks:    return "popcorn.fill"
        case .drinks:    return "cup.and.saucer.fill"
        case .dairy:     return "drop.fill"
        case .cleaning:  return "sparkles"
        case .personal:  return "drop.degreesign"
        case .paper:     return "rectangle.stack.fill"
        }
    }
}

/// Persisted via @AppStorage as JSON. Two fields, both of which drive real
/// behaviour: `categories` filters the digest, `shopFrequency` is the
/// purchases-per-year multiplier in the savings dashboard (spec §3.5).
struct OnboardingProfile: Codable, Equatable {
    var categories: Set<GroceryCategory> = []
    var shopFrequency: ShopFrequency = .biweekly

    static let empty = OnboardingProfile()

    /// Custom decoding so profiles written before this phase — which carry
    /// `householdSize` and `monthlySpend`, and may omit `shopFrequency` —
    /// still decode instead of resetting the user.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent(Set<GroceryCategory>.self, forKey: .categories) ?? []
        shopFrequency = try container.decodeIfPresent(ShopFrequency.self, forKey: .shopFrequency) ?? .biweekly
    }

    init(categories: Set<GroceryCategory> = [], shopFrequency: ShopFrequency = .biweekly) {
        self.categories = categories
        self.shopFrequency = shopFrequency
    }
}

extension OnboardingProfile {
    /// JSON round-trip helpers for @AppStorage (UserDefaults stores String).
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func decoded(_ raw: String) -> OnboardingProfile {
        guard let data = raw.data(using: .utf8),
              let profile = try? JSONDecoder().decode(OnboardingProfile.self, from: data)
        else { return .empty }
        return profile
    }
}
```

- [ ] **Step 4: Rewrite `OnboardingViewModel.swift`**

Replace the whole file with:

```swift
import Foundation
import SwiftUI

@MainActor
final class OnboardingViewModel: ObservableObject {
    /// Spec §7: welcome → pick categories → set store (skippable) → paywall.
    enum Step: Int, CaseIterable, Identifiable {
        case welcome    = 0
        case categories
        case store
        case paywall

        var id: Int { rawValue }

        var showsProgress: Bool { self != .welcome }

        /// Only the store step can be skipped; the paywall owns its own exit.
        var allowsSkip: Bool { self == .store }
    }

    @Published var step: Step = .welcome
    @Published var profile: OnboardingProfile = .empty

    /// The CTA is enabled only when the step's required data is captured.
    var canAdvance: Bool {
        switch step {
        case .categories: return !profile.categories.isEmpty
        default:          return true
        }
    }

    var progressFraction: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) { step = next }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(.easeInOut(duration: 0.32)) { step = previous }
    }

    /// "I'll do this later" on the store step — a store is optional everywhere
    /// in the app (spec §8: loss of Kroger degrades, never breaks).
    func skipStore() {
        withAnimation(.easeInOut(duration: 0.32)) { step = .paywall }
    }

    func toggleCategory(_ category: GroceryCategory) {
        if profile.categories.contains(category) {
            profile.categories.remove(category)
        } else {
            profile.categories.insert(category)
        }
    }

    func selectFrequency(_ frequency: ShopFrequency) {
        profile.shopFrequency = frequency
    }
}
```

- [ ] **Step 5: Rewrite `OnboardingContainerView.swift`**

Replace the whole file with:

```swift
import SwiftUI

struct OnboardingContainerView: View {
    @StateObject private var vm = OnboardingViewModel()
    @EnvironmentObject private var storeKit: StoreKitService

    @AppStorage("shrunk.onboarding_profile") private var persistedProfile: String = "{}"

    let onFinish: () -> Void

    var body: some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                progressBar
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ctaSection
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                    .padding(.bottom, ShrunkTheme.Spacing.lg)
            }
        }
        .onChange(of: vm.profile) { _, profile in
            persistedProfile = profile.encoded()
        }
        .onChange(of: storeKit.isProUser) { _, isPro in
            if isPro { finish() }
        }
    }

    private func finish() {
        persistedProfile = vm.profile.encoded()
        onFinish()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            if vm.step == .welcome {
                HStack(spacing: 6) {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.shrunkRed)
                    Text("SHRUNK")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.ink)
                }
            } else {
                Button {
                    vm.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Color.ink)
                        .frame(width: 36, height: 36)
                        .background(Color.mist)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
            if vm.step.allowsSkip {
                Button("Skip") { vm.skipStore() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.smoke)
            }
        }
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
        .frame(height: 52)
    }

    @ViewBuilder
    private var progressBar: some View {
        if vm.step.showsProgress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.border)
                        .frame(height: 4)
                    Capsule()
                        .fill(LinearGradient.shrunkRedDiagonal)
                        .frame(width: geo.size.width * vm.progressFraction, height: 4)
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: vm.progressFraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, ShrunkTheme.Spacing.md)
        } else {
            Color.clear.frame(height: 4 + ShrunkTheme.Spacing.md)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch vm.step {
        case .welcome:    WelcomeStep()
        case .categories: CategoriesStep(vm: vm)
        case .store:      StoreStep()
        case .paywall:
            ProPaywallContent(skipTitle: "Continue with the free version") { finish() }
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        if vm.step == .paywall {
            // ProPaywallContent owns its own CTA and free-tier exit.
            Color.clear.frame(height: 0)
        } else {
            ShrunkButton(ctaTitle, icon: "arrow.right", isLoading: false) {
                vm.advance()
            }
            .opacity(vm.canAdvance ? 1 : 0.35)
            .allowsHitTesting(vm.canAdvance)
            .animation(.easeOut(duration: 0.15), value: vm.canAdvance)
        }
    }

    private var ctaTitle: String {
        switch vm.step {
        case .welcome:    return "Show me how"
        case .categories: return "Continue"
        case .store:      return "Use this store"
        case .paywall:    return "Continue"
        }
    }
}

// MARK: - Step 1: WELCOME

private struct WelcomeStep: View {
    @State private var arrowDrop: CGFloat = -10

    var body: some View {
        VStack(spacing: ShrunkTheme.Spacing.xl) {
            Spacer(minLength: ShrunkTheme.Spacing.md)
            illustration
                .frame(maxWidth: .infinity)
            VStack(spacing: ShrunkTheme.Spacing.md) {
                Text("They're shrinking your groceries.")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                Text("Same price. Less product. Scan a barcode and see exactly what changed.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            Spacer()
        }
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(Color.shrunkRedLight)
                .frame(width: 240, height: 240)
                .blur(radius: 12)
                .opacity(0.7)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .frame(width: 156, height: 196)
                .rotationEffect(.degrees(-6))
                .offset(x: -22, y: 6)
                .shrunkElevation(ShrunkTheme.Elevation.card)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
                .frame(width: 156, height: 196)
                .overlay(
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(Color.mist).frame(width: 80, height: 8)
                        Capsule().fill(Color.mist).frame(width: 110, height: 8)
                        Capsule().fill(Color.mist).frame(width: 60, height: 8)
                        Spacer()
                        Capsule()
                            .fill(Color.shrunkRedLight)
                            .frame(width: 90, height: 24)
                            .overlay(
                                Text("$1.89")
                                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(Color.shrunkRedDark)
                            )
                    }
                    .padding(16)
                )
                .rotationEffect(.degrees(4))
                .offset(x: 18, y: -2)
                .shrunkElevation(ShrunkTheme.Elevation.card)
            ZStack {
                Circle()
                    .fill(LinearGradient.shrunkRedDiagonal)
                    .frame(width: 78, height: 78)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "arrow.down")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
            }
            .offset(x: 84, y: arrowDrop)
        }
        .frame(height: 260)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                arrowDrop = 14
            }
        }
    }
}

// MARK: - Step 2: CATEGORIES (+ shop frequency)

private struct CategoriesStep: View {
    @ObservedObject var vm: OnboardingViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                    Text("WHAT YOU BUY")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.smoke)
                    Text("What do you buy most?")
                        .font(.shrunkLargeTitle)
                        .foregroundStyle(Color.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("We'll watch these categories and send you the weekly digest.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.smoke)
                        .lineSpacing(2)
                }
                .padding(.top, ShrunkTheme.Spacing.sm)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(GroceryCategory.allCases) { category in
                        CategoryToggle(
                            category: category,
                            isSelected: vm.profile.categories.contains(category)
                        ) {
                            vm.toggleCategory(category)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                    Text("How often do you shop?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Picker("How often do you shop?", selection: Binding(
                        get: { vm.profile.shopFrequency },
                        set: { vm.selectFrequency($0) }
                    )) {
                        ForEach(ShopFrequency.allCases) { frequency in
                            Text(frequency.shortLabel).tag(frequency)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Sets how many times a year we count each shrink against you.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smokeSoft)
                }
                .padding(.top, ShrunkTheme.Spacing.sm)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.bottom, ShrunkTheme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }
}

private struct CategoryToggle: View {
    let category: GroceryCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.shrunkRed : Color.shrunkRedLight)
                        .frame(width: 50, height: 50)
                    Image(systemName: category.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : Color.shrunkRed)
                }
                Text(category.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isSelected ? Color.shrunkRedLight : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? Color.shrunkRed : Color.borderSoft,
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .shrunkElevation(isSelected ? ShrunkTheme.Elevation.card : ShrunkTheme.Elevation.whisper)
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Step 3: STORE (skippable)

private struct StoreStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                Text("YOUR STORE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.smoke)
                Text("Where do you shop?")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pick a Kroger store and we'll show live prices and cost per ounce. You can skip this and add it later in Settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, ShrunkTheme.Spacing.sm)
            .padding(.horizontal, ShrunkTheme.Spacing.lg)

            // Phase 3. Writes @AppStorage("storeLocationId").
            StorePickerView(embedded: true)
        }
    }
}

#Preview {
    OnboardingContainerView { }
        .environmentObject(StoreKitService.shared)
}
```

- [ ] **Step 6: Delete `SavingsForecast` and prove nothing references it**

```bash
git rm -q Shrunk/Services/SavingsForecast.swift
grep -rn "SavingsForecast\|monthlySpend\|householdSize\|HouseholdSize\|basketShare\|shrinkRate" Shrunk ShrunkTests \
  || echo "no remaining references"
```
Expected: `no remaining references`. Any hit is a call site this task still has to remove.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/OnboardingViewModelTests \
  -only-testing:ShrunkTests/OnboardingProfileTests -quiet 2>&1 | tail -20
```
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 8: Walk the flow on the simulator**

Delete the app from the simulator first so onboarding runs. Expected: four screens, a back chevron from screen two onward, **Skip** visible only on the store screen, Continue disabled on categories until one is tapped, the frequency control defaulting to "Every 2 wks", and the paywall as the last screen with "Continue with the free version" beneath the CTA.

- [ ] **Step 9: Commit**

```bash
git add -A Shrunk/Models/OnboardingProfile.swift Shrunk/Features/Onboarding Shrunk/Services/SavingsForecast.swift ShrunkTests/OnboardingViewModelTests.swift
git commit -m "feat(ios): four-step onboarding; delete the invented savings forecast"
```

---

### Task 10: Savings dashboard on observed data

**Files:**
- Modify: `Shrunk/Models/ShrinkAlert.swift` (add `currentPrice`)
- Modify: `Shrunk/Models/WatchedProduct.swift` (add `lastKnownPrice`, `lastShrinkPercent`)
- Modify: `Shrunk/Services/WatchlistService.swift` (`add(product:record:)`, keep price fresh in the sweep)
- Modify: `Shrunk/Features/Result/ResultView.swift` (one call site)
- Modify: `Shrunk/Services/SavingsLedger.swift` (full rewrite)
- Modify: `Shrunk/Features/Dashboard/SavingsDashboardView.swift` (full rewrite)
- Modify: `Shrunk/Features/Alerts/AlertsFeedView.swift` (savings hero)
- Test: `ShrunkTests/SavingsLedgerTests.swift`

**Interfaces:**
- Consumes: `OnboardingProfile.shopFrequency`, `ShopFrequency` (Task 9); `ShrinkRecord.priceNow`, `.shrinkPercent`, `.currentSize`, `.verdict` (Phase 1).
- Produces:
  - `SavingsEntry { let id: String /* barcode */; let productName: String; let brand: String; let shrinkPercentAbs: Double; let currentPrice: Double; let annual: Double; let detectedAt: Date }`
  - `SavingsLedger { let entries: [SavingsEntry]; let totalAnnual: Double; static let empty; static func purchasesPerYear(for: ShopFrequency) -> Double; static func build(alerts: [ShrinkAlert], watchlist: [WatchedProduct], shopFrequency: ShopFrequency) -> SavingsLedger; var totalDisplay: String; static func currencyString(_:) -> String }`
  - `ShrinkAlert.currentPrice: Double?`, `WatchedProduct.lastKnownPrice: Double?`, `WatchedProduct.lastShrinkPercent: Double`
  - `WatchlistService.add(product: ShrunkProduct, record: ShrinkRecord) throws` (replaces `add(product:currentSize:)`)
  - `WatchedProduct.from(product: ShrunkProduct, record: ShrinkRecord) -> WatchedProduct` (replaces `from(product:currentSize:)`)
- Removed: `SavingsCatch`, `SavingsLedger.totalProtected`, `.thisMonth`, `.ongoingAnnual`, `.catches`, `.dailyTotals`, `DailyTotal`, `typicalUnitPrice`, `build(alerts:profile:)`, the cumulative chart, and the "Background sweeps against Open Food Facts" empty-state line.

**Units.** `ShrinkRecord.shrinkPercent` and `ShrinkAlert.shrinkPercent` are **percentage points** (a 12.5% shrink is `-12.5`), which is what `ShrinkDetector` produces. `SavingsEntry.shrinkPercentAbs` is the **fraction** (`0.125`), because that is what multiplies a price. Converting once, at the boundary, is what makes `annual` right; the old `CatchRow` multiplied by 100 a second time and was wrong on screen.

**Which products count.** Spec §3.5 is "for each scanned or watched product". Concretely: every alert and every watched product that has a shrink verdict (`shrinkPercent < -1`, matching `ShrinkDetector`'s ±1% unchanged band) **and** a current price above zero. A product with no price at the user's store contributes nothing rather than a guess — that is the whole point of this phase.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/SavingsLedgerTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class SavingsLedgerTests: XCTestCase {

    private func alert(
        barcode: String = "0028400642255",
        name: String = "Doritos Nacho Cheese",
        percent: Double = -12.5,
        price: Double? = 4.99,
        daysAgo: Double = 1
    ) -> ShrinkAlert {
        ShrinkAlert(
            barcode: barcode,
            productName: name,
            brand: "Doritos",
            kind: .newShrink,
            shrinkPercent: percent,
            currentPrice: price,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400)
        )
    }

    private func watched(
        barcode: String = "0052000012897",
        name: String = "Gatorade Cool Blue",
        percent: Double = -10,
        price: Double? = 2.00
    ) -> WatchedProduct {
        WatchedProduct(
            barcode: barcode,
            productName: name,
            brand: "Gatorade",
            lastKnownSize: 828,
            lastKnownUnit: "ml",
            lastKnownPrice: price,
            lastShrinkPercent: percent
        )
    }

    // MARK: - Frequency

    func test_purchasesPerYear() {
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .weekly), 52)
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .biweekly), 26)
        XCTAssertEqual(SavingsLedger.purchasesPerYear(for: .monthly), 12)
    }

    // MARK: - Math

    func test_annualIsShrinkFractionTimesPriceTimesPurchases() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .biweekly)
        // 0.125 × $4.99 × 26 = $16.2175
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].shrinkPercentAbs, 0.125, accuracy: 0.0001)
        XCTAssertEqual(ledger.entries[0].annual, 16.2175, accuracy: 0.001)
        XCTAssertEqual(ledger.totalAnnual, 16.2175, accuracy: 0.001)
    }

    func test_frequencyScalesTheTotal() {
        let weekly = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .weekly)
        let monthly = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .monthly)
        XCTAssertEqual(weekly.totalAnnual / monthly.totalAnnual, 52.0 / 12.0, accuracy: 0.0001)
    }

    func test_watchedProductsCountToo() {
        let ledger = SavingsLedger.build(alerts: [], watchlist: [watched()], shopFrequency: .monthly)
        // 0.10 × $2.00 × 12 = $2.40
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].annual, 2.40, accuracy: 0.001)
    }

    func test_alertsAndWatchlistSumTogether() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [watched()], shopFrequency: .monthly)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertEqual(ledger.totalAnnual, 7.485 + 2.40, accuracy: 0.001)
    }

    // MARK: - Filtering

    func test_productsWithoutAPriceAreExcluded() {
        let ledger = SavingsLedger.build(
            alerts: [alert(price: nil)],
            watchlist: [watched(price: 0)],
            shopFrequency: .weekly
        )
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertEqual(ledger.totalAnnual, 0)
    }

    func test_productsWithoutAShrinkVerdictAreExcluded() {
        let unchanged = alert(percent: -0.4)   // inside the ±1% unchanged band
        let grew = alert(barcode: "0000000000017", percent: 3.0)
        let ledger = SavingsLedger.build(alerts: [unchanged, grew], watchlist: [], shopFrequency: .weekly)
        XCTAssertTrue(ledger.entries.isEmpty)
    }

    func test_minorShrinkStillCounts() {
        let ledger = SavingsLedger.build(alerts: [alert(percent: -2.0)], watchlist: [], shopFrequency: .weekly)
        XCTAssertEqual(ledger.entries.count, 1)
    }

    // MARK: - Shape

    func test_oneEntryPerBarcodeWithTheAlertWinning() {
        let sameBarcode = watched(barcode: "0028400642255", name: "Doritos (stale copy)", percent: -3, price: 9.99)
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [sameBarcode], shopFrequency: .biweekly)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries[0].productName, "Doritos Nacho Cheese")
        XCTAssertEqual(ledger.entries[0].currentPrice, 4.99)
    }

    func test_entriesAreSortedByAnnualDescending() {
        let big = alert(barcode: "0000000000010", name: "Big", percent: -20, price: 10)
        let small = alert(barcode: "0000000000027", name: "Small", percent: -2, price: 1)
        let ledger = SavingsLedger.build(alerts: [small, big], watchlist: [], shopFrequency: .weekly)
        XCTAssertEqual(ledger.entries.map(\.productName), ["Big", "Small"])
    }

    func test_emptyInputsGiveTheEmptyLedger() {
        XCTAssertEqual(SavingsLedger.build(alerts: [], watchlist: [], shopFrequency: .weekly), .empty)
    }

    func test_totalDisplayIsWholeDollars() {
        let ledger = SavingsLedger.build(alerts: [alert()], watchlist: [], shopFrequency: .biweekly)
        XCTAssertEqual(ledger.totalDisplay, "$16")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/SavingsLedgerTests -quiet 2>&1 | tail -20
```
Expected: compile errors — `ShrinkAlert` has no `currentPrice` argument and `WatchedProduct` has no `lastKnownPrice`.

- [ ] **Step 3: Add the two model fields**

In `Shrunk/Models/ShrinkAlert.swift`, add the stored property after `shrinkPercent`:

```swift
    var currentPrice: Double?
```

add the initializer parameter after `shrinkPercent: Double = 0`:

```swift
        currentPrice: Double? = nil,
```

assign it alongside the others (`self.currentPrice = currentPrice`), and carry the observed price through the convenience constructor:

```swift
extension ShrinkAlert {
    static func newShrink(from watched: WatchedProduct, record: ShrinkRecord) -> ShrinkAlert {
        ShrinkAlert(
            barcode: watched.barcode,
            productName: watched.productName,
            brand: watched.brand,
            kind: .newShrink,
            previousQuantity: record.previousSize?.quantity,
            previousUnit: record.previousSize?.unit,
            currentQuantity: record.currentSize?.quantity,
            currentUnit: record.currentSize?.unit,
            shrinkPercent: record.shrinkPercent,
            currentPrice: record.priceNow,
            costDeltaPerUnit: nil
        )
    }
}
```

In `Shrunk/Models/WatchedProduct.swift`, add two stored properties after `lastKnownUnit`:

```swift
    var lastKnownPrice: Double?
    var lastShrinkPercent: Double
```

add the matching initializer parameters after `lastKnownUnit: String` (`lastKnownPrice: Double? = nil, lastShrinkPercent: Double = 0`), assign them, and replace the extension:

```swift
extension WatchedProduct {
    static func from(product: ShrunkProduct, record: ShrinkRecord) -> WatchedProduct {
        WatchedProduct(
            barcode: product.id,
            productName: product.name,
            brand: product.brand,
            lastKnownSize: record.currentSize?.quantity ?? 0,
            lastKnownUnit: record.currentSize?.unit ?? "count",
            lastKnownPrice: record.priceNow,
            lastShrinkPercent: record.shrinkPercent
        )
    }
}
```

Both additions are new optional/defaulted properties, which SwiftData migrates automatically — no `VersionedSchema` is needed.

- [ ] **Step 4: Keep the two fields fresh in `WatchlistService`**

Replace `add(product:currentSize:)` with:

```swift
    func add(product: ShrunkProduct, record: ShrinkRecord) throws {
        guard let currentSize = record.currentSize else { return }
        if let existing = try fetch(barcode: product.id) {
            existing.lastKnownSize = currentSize.quantity
            existing.lastKnownUnit = currentSize.unit
            existing.lastKnownPrice = record.priceNow
            existing.lastShrinkPercent = record.shrinkPercent
            existing.lastChecked = Date()
            try context.save()   // the old code returned without saving — a real bug
            return
        }
        let watched = WatchedProduct.from(product: product, record: record)
        context.insert(watched)
        try context.save()
    }
```

and in `refreshAll()`, immediately after the existing `item.lastChecked = Date()` line, add:

```swift
                item.lastKnownPrice = record.priceNow
                item.lastShrinkPercent = record.shrinkPercent
```

In `Shrunk/Features/Result/ResultView.swift`, `addToWatchlist` becomes:

```swift
    private func addToWatchlist(product: ShrunkProduct, record: ShrinkRecord) {
        let service = WatchlistService(context: modelContext)
        do {
            try service.add(product: product, record: record)
            watchedConfirmation = product.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
```

- [ ] **Step 5: Rewrite `SavingsLedger.swift`**

Replace the whole file with:

```swift
import Foundation

/// One product's annual cost of shrinking, computed from what we actually
/// observed: the measured size change and the current price at the user's
/// store (spec §3.5).
struct SavingsEntry: Identifiable, Equatable {
    let id: String            // barcode
    let productName: String
    let brand: String
    /// Fraction, not percentage points: a 12.5% shrink is 0.125.
    let shrinkPercentAbs: Double
    let currentPrice: Double
    let annual: Double
    let detectedAt: Date
}

/// The savings dashboard's model.
///
///     annual = |shrink%| × current price × purchases per year
///
/// Every input is observed. Products without a shrink verdict or without a
/// price contribute nothing — no category averages, no assumed basket, no
/// invented unit price.
struct SavingsLedger: Equatable {
    let entries: [SavingsEntry]   // largest annual cost first
    let totalAnnual: Double

    static let empty = SavingsLedger(entries: [], totalAnnual: 0)

    /// Below this the change is inside `ShrinkDetector`'s ±1% unchanged band.
    private static let shrinkThresholdPercent: Double = -1

    static func purchasesPerYear(for frequency: ShopFrequency) -> Double {
        switch frequency {
        case .weekly:   return 52
        case .biweekly: return 26
        case .monthly:  return 12
        }
    }

    static func build(
        alerts: [ShrinkAlert],
        watchlist: [WatchedProduct],
        shopFrequency: ShopFrequency
    ) -> SavingsLedger {
        let purchases = purchasesPerYear(for: shopFrequency)

        // Alerts are the fresher observation, so they win a barcode collision.
        var byBarcode: [String: SavingsEntry] = [:]

        for watched in watchlist {
            guard let entry = makeEntry(
                barcode: watched.barcode,
                productName: watched.productName,
                brand: watched.brand,
                shrinkPercent: watched.lastShrinkPercent,
                price: watched.lastKnownPrice,
                detectedAt: watched.lastChecked,
                purchases: purchases
            ) else { continue }
            byBarcode[watched.barcode] = entry
        }

        for alert in alerts {
            guard let entry = makeEntry(
                barcode: alert.barcode,
                productName: alert.productName,
                brand: alert.brand,
                shrinkPercent: alert.shrinkPercent,
                price: alert.currentPrice,
                detectedAt: alert.createdAt,
                purchases: purchases
            ) else { continue }
            byBarcode[alert.barcode] = entry
        }

        guard !byBarcode.isEmpty else { return .empty }

        let entries = byBarcode.values.sorted {
            $0.annual == $1.annual ? $0.id < $1.id : $0.annual > $1.annual
        }
        return SavingsLedger(
            entries: entries,
            totalAnnual: entries.reduce(0) { $0 + $1.annual }
        )
    }

    private static func makeEntry(
        barcode: String,
        productName: String,
        brand: String,
        shrinkPercent: Double,
        price: Double?,
        detectedAt: Date,
        purchases: Double
    ) -> SavingsEntry? {
        guard shrinkPercent < shrinkThresholdPercent else { return nil }
        guard let price, price > 0 else { return nil }

        let fraction = abs(shrinkPercent) / 100
        return SavingsEntry(
            id: barcode,
            productName: productName,
            brand: brand,
            shrinkPercentAbs: fraction,
            currentPrice: price,
            annual: fraction * price * purchases,
            detectedAt: detectedAt
        )
    }
}

extension SavingsLedger {
    /// "$487" — the dashboard hero.
    var totalDisplay: String { Self.currencyString(totalAnnual) }

    static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}
```

- [ ] **Step 6: Rewrite `SavingsDashboardView.swift`**

Replace the whole file with:

```swift
import SwiftUI
import SwiftData

struct SavingsDashboardView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ShrinkAlert.createdAt, order: .reverse)
    private var alerts: [ShrinkAlert]

    @Query(sort: \WatchedProduct.addedAt, order: .reverse)
    private var watchlist: [WatchedProduct]

    @AppStorage("shrunk.onboarding_profile") private var rawProfile: String = "{}"

    private var ledger: SavingsLedger {
        SavingsLedger.build(
            alerts: alerts,
            watchlist: watchlist,
            shopFrequency: OnboardingProfile.decoded(rawProfile).shopFrequency
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShrunkTheme.Spacing.lg) {
                    if ledger.entries.isEmpty {
                        emptyState
                            .padding(.top, ShrunkTheme.Spacing.xl)
                    } else {
                        hero
                        methodNote
                        entriesSection
                    }
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                .padding(.bottom, ShrunkTheme.Spacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(Color.paper.ignoresSafeArea())
            .navigationTitle("Savings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(Color.ink)
                            .frame(width: 32, height: 32)
                            .background(Color.mist)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 4) {
            Text("SHRINKFLATION COSTS YOU")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.smoke)
                .padding(.top, ShrunkTheme.Spacing.md)
            Text(ledger.totalDisplay)
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient.shrunkRedDiagonal)
            Text("a year, across \(ledger.entries.count) \(ledger.entries.count == 1 ? "product" : "products") you track")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.smoke)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var methodNote: some View {
        Text("Each product's size drop × its current price at your store × how often you shop. Observed sizes and prices only — nothing estimated.")
            .font(.system(size: 12))
            .foregroundStyle(Color.smoke)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.horizontal, ShrunkTheme.Spacing.sm)
    }

    // MARK: - Entries

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text("PER PRODUCT")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.smoke)
                Spacer()
            }
            VStack(spacing: 8) {
                ForEach(ledger.entries) { entry in
                    SavingsEntryRow(entry: entry)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: ShrunkTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.verdictGoodTint)
                    .frame(width: 140, height: 140)
                    .shrunkElevation(ShrunkTheme.Elevation.float)
                Image(systemName: "shield.checkered")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.verdictGood)
            }
            VStack(spacing: 8) {
                Text("Nothing to add up yet")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("This page only shows numbers we can back with data — a measured size drop and a real price at your store.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
            }

            VStack(spacing: 12) {
                howItWorksRow(
                    icon: "1.circle.fill",
                    title: "Set your store",
                    subtitle: "Settings → Store. Without a price we can't cost a shrink."
                )
                howItWorksRow(
                    icon: "2.circle.fill",
                    title: "Scan or watch what you buy",
                    subtitle: "Anything with a size history gets a verdict."
                )
                howItWorksRow(
                    icon: "3.circle.fill",
                    title: "We do the multiplication",
                    subtitle: "Size drop × price × how often you shop."
                )
            }
            .padding(.top, ShrunkTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
    }

    private func howItWorksRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: ShrunkTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.shrunkRed)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Row

private struct SavingsEntryRow: View {
    let entry: SavingsEntry

    var body: some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.productName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(percentText)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color.shrunkRedDark)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.shrunkRedLight)
                        .clipShape(Capsule())
                    Text(priceText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.smoke)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(SavingsLedger.currencyString(entry.annual))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.shrunkRedDark)
                Text("per year")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.smoke)
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }

    private var percentText: String {
        String(format: "-%.1f%%", entry.shrinkPercentAbs * 100)
    }

    private var priceText: String {
        let price = String(format: "%.2f", entry.currentPrice)
        return "at $\(price)"
    }
}
```

- [ ] **Step 7: Update the alerts-feed savings hero**

In `Shrunk/Features/Alerts/AlertsFeedView.swift`, add a second query next to the alerts one:

```swift
    @Query(sort: \WatchedProduct.addedAt, order: .reverse)
    private var watchlist: [WatchedProduct]
```

replace the ledger construction in `savingsHero`:

```swift
        let ledger = SavingsLedger.build(
            alerts: alerts,
            watchlist: watchlist,
            shopFrequency: OnboardingProfile.decoded(rawProfile).shopFrequency
        )
```

change the subtitle condition from `ledger.catches.isEmpty` to `ledger.entries.isEmpty`, and replace `savingsHeadline`:

```swift
    private func savingsHeadline(ledger: SavingsLedger) -> String {
        if ledger.totalAnnual > 0 {
            return "Shrinkflation is costing you \(ledger.totalDisplay)/yr"
        }
        return "Watching for sneaky shrinkflation"
    }
```

- [ ] **Step 8: Run the tests and the whole suite**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: `SavingsLedgerTests` 12 passed, and every other suite still green.

- [ ] **Step 9: Commit**

```bash
git add Shrunk/Models/ShrinkAlert.swift Shrunk/Models/WatchedProduct.swift Shrunk/Services/WatchlistService.swift Shrunk/Services/SavingsLedger.swift Shrunk/Features/Dashboard/SavingsDashboardView.swift Shrunk/Features/Alerts/AlertsFeedView.swift Shrunk/Features/Result/ResultView.swift ShrunkTests/SavingsLedgerTests.swift
git commit -m "feat(ios): savings dashboard computed from observed sizes and prices"
```

---

### Task 11: History chart — all observations for Pro, latest two for free

**Files:**
- Modify: `Shrunk/Features/Result/ShrinkHistoryChart.swift`
- Modify: `Shrunk/Features/Result/ResultView.swift` (chart call site)
- Test: `ShrunkTests/ShrinkHistoryChartTests.swift`

**Interfaces:**
- Consumes: `StoreKitService.isProUser` (Task 6); `SizeRecord`, `ShrinkDetector.normalize(_:)` (Phase 1).
- Produces: `ShrinkHistoryChart(history: [SizeRecord], isPro: Bool, onUpgrade: (() -> Void)? = nil)` and the pure `static func visibleHistory(_ history: [SizeRecord], isPro: Bool) -> [SizeRecord]` and `static func hiddenCount(_ history: [SizeRecord], isPro: Bool) -> Int`.
- `ResultView` gains no new state: it already owns `showWatchPaywall` and presents `ProPaywallView` as a sheet, so `onUpgrade` reuses it.

Spec §3.4 / §7: Pro sees every observation; free sees "the latest before/after only" — the two most recent, plus a "See full history with Pro" affordance whenever there is more history behind the lock.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/ShrinkHistoryChartTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class ShrinkHistoryChartTests: XCTestCase {

    private func record(_ daysAgo: Double, _ quantity: Double) -> SizeRecord {
        SizeRecord(
            date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            quantity: quantity,
            unit: "g",
            source: "fdc"
        )
    }

    private var fourPoints: [SizeRecord] {
        // Deliberately out of order — the chart sorts.
        [record(300, 28), record(1500, 32), record(0, 26), record(900, 30)]
    }

    func test_proSeesEveryObservationOldestFirst() {
        let visible = ShrinkHistoryChart.visibleHistory(fourPoints, isPro: true)
        XCTAssertEqual(visible.map(\.quantity), [32, 30, 28, 26])
    }

    func test_freeSeesOnlyTheLatestTwo() {
        let visible = ShrinkHistoryChart.visibleHistory(fourPoints, isPro: false)
        XCTAssertEqual(visible.map(\.quantity), [28, 26])
    }

    func test_freeWithExactlyTwoObservationsSeesBoth() {
        let two = [record(300, 28), record(0, 26)]
        XCTAssertEqual(ShrinkHistoryChart.visibleHistory(two, isPro: false).map(\.quantity), [28, 26])
    }

    func test_freeWithOneObservationSeesIt() {
        XCTAssertEqual(ShrinkHistoryChart.visibleHistory([record(0, 26)], isPro: false).map(\.quantity), [26])
    }

    func test_emptyHistoryStaysEmptyForBothTiers() {
        XCTAssertTrue(ShrinkHistoryChart.visibleHistory([], isPro: true).isEmpty)
        XCTAssertTrue(ShrinkHistoryChart.visibleHistory([], isPro: false).isEmpty)
    }

    func test_hiddenCountDrivesTheUpgradeAffordance() {
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount(fourPoints, isPro: false), 2)
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount(fourPoints, isPro: true), 0)
        XCTAssertEqual(ShrinkHistoryChart.hiddenCount([record(0, 26), record(1, 28)], isPro: false), 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ShrinkHistoryChartTests -quiet 2>&1 | tail -20
```
Expected: compile error `type 'ShrinkHistoryChart' has no member 'visibleHistory'`.

- [ ] **Step 3: Add the gating to `ShrinkHistoryChart`**

Replace the top of `Shrunk/Features/Result/ShrinkHistoryChart.swift` — the stored properties, the initializer, and `body` — with:

```swift
struct ShrinkHistoryChart: View {
    let history: [SizeRecord]
    let unitLabel: String
    let isPro: Bool
    let hiddenCount: Int
    let onUpgrade: (() -> Void)?

    @State private var selected: SizeRecord?

    /// Spec §3.4: Pro sees every observation, free sees the latest two.
    /// Always oldest-first, so the chart reads left to right in time.
    static func visibleHistory(_ history: [SizeRecord], isPro: Bool) -> [SizeRecord] {
        let sorted = history.sorted { $0.date < $1.date }
        guard !isPro else { return sorted }
        return Array(sorted.suffix(2))
    }

    /// How many observations the free tier is not being shown.
    static func hiddenCount(_ history: [SizeRecord], isPro: Bool) -> Int {
        isPro ? 0 : max(0, history.count - 2)
    }

    init(history: [SizeRecord], isPro: Bool, onUpgrade: (() -> Void)? = nil) {
        let visible = Self.visibleHistory(history, isPro: isPro)
        self.history = visible
        self.unitLabel = visible.first?.unit ?? "oz"
        self.isPro = isPro
        self.hiddenCount = Self.hiddenCount(history, isPro: isPro)
        self.onUpgrade = onUpgrade
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text("SIZE HISTORY")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.smoke)
                Spacer()
                if let selected {
                    Text("\(selected.quantity.formattedQuantity(unit: selected.unit)) · \(selected.date, format: .dateTime.year().month(.abbreviated))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.ink)
                }
            }

            if history.count >= 3 {
                chart
            } else if history.count == 2 {
                beforeAfter
            } else {
                EmptyView()
            }

            if hiddenCount > 0 {
                upgradeRow
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    // MARK: - Pro affordance

    private var upgradeRow: some View {
        Button {
            onUpgrade?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("See full history with Pro")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(hiddenCount) more")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.smoke)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.smoke)
            }
            .foregroundStyle(Color.shrunkRedDark)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color.shrunkRedLight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onUpgrade == nil)
        .accessibilityLabel("See full history with Pro, \(hiddenCount) more observations")
    }
```

Leave `chart`, `barColor(at:)`, `beforeAfter`, and `sideCell` exactly as they are — they already read `history`, which is now the gated slice.

Replace the two previews at the bottom of the file with:

```swift
#Preview("Free — latest two of four") {
    ShrinkHistoryChart(
        history: [
            SizeRecord(date: .now.addingTimeInterval(-1500 * 24 * 3600), quantity: 32, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-900 * 24 * 3600),  quantity: 30, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-300 * 24 * 3600),  quantity: 28, unit: "oz", source: "crowd"),
            SizeRecord(date: .now,                                       quantity: 26, unit: "oz", source: "kroger")
        ],
        isPro: false,
        onUpgrade: {}
    )
    .padding()
}

#Preview("Pro — all four") {
    ShrinkHistoryChart(
        history: [
            SizeRecord(date: .now.addingTimeInterval(-1500 * 24 * 3600), quantity: 32, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-900 * 24 * 3600),  quantity: 30, unit: "oz", source: "fdc"),
            SizeRecord(date: .now.addingTimeInterval(-300 * 24 * 3600),  quantity: 28, unit: "oz", source: "crowd"),
            SizeRecord(date: .now,                                       quantity: 26, unit: "oz", source: "kroger")
        ],
        isPro: true
    )
    .padding()
}
```

- [ ] **Step 4: Pass the entitlement in from `ResultView`**

In `Shrunk/Features/Result/ResultView.swift`, replace the chart call site inside `loadedView`:

```swift
                if product.sizeHistory.count >= 2 {
                    ShrinkHistoryChart(
                        history: product.sizeHistory,
                        isPro: storeKit.isProUser,
                        onUpgrade: { showWatchPaywall = true }
                    )
                    .padding(.horizontal, ShrunkTheme.Spacing.lg)
                }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the command from Step 2.
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 6: See it both ways**

On the simulator, scan a GTIN with three or more observations (the Task 9 D1 query in the Phase 1 plan lists them). As a free user the chart shows the before/after pair with a red "See full history with Pro · N more" row that opens the paywall; buy a subscription through the StoreKit configuration and the chart redraws with every bar.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Features/Result/ShrinkHistoryChart.swift Shrunk/Features/Result/ResultView.swift ShrunkTests/ShrinkHistoryChartTests.swift
git commit -m "feat(ios): gate full size history behind Pro"
```

---

### Task 12: App Store Connect setup sheet and the superseded monetization note

**Files:**
- Modify: `docs/ASC_SETUP.md` (§2, §7, and the pre-submission checklist)
- Modify: `tasks/shrunk_v2_monetization.md` (one line at the top)

**Interfaces:**
- Consumes: the deployed Worker origin printed by `wrangler deploy` in Task 4, Step 5.
- Produces: no code. This is the configuration an operator has to enter by hand in App Store Connect, and it must match `Shrunk/Resources/Shrunk.storekit` exactly or the build ships against products that do not exist.

- [ ] **Step 1: Replace §2 of `docs/ASC_SETUP.md`**

Replace the whole "## 2. In-App Purchase" section (heading through its closing `---`) with:

```markdown
## 2. Subscriptions (ASC → app → Monetization → Subscriptions)

Create **one subscription group**, then two subscriptions inside it. The product IDs must match `Shrunk/Resources/Shrunk.storekit` and `ShrunkProProduct` in `Shrunk/Services/StoreKitService.swift` character for character.

| Field | Value |
|---|---|
| Subscription Group Reference Name | `Shrunk Pro` |
| Group Localization (en-US) — Display Name | `Shrunk Pro` |
| App Name in group localization | `Shrunk` |

### 2a. Yearly (create this one first — it is the preselected plan)

| Field | Value |
|---|---|
| Reference Name | `Shrunk Pro Yearly` |
| Product ID | `com.shrunk.pro.yearly` |
| Subscription Duration | **1 Year** |
| Price | **$14.99** (United States; let ASC generate the other storefronts) |
| Subscription Level (rank in group) | **1** |
| Display Name (en-US) | `Shrunk Pro Yearly` |
| Description (en-US) | `Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.` |

### 2b. Monthly

| Field | Value |
|---|---|
| Reference Name | `Shrunk Pro Monthly` |
| Product ID | `com.shrunk.pro.monthly` |
| Subscription Duration | **1 Month** |
| Price | **$2.99** (United States) |
| Subscription Level (rank in group) | **2** |
| Display Name (en-US) | `Shrunk Pro Monthly` |
| Description (en-US) | `Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.` |

Level 1 for yearly and level 2 for monthly makes monthly → yearly an upgrade and yearly → monthly a downgrade, which is what the paywall's "Save 58%" implies.

### 2c. Introductory Offer — 7-day free trial (yearly only)

On `com.shrunk.pro.yearly` → **Introductory Offers → Create Introductory Offer**:

| Field | Value |
|---|---|
| Countries or Regions | United States |
| Start Date | today |
| End Date | **No End Date** |
| Type | **Free Trial** |
| Duration | **1 Week** |

Do **not** add an introductory offer to the monthly product — the app's paywall shows the trial only on the yearly plan and `StoreKitConfigurationTests` asserts monthly has none.

### 2d. App Store Server Notifications V2

ASC → app → **General → App Information → App Store Server Notifications**:

| Field | Value |
|---|---|
| Version | **Version 2** |
| Production Server URL | `https://<worker>/v1/appstore/notifications` |
| Sandbox Server URL | `https://<worker>/v1/appstore/notifications` |

Replace `<worker>` with the origin printed by `wrangler deploy` (for example `shrunk-api.stackcurious.workers.dev`). The endpoint verifies Apple's signature against a pinned copy of Apple Root CA - G3, needs no shared secret, and answers `401 {"error":"invalid_signature"}` to anything it cannot verify — which is what ASC's **Test Notification** button will surface if the URL is wrong.

- Upload a screenshot of the paywall for review (capture on a real device).
- The removed `com.shrunk.pro.lifetime` non-consumable has no purchases; delete it in ASC if it was ever created, or leave it marked "Removed from Sale". The app no longer references it.

---
```

- [ ] **Step 2: Replace the reviewer note in §7**

The current note names the lifetime IAP and would be wrong in front of a reviewer. Replace the fenced block under "## 7. Reviewer Note" with:

```
Shrunk has no account or login — open the app and start scanning immediately. Shrunk Pro is an auto-renewable subscription in the "Shrunk Pro" group: com.shrunk.pro.yearly ($14.99/year, with a 7-day free trial) and com.shrunk.pro.monthly ($2.99/month). Either one unlocks watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and the savings dashboard; scanning, verdicts, size history and three alternatives are free forever. Use a StoreKit sandbox account to test. Product size history comes from the public USDA FoodData Central dataset and from shoppers' own label photos; live prices come from Kroger's official Products API and are shown with "Prices from Kroger" attribution.
```

- [ ] **Step 3: Update the pre-submission checklist**

Replace the IAP line in the checklist with these four, and add the privacy flag at the end:

```markdown
- [ ] Subscription group `Shrunk Pro` created
- [ ] `com.shrunk.pro.yearly` ($14.99/yr, level 1) and `com.shrunk.pro.monthly` ($2.99/mo, level 2) created and submitted with the build
- [ ] 7-day Free Trial introductory offer added to the yearly product only
- [ ] App Store Server Notifications set to Version 2, both URLs pointing at `https://<worker>/v1/appstore/notifications`, and ASC's Test Notification returns 200
```

```markdown
- [ ] §4 App Privacy re-answered before submission — the app now talks to a first-party Cloudflare Worker and stores a device UUID, an APNs token, a store id, and category preferences server-side. The "we operate no backend" wording in §4 is stale as of Phase 5 and must be rewritten in week 6.
```

- [ ] **Step 4: Mark the old monetization note superseded**

Insert as the very first line of `tasks/shrunk_v2_monetization.md`, above the `#` heading:

```markdown
> **Superseded on 2026-08-26** by `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`. Pricing is now a $2.99/mo + $14.99/yr subscription with a 7-day trial, onboarding is four screens, and the quiz-driven "$/yr exposure" forecast is deleted. Kept for history only — do not implement from this file.
```

- [ ] **Step 5: Verify the docs and the code agree**

```bash
grep -rn "com.shrunk.pro" docs/ASC_SETUP.md Shrunk/Resources/Shrunk.storekit Shrunk/Services/StoreKitService.swift
grep -rn "lifetime" docs Shrunk ShrunkTests backend/src || echo "no lifetime references outside history"
```
Expected: the same two product IDs in all three files, and the only `lifetime` hit is the one deliberate assertion in `ProEntitlementTests` plus the historical note in `tasks/`.

- [ ] **Step 6: Commit**

```bash
git add docs/ASC_SETUP.md tasks/shrunk_v2_monetization.md
git commit -m "docs: ASC subscription group, trial offer and server notifications URL"
```

---

## Phase 5 exit criteria

- [ ] `cd backend && npx vitest run && npx tsc --noEmit` — all suites green, typecheck clean.
- [ ] `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'` — all suites green, including `StoreKitConfigurationTests` (trial → active → expired).
- [ ] `grep -rn "SavingsForecast\|com.shrunk.pro.lifetime\|monthlySpend\|householdSize" Shrunk` returns nothing.
- [ ] **Spec §10's "JWS verification with an Apple sandbox transaction":** a sandbox purchase on a real device writes a future `pro_until` — `npx wrangler d1 execute shrunk --remote --command "SELECT id, pro_until, app_account_token FROM devices WHERE pro_until IS NOT NULL;"`. This is the only check that exercises a genuinely Apple-signed JWS against the pinned real root, so it cannot be skipped.
- [ ] ASC's **Test Notification** for the app returns 200 and the Worker log shows the notification type.
- [ ] Onboarding is four screens; the paywall preselects yearly with "Save 58%" and offers the 7-day trial.
- [ ] The savings dashboard shows either real per-product numbers or the "Nothing to add up yet" empty state — never an invented total.
- [ ] A free user's result view shows two history points and the "See full history with Pro" row; a Pro user's shows every observation.
