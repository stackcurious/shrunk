# Shrunk v2 — Phase 4: Push, Devices and Crons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the two Pro promises that need a server — watchlist alerts (size drop, ≥5% per-unit price hike, verified case for a watched product or brand) and the Monday "what shrank this week" digest — as real pushes to real devices.

**Architecture:** The Worker gains `devices` and `watches` tables, a `POST /v1/devices` upsert that the app calls after every watchlist edit, and a `PushSender` seam with two implementations (APNs token auth by default, FCM HTTP v1 behind the same interface). Three cron triggers hang off `src/worker.ts`: a five-minute drain that turns `alert_jobs` rows into pushes for Pro devices only, the six-hourly Kroger sweep (extended so its `(gtin, location_id)` set comes from `watches × devices`), and a Monday-01:00 digest that counts the week's accepted shrink observations and verified cases per category. `GET /v1/feed` merges the curated `trending.json` with the last 30 days of accepted crowd/Kroger shrinks, and the app's Browse feed switches to it. On iOS an `AppDelegate` registers for remote notifications, stores the token, syncs the device, writes incoming pushes into the Alerts feed as new `ShrinkAlert` kinds, and routes a tapped push to the product.

**Tech Stack:** TypeScript, Hono 4, Wrangler 4, Cloudflare D1 + KV + Cron Triggers, WebCrypto (ECDSA P-256 for APNs, RSASSA-PKCS1-v1_5 for FCM), Vitest 4 with `@cloudflare/vitest-pool-workers` · Swift 5.9 / SwiftUI / SwiftData / UserNotifications / BackgroundTasks / XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§3 Pro items 1–2, §5 `devices` / `watches` / `alert_jobs`, §6.1 `POST /v1/devices` and `GET /v1/feed`, §6.2 all three crons, §6.5 Push, §7 Watchlist / Alerts feed, §8 error handling, §10 Testing, §11 week 4).

**Format template:** `docs/superpowers/plans/2026-08-26-shrunk-v2-week1-data-backbone.md` (Phase 1).

**Assumes Phases 1–3 are complete.** This plan consumes, and never redefines:

- Phase 1: `backend/` with `src/index.ts` (default-exports the Hono `app`), `src/env.ts` (`Env`), `src/db.ts` (`ProductRow`, `getProduct`, `insertProduct`, `getAcceptedObservations`, `getRecentSnapshots`), `src/gtin.ts` (`normalizeGTIN`), `src/normalize.ts` (`parsePackageWeight`, `ParsedQuantity { quantity, unitKind, raw }`, `UnitKind`), `migrations/0001_init.sql`; iOS `Shrunk/Services/ShrunkAPIClient.swift` (actor, `init(baseURL:session:)`, `fetchProduct(barcode:locationId:)`, `ProductDTO.unit(forKind:)`), `ShrinkDetector`, `ShrunkTests/ShrunkAPIClientTests.swift` (`StubURLProtocol`).
- Phase 2: `migrations/0002_submissions.sql` (`submissions`, `alert_jobs`), `Env.ADMIN_SECRET`, `Env.PHOTOS`, `src/db.ts` `insertAlertJob(db, job: NewAlertJob)` with `NewAlertJob { kind, gtin, brand, location_id, payload, created_at }`, crowd `size_drop` payloads shaped `{gtin, unit_kind, previous_quantity, quantity, percent_change, source}`; iOS `Shrunk/Services/DeviceIdentity.swift`, `ShrunkAPIClient.submitObservation(...)`.
- Phase 3: `migrations/0003_alert_jobs.sql`, `src/worker.ts` (`export default { fetch, scheduled }`, `main` in `wrangler.toml`), `src/sweep.ts` (`runKrogerSweep(env, client?)`, `SweepResult`), `src/kroger/*`, `Env` additions `KV`, `KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET`, `KROGER_PERSIST`; sweep `size_drop` payloads `{previous_size, size}` and `price_hike` payloads `{previous_per_unit, per_unit}`; iOS `ShrunkAPIClient.deviceId`, `.liveProduct(barcode:locationId:)`, `LivePrice` (`quantity: Double?`, `unitKind: String?`), `Shrunk/Services/DataProviders.swift` (`StoreDataProviding`, `TrendingFeedProviding`), `@AppStorage("storeLocationId")`.

## Global Constraints

- **Phase-5 contract, honoured verbatim** (from `docs/superpowers/plans/2026-08-26-shrunk-v2-phase5-subscription-onboarding-dashboard.md`, "Interface this phase requires from Phase 4"):
  - `POST /v1/devices` accepts JSON `{ device_id: string, apns_token?: string|null, location_id?: string|null, categories?: string[], watches?: [...], transaction_jws?: string|null }` and upserts into `devices(id, apns_token, location_id, categories, pro_until, app_account_token, transaction_jws, updated_at)` keyed on `id = device_id`. Phase 4 stores `transaction_jws` **raw without verifying it**; Phase 5 adds the verification.
  - The route module is `backend/src/routes/devices.ts` and exports a Hono sub-app named `devicesRoute`, mounted in `backend/src/index.ts`.
  - iOS: `ShrunkAPIClient.syncDevice(deviceId:transactionJWS:)` posts that body and **never throws**.
- `devices.pro_until` is nullable and **Phase 4 never writes it** — the column is set to `NULL` on insert and left untouched on every update, so Phase 5's verifier owns it. NULL is treated as "not Pro" everywhere.
- Pushes go only to devices with `pro_until IS NOT NULL AND pro_until > now`, a non-null `apns_token`, and `watches.alert_enabled = 1` (spec §6.2).
- **Max 40 pushes per drain invocation** (spec §6.2). A job with more recipients resumes from `alert_jobs.sent_count` on the next run.
- Price-hike threshold: per-unit price up **≥5%** versus the previous snapshot (spec §3). Size drop: more than **1%** smaller, the same-size band from spec §5.1.
- Digest cron runs `0 1 * * 1` (Monday 01:00 UTC): per category, count the last **7 days** of accepted shrink observations plus `verified_case` jobs; **one push per Pro device** with a non-zero count in a subscribed category (spec §6.2).
- Feed window: accepted `crowd`/`kroger` shrink observations from the last **30 days**, merged with the curated catalogue (spec §6.1).
- Barcodes are 13-digit zero-padded GTINs; every inbound barcode goes through `normalizeGTIN` (spec §2).
- APNs topic and bundle id are **`com.shrunk.app`**. APNs JWT is ES256, cached in KV for **50 minutes** (spec §6.5). Hosts: `api.push.apple.com` (production) / `api.sandbox.push.apple.com` (sandbox).
- **Push `kind` values on the wire are the iOS camelCase names** — `sizeDrop`, `priceHike`, `verifiedCase`, `digest` — so the app maps a payload straight onto `ShrinkAlert.Kind`. The D1 `alert_jobs.kind` values stay snake_case (`size_drop`, `price_hike`, `verified_case`), which is what Phases 2 and 3 already write.
- **Never log** device tokens, barcodes, push bodies, or `transaction_jws`. Counts and status codes only.
- Cloudflare **Workers Paid**. APNs/FCM credentials are set with `wrangler secret put`, never committed. `PUSH_PROVIDER` and `APNS_ENV` are plain vars so the provider and environment can change without a code change.
- Worker tests: `cd backend && npx vitest run`, typecheck `npx tsc --noEmit`. **`fetchMock` from `cloudflare:test` does not exist in this repo's toolchain** — stub outbound HTTP with `vi.stubGlobal("fetch", vi.fn(...))` plus `afterEach(() => vi.unstubAllGlobals())`. D1 and KV bindings are real in tests. Cron handlers are tested by calling the exported functions (`runAlertDrain`, `runWeeklyDigest`, `runKrogerSweep`) directly with `env`.
- iOS 17+, Swift 5.9, `project.yml` is the source of truth — run `xcodegen generate` after adding, removing or renaming any Swift file or target setting. iOS tests: `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'`.
- Commit after every task. Never commit `backend/node_modules`, `backend/.wrangler`, `.dev.vars`, or any `.p8` / service-account JSON.

### Handoff notes for Phase 5 (read before executing Phase 5)

- Phase 4 creates `ShrunkTests/TestHTTPHelpers.swift` containing `extension URLRequest { func bodyData() -> Data? }`. Phase 5's Task 5 defines the same helper inside `ShrunkTests/DeviceSyncTests.swift` — **delete that copy** there, or the target will not compile (duplicate method).
- Phase 4's iOS test classes are named `DeviceIdentityUnificationTests` and `DeviceSyncPayloadTests` precisely so Phase 5's `DeviceIdentityTests` / `SyncDeviceTests` can be added to the same target without a duplicate-symbol error.
- Phase 4 does **not** declare `DeviceSyncing`; Phase 5 Task 5 still owns it. Phase 4's `syncDevice` gives every parameter after `transactionJWS` a default, so `syncDevice(deviceId:transactionJWS:)` is callable with exactly two arguments. A Swift protocol requirement is **not** witnessed by a method with extra defaulted parameters, so when Phase 5 declares `DeviceSyncing` with the two-argument requirement it must add an explicit forwarder in the conformance:
  ```swift
  extension ShrunkAPIClient: DeviceSyncing {
      @discardableResult
      func syncDevice(deviceId: String, transactionJWS: String) async -> Bool {
          await syncDevice(deviceId: deviceId, transactionJWS: transactionJWS,
                           apnsToken: nil, locationId: nil, categories: nil, watches: nil)
      }
  }
  ```
- Phase 4 adds a `prefs TEXT` column to `devices` (per-kind notification toggles as a JSON object). Phase 5's `0005_devices_appstore.sql` creates `devices`/`watches` with `IF NOT EXISTS`, so it will find them already present and must not attempt to re-add columns.

## File Structure

```
backend/
  migrations/0004_devices_watches.sql   devices + watches (spec §5) + alert_jobs.sent_count
  wrangler.toml                         + PUSH_PROVIDER/APNS_ENV vars, three cron triggers
  vitest.config.ts                      + push test bindings
  package.json                          + sync:trending / check:trending scripts
  src/env.ts                            + PUSH_PROVIDER, APNS_*, FCM_SERVICE_ACCOUNT_JSON
  src/db.ts                             + device/watch helpers + previousAcceptedQuantity
  src/categories.ts                     NEW — canonicalCategory: one spelling per category
  src/data/trending.json                NEW — build-time copy of ../../data/trending.json
  src/push/PushSender.ts                NEW — PushSender/PushPayload/PushResult + PEM & base64url
  src/push/apns.ts                      NEW — APNsSender (ES256 JWT, KV-cached 50 min)
  src/push/fcm.ts                       NEW — FCMSender (service-account JWT -> OAuth, KV-cached)
  src/push/index.ts                     NEW — pushSender(env) picks by PUSH_PROVIDER
  src/feed.ts                           NEW — buildFeed: curated + recent accepted shrinks
  src/alerts.ts                         NEW — runAlertDrain + alertCopy (the */5 cron)
  src/digest.ts                         NEW — runWeeklyDigest (the Monday cron)
  src/sweep.ts                          MODIFIED — pairs come from watches x devices
  src/worker.ts                         MODIFIED — scheduled dispatches on event.cron
  src/routes/devices.ts                 NEW — POST /v1/devices  (devicesRoute)
  src/routes/feed.ts                    NEW — GET  /v1/feed     (feedRoute)
  src/routes/admin-verified.ts          NEW — POST /v1/admin/verified-case (adminVerifiedRoute)
  src/index.ts                          MODIFIED — mounts the three new routers
  test/devices-db.test.ts, devices.test.ts, feed.test.ts, push-apns.test.ts,
  test/push-fcm.test.ts, alerts-drain.test.ts, admin-verified.test.ts,
  test/digest.test.ts, sweep.test.ts (MODIFIED)
Shrunk/
  Shrunk.entitlements                   NEW — aps-environment: development
  Resources/Info.plist                  + remote-notification background mode
  Services/AppDelegate.swift            NEW — APNs registration + UNUserNotificationCenterDelegate
  Services/PushInbox.swift              NEW — push -> Alerts feed + tap routing state
  Services/DeviceIdentity.swift         MODIFIED — one id, shared with ShrunkAPIClient.deviceId
  Services/ShrunkAPIClient.swift        + syncDevice, DeviceWatch, deviceId reads DeviceIdentity
  Services/DataProviders.swift          + WatchlistSyncing seam
  Services/NotificationScheduler.swift  + requestPermissionAndRegister
  Services/WatchlistService.swift       refreshAll -> syncToBackend + liveSizeCheck
  Services/TrendingFeedService.swift    remote source becomes /v1/feed
  Models/ShrinkAlert.swift              + 4 kinds, message, headline, from(pushUserInfo:)
  Models/NotificationPreferences.swift  + per-kind toggles
  Models/GroceryCategory+Feed.swift     NEW — app category -> feed category name
  Features/Alerts/AlertRow.swift        + the four new kinds
  Features/Alerts/AlertsViewModel.swift + filter mapping for the new kinds
  Features/Alerts/AlertsFeedView.swift  digest rows do not open a product
  Features/Settings/NotificationPreferencesView.swift  + alert-kinds card
  Features/Watchlist/WatchlistViewModel.swift  refresh -> live-size check
  Features/Watchlist/WatchlistView.swift       refresh call site copy
  ShrunkApp.swift                       + delegate adaptor, foreground sync, unconfirmed sweep
project.yml                             + CODE_SIGN_ENTITLEMENTS
ShrunkTests/
  TestHTTPHelpers.swift                 NEW — URLRequest.bodyData()
  DeviceRegistrationTests.swift         NEW — syncDevice body, token hex
  PushAlertTests.swift                  NEW — kind copy, from(pushUserInfo:), tap routing
  NotificationPreferencesTests.swift    NEW — per-kind decode defaults + prefs payload
  WatchlistSyncTests.swift              NEW — sync triggers, live-size mismatch
  TrendingFeedServiceTests.swift        NEW — /v1/feed mapping
```

---

### Task 1: `devices` + `watches` schema, push bindings, D1 helpers

**Files:**
- Create: `backend/migrations/0004_devices_watches.sql`
- Modify: `backend/src/env.ts`
- Modify: `backend/src/db.ts`
- Modify: `backend/wrangler.toml`
- Modify: `backend/vitest.config.ts`
- Test: `backend/test/devices-db.test.ts`

**Interfaces:**
- Consumes: `Env` (Phases 1–3), `src/db.ts` from Phases 1–2.
- Produces: tables `devices(id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at)` and `watches(device_id, gtin, brand, alert_enabled)`, plus `alert_jobs.sent_count INTEGER NOT NULL DEFAULT 0`.
- Produces: `Env` gains `PUSH_PROVIDER: string`, `APNS_ENV: string`, `APNS_KEY_P8: string`, `APNS_KEY_ID: string`, `APNS_TEAM_ID: string`, `FCM_SERVICE_ACCOUNT_JSON: string`.
- Produces (`src/db.ts`):
  - `DeviceRow { id: string; apns_token: string | null; location_id: string | null; categories: string | null; prefs: string | null; pro_until: number | null; app_account_token: string | null; transaction_jws: string | null }`
  - `DeviceUpsert { id: string; apns_token?: string | null; location_id?: string | null; categories?: string[] | null; prefs?: Record<string, boolean> | null; app_account_token?: string | null; transaction_jws?: string | null }`
  - `WatchInput { gtin: string; brand: string | null; alert_enabled: boolean }`
  - `upsertDevice(db: D1Database, row: DeviceUpsert, now: number): Promise<void>` — inserts with `pro_until = NULL`; on conflict `COALESCE`s every supplied column and **never touches `pro_until`**.
  - `getDevice(db: D1Database, id: string): Promise<DeviceRow | null>`
  - `replaceWatches(db: D1Database, deviceId: string, watches: WatchInput[]): Promise<void>`
  - `listWatches(db: D1Database, deviceId: string): Promise<WatchInput[]>`
  - `previousAcceptedQuantity(db: D1Database, gtin: string, unitKind: string, observedAt: number, id: number): Promise<number | null>`

- [ ] **Step 1: Write the migration**

Confirm the next free number first: `ls backend/migrations` (Phase 1 wrote `0001_init.sql`, Phase 2 `0002_*`, Phase 3 `0003_*`). If your listing shows a different next number, use it and rename every reference below.

`backend/migrations/0004_devices_watches.sql`:

```sql
-- Phase 4 (spec §5). Only new objects here — no earlier table is recreated.
CREATE TABLE devices (
  id                TEXT PRIMARY KEY,   -- app-generated UUID
  apns_token        TEXT,               -- APNs hex token (or FCM registration token)
  location_id       TEXT,               -- the user's Kroger store
  categories        TEXT,               -- JSON array of canonical category names
  prefs             TEXT,               -- JSON object of per-kind toggles, e.g. {"digest":false}
  pro_until         INTEGER,            -- unix seconds; NULL = not Pro. Phase 5 writes this.
  app_account_token TEXT,               -- UUID passed to the StoreKit purchase
  transaction_jws   TEXT,               -- stored raw in Phase 4; Phase 5 verifies it
  updated_at        INTEGER NOT NULL
);
CREATE INDEX devices_pro ON devices(pro_until);
CREATE INDEX devices_account ON devices(app_account_token);

CREATE TABLE watches (
  device_id     TEXT NOT NULL,
  gtin          TEXT NOT NULL,
  brand         TEXT,
  alert_enabled INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (device_id, gtin)
);
CREATE INDEX watches_gtin ON watches(gtin, alert_enabled);
CREATE INDEX watches_brand ON watches(brand, alert_enabled);

-- Resume cursor for the every-5-minute drain: how many recipient rows of this
-- job have already been processed (spec §6.2 caps a run at 40 pushes).
ALTER TABLE alert_jobs ADD COLUMN sent_count INTEGER NOT NULL DEFAULT 0;
```

- [ ] **Step 2: Add the bindings**

`backend/src/env.ts` — keep everything Phases 1–3 put here and add the six push lines:

```ts
export interface Env {
  DB: D1Database;
  KV: KVNamespace;
  PHOTOS: R2Bucket;
  FDC_API_KEY: string;
  ADMIN_SECRET: string;
  KROGER_CLIENT_ID: string;
  KROGER_CLIENT_SECRET: string;
  KROGER_PERSIST: "on" | "off";
  /** "apns" (default) | "fcm" — spec §6.5. */
  PUSH_PROVIDER: string;
  /** "sandbox" (default) | "production". */
  APNS_ENV: string;
  /** Contents of the AuthKey_XXXXXXXXXX.p8 file, PEM including the BEGIN/END lines. */
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  /** Firebase service-account JSON, used only when PUSH_PROVIDER = "fcm". */
  FCM_SERVICE_ACCOUNT_JSON: string;
  ENV: string;
}
```

`backend/wrangler.toml` — add to the existing `[vars]` block (leave `ENV` and `KROGER_PERSIST` alone):

```toml
PUSH_PROVIDER = "apns"
APNS_ENV = "sandbox"
```

`backend/vitest.config.ts` — extend the existing `miniflare.bindings` object inside `cloudflareTest({...})` with the push bindings (keep every binding Phases 1–3 added):

```ts
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            FDC_API_KEY: "test-key",
            ADMIN_SECRET: "test-admin-secret",
            KROGER_CLIENT_ID: "test-client",
            KROGER_CLIENT_SECRET: "test-secret",
            KROGER_PERSIST: "off",
            PUSH_PROVIDER: "apns",
            APNS_ENV: "sandbox",
            APNS_KEY_P8: "",
            APNS_KEY_ID: "TESTKEYID1",
            APNS_TEAM_ID: "TESTTEAM01",
            FCM_SERVICE_ACCOUNT_JSON: "",
          },
        },
```

- [ ] **Step 3: Write the failing tests**

`backend/test/devices-db.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  getDevice,
  listWatches,
  previousAcceptedQuantity,
  replaceWatches,
  upsertDevice,
} from "../src/db";

const DEVICE = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const GTIN = "0028400642255";

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM products"),
  ]);
});

describe("device helpers", () => {
  it("inserts a device with a NULL pro_until", async () => {
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "aa11", location_id: "01400943", categories: ["Snacks"] }, 1700000000);
    const row = await getDevice(env.DB, DEVICE);
    expect(row).toMatchObject({ id: DEVICE, apns_token: "aa11", location_id: "01400943", pro_until: null });
    expect(JSON.parse(row!.categories!)).toEqual(["Snacks"]);
    expect(row!.prefs).toBeNull();
  });

  it("keeps columns the second upsert omits, and never touches pro_until", async () => {
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "aa11", location_id: "01400943", categories: ["Snacks"], transaction_jws: "a.b.c" }, 1700000000);
    await env.DB.prepare("UPDATE devices SET pro_until = 1800000000 WHERE id = ?").bind(DEVICE).run();

    await upsertDevice(env.DB, { id: DEVICE, apns_token: "bb22" }, 1700000900);

    const row = await getDevice(env.DB, DEVICE);
    expect(row).toMatchObject({
      apns_token: "bb22",            // updated
      location_id: "01400943",       // preserved
      transaction_jws: "a.b.c",      // preserved
      pro_until: 1800000000,         // Phase 4 never writes this
    });
    expect(JSON.parse(row!.categories!)).toEqual(["Snacks"]);
    const updated = await env.DB.prepare("SELECT updated_at FROM devices WHERE id = ?").bind(DEVICE).first<{ updated_at: number }>();
    expect(updated!.updated_at).toBe(1700000900);
  });

  it("stores prefs as a JSON object", async () => {
    await upsertDevice(env.DB, { id: DEVICE, prefs: { sizeDrop: true, digest: false } }, 1700000000);
    expect(JSON.parse((await getDevice(env.DB, DEVICE))!.prefs!)).toEqual({ sizeDrop: true, digest: false });
  });

  it("returns null for an unknown device", async () => {
    expect(await getDevice(env.DB, "nope")).toBeNull();
  });

  it("replaces the whole watch set", async () => {
    await upsertDevice(env.DB, { id: DEVICE }, 1700000000);
    await replaceWatches(env.DB, DEVICE, [
      { gtin: GTIN, brand: "Gatorade", alert_enabled: true },
      { gtin: "0028400642262", brand: "Doritos", alert_enabled: false },
    ]);
    expect((await listWatches(env.DB, DEVICE)).map((w) => w.gtin)).toEqual([GTIN, "0028400642262"]);

    await replaceWatches(env.DB, DEVICE, [{ gtin: "0028400642262", brand: "Doritos", alert_enabled: true }]);
    const after = await listWatches(env.DB, DEVICE);
    expect(after).toEqual([{ gtin: "0028400642262", brand: "Doritos", alert_enabled: true }]);
  });

  it("clears the watch set when handed an empty array", async () => {
    await upsertDevice(env.DB, { id: DEVICE }, 1700000000);
    await replaceWatches(env.DB, DEVICE, [{ gtin: GTIN, brand: "Gatorade", alert_enabled: true }]);
    await replaceWatches(env.DB, DEVICE, []);
    expect(await listWatches(env.DB, DEVICE)).toEqual([]);
  });

  it("finds the newest accepted same-kind observation before a given one", async () => {
    await env.DB.prepare(
      "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'Gatorade', 'Beverages', NULL, 'volume', 1, 1)"
    ).bind(GTIN).run();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1625097600, 'kroger', '01400943', 0.8, 'accepted', 2)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 400, 'volume', 'bogus', 1650000000, 'crowd', 'sub-1', 0.5, 'pending', 3)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 340.194, 'mass', '12 oz', 1650000000, 'fdc', '2', 0.9, 'accepted', 4)").bind(GTIN),
    ]);
    const latest = await env.DB.prepare("SELECT id FROM observations WHERE observed_at = 1625097600").first<{ id: number }>();

    expect(await previousAcceptedQuantity(env.DB, GTIN, "volume", 1625097600, latest!.id)).toBe(946.353);
    expect(await previousAcceptedQuantity(env.DB, GTIN, "volume", 1517443200, 1)).toBeNull();
    expect(await previousAcceptedQuantity(env.DB, GTIN, "count", 1700000000, 999)).toBeNull();
  });
});
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/devices-db.test.ts`
Expected: FAIL — `does not provide an export named 'upsertDevice'` (and siblings). If it instead fails with `no such table: devices`, the migration filename is wrong.

- [ ] **Step 5: Implement the helpers**

Append to `backend/src/db.ts`:

```ts
// ---------------------------------------------------------------------------
// Phase 4 — devices, watches (spec §5)
// ---------------------------------------------------------------------------

export interface DeviceRow {
  id: string;
  apns_token: string | null;
  location_id: string | null;
  categories: string | null;
  prefs: string | null;
  pro_until: number | null;
  app_account_token: string | null;
  transaction_jws: string | null;
}

/** Every field except `id` is optional: an omitted field keeps its stored value. */
export interface DeviceUpsert {
  id: string;
  apns_token?: string | null;
  location_id?: string | null;
  categories?: string[] | null;
  prefs?: Record<string, boolean> | null;
  app_account_token?: string | null;
  transaction_jws?: string | null;
}

export interface WatchInput {
  gtin: string;
  brand: string | null;
  alert_enabled: boolean;
}

/**
 * Upserts a device row. `pro_until` is written NULL on insert and is *never*
 * in the UPDATE set — Phase 5's JWS verifier owns that column, and a device
 * sync must never downgrade a subscriber (spec §8).
 */
export async function upsertDevice(db: D1Database, row: DeviceUpsert, now: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at)
       VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         apns_token        = COALESCE(excluded.apns_token, devices.apns_token),
         location_id       = COALESCE(excluded.location_id, devices.location_id),
         categories        = COALESCE(excluded.categories, devices.categories),
         prefs             = COALESCE(excluded.prefs, devices.prefs),
         app_account_token = COALESCE(excluded.app_account_token, devices.app_account_token),
         transaction_jws   = COALESCE(excluded.transaction_jws, devices.transaction_jws),
         updated_at        = excluded.updated_at`
    )
    .bind(
      row.id,
      row.apns_token ?? null,
      row.location_id ?? null,
      row.categories ? JSON.stringify(row.categories) : null,
      row.prefs ? JSON.stringify(row.prefs) : null,
      row.app_account_token ?? null,
      row.transaction_jws ?? null,
      now
    )
    .run();
}

export async function getDevice(db: D1Database, id: string): Promise<DeviceRow | null> {
  return db
    .prepare(
      "SELECT id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws FROM devices WHERE id = ?"
    )
    .bind(id)
    .first<DeviceRow>();
}

/** The watch list is replace-only: the app owns it and posts the whole set. */
export async function replaceWatches(db: D1Database, deviceId: string, watches: WatchInput[]): Promise<void> {
  const statements: D1PreparedStatement[] = [
    db.prepare("DELETE FROM watches WHERE device_id = ?").bind(deviceId),
  ];
  for (const watch of watches) {
    statements.push(
      db
        .prepare("INSERT OR REPLACE INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, ?, ?)")
        .bind(deviceId, watch.gtin, watch.brand, watch.alert_enabled ? 1 : 0)
    );
  }
  await db.batch(statements);
}

export async function listWatches(db: D1Database, deviceId: string): Promise<WatchInput[]> {
  const { results } = await db
    .prepare("SELECT gtin, brand, alert_enabled FROM watches WHERE device_id = ? ORDER BY gtin")
    .bind(deviceId)
    .all<{ gtin: string; brand: string | null; alert_enabled: number }>();
  return results.map((r) => ({ gtin: r.gtin, brand: r.brand, alert_enabled: r.alert_enabled === 1 }));
}

/**
 * The newest accepted observation of the same kind strictly *before* the one
 * identified by (observedAt, id). Used by the feed and the digest to decide
 * whether an observation is a shrink (spec §5.1).
 */
export async function previousAcceptedQuantity(
  db: D1Database,
  gtin: string,
  unitKind: string,
  observedAt: number,
  id: number
): Promise<number | null> {
  const row = await db
    .prepare(
      `SELECT quantity FROM observations
       WHERE gtin = ? AND unit_kind = ? AND status = 'accepted'
         AND (observed_at < ? OR (observed_at = ? AND id < ?))
       ORDER BY observed_at DESC, id DESC LIMIT 1`
    )
    .bind(gtin, unitKind, observedAt, observedAt, id)
    .first<{ quantity: number }>();
  return row ? row.quantity : null;
}
```

`listWatches` sorts by `gtin`, so its results are deterministic regardless of insert order — that is what the assertions above rely on.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/devices-db.test.ts && npx tsc --noEmit`
Expected: `7 passed`; typecheck clean.

- [ ] **Step 7: Run the whole suite**

Run: `cd backend && npx vitest run`
Expected: every Phase 1–3 suite still green (the new migration only adds objects).

- [ ] **Step 8: Commit**

```bash
git add backend/migrations/0004_devices_watches.sql backend/src/env.ts backend/src/db.ts backend/wrangler.toml backend/vitest.config.ts backend/test/devices-db.test.ts
git commit -m "feat(backend): devices and watches tables, push bindings, device D1 helpers"
```

---

### Task 2: `POST /v1/devices`

**Files:**
- Create: `backend/src/categories.ts`
- Create: `backend/src/routes/devices.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/devices.test.ts`

**Interfaces:**
- Consumes: `upsertDevice`, `getDevice`, `replaceWatches`, `WatchInput` (Task 1); `normalizeGTIN` (Phase 1).
- Produces: `canonicalCategory(raw: string | null | undefined): string | null` in `src/categories.ts` — one spelling per category so the app, `products.category` and the digest all agree.
- Produces: `devicesRoute` (a `Hono<{ Bindings: Env }>` sub-app) exported from `src/routes/devices.ts`, mounted with `app.route("/", devicesRoute)`; `MAX_WATCHES = 500`.
- Produces: `POST /v1/devices` → `200 {ok: true, pro: boolean}`; `400 {error: "invalid_json" | "invalid_device_id" | "too_many_watches"}`. `watches` **absent** leaves the stored watch set alone; `watches: []` clears it.

- [ ] **Step 1: Write the failing tests**

`backend/test/devices.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { canonicalCategory } from "../src/categories";

const DEVICE = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";

async function post(body: unknown) {
  return app.request(
    "/v1/devices",
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) },
    env
  );
}

async function watchRows() {
  const { results } = await env.DB
    .prepare("SELECT gtin, brand, alert_enabled FROM watches WHERE device_id = ? ORDER BY gtin")
    .bind(DEVICE)
    .all<{ gtin: string; brand: string | null; alert_enabled: number }>();
  return results;
}

beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM watches"), env.DB.prepare("DELETE FROM devices")]);
});

describe("canonicalCategory", () => {
  it("folds every spelling we emit onto one name", () => {
    expect(canonicalCategory("Drinks")).toBe("Beverages");
    expect(canonicalCategory("beverages")).toBe("Beverages");
    expect(canonicalCategory("Personal")).toBe("Personal care");
    expect(canonicalCategory("cosmetics")).toBe("Personal care");
    expect(canonicalCategory("Paper")).toBe("Paper products");
    expect(canonicalCategory("Dairies")).toBe("Dairy");
    expect(canonicalCategory("Snacks")).toBe("Snacks");
    expect(canonicalCategory("Condiments")).toBe("Condiments");
    expect(canonicalCategory("  sugar ")).toBe("Sugar");
    expect(canonicalCategory("")).toBeNull();
    expect(canonicalCategory(null)).toBeNull();
  });

  it("passes an unknown category through, trimmed", () => {
    expect(canonicalCategory(" Frozen ")).toBe("Frozen");
  });
});

describe("POST /v1/devices", () => {
  it("upserts the device and its watches, and reports pro:false", async () => {
    const res = await post({
      device_id: DEVICE,
      apns_token: "a1b2c3",
      location_id: "01400943",
      categories: ["Snacks", "Drinks"],
      prefs: { digest: false },
      watches: [
        { gtin: "028400642255", brand: "Gatorade", alert_enabled: true },
        { gtin: "0028400642262", brand: "Doritos", alert_enabled: false },
      ],
      transaction_jws: "aaa.bbb.ccc",
    });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });

    const row = await env.DB
      .prepare("SELECT apns_token, location_id, categories, prefs, pro_until, transaction_jws FROM devices WHERE id = ?")
      .bind(DEVICE)
      .first<any>();
    expect(row.apns_token).toBe("a1b2c3");
    expect(row.location_id).toBe("01400943");
    expect(JSON.parse(row.categories)).toEqual(["Snacks", "Beverages"]);
    expect(JSON.parse(row.prefs)).toEqual({ digest: false });
    expect(row.pro_until).toBeNull();
    expect(row.transaction_jws).toBe("aaa.bbb.ccc");   // stored raw, unverified

    expect(await watchRows()).toEqual([
      { gtin: "0028400642255", brand: "Gatorade", alert_enabled: 1 },   // 12-digit UPC padded
      { gtin: "0028400642262", brand: "Doritos", alert_enabled: 0 },
    ]);
  });

  it("replaces the watch set on the next sync", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255", brand: "Gatorade" }] });
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642262", brand: "Doritos" }] });
    expect((await watchRows()).map((w) => w.gtin)).toEqual(["0028400642262"]);
  });

  it("leaves the watch set alone when the key is absent, and clears it on []", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255", brand: "Gatorade" }] });

    await post({ device_id: DEVICE, transaction_jws: "aaa.bbb.ccc" });   // the Phase 5 two-field call
    expect((await watchRows()).map((w) => w.gtin)).toEqual(["0028400642255"]);

    await post({ device_id: DEVICE, watches: [] });
    expect(await watchRows()).toEqual([]);
  });

  it("defaults alert_enabled to 1 and drops unparseable gtins", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255" }, { gtin: "12345" }, { gtin: null }] });
    expect(await watchRows()).toEqual([{ gtin: "0028400642255", brand: null, alert_enabled: 1 }]);
  });

  it("reports pro:true when pro_until is in the future", async () => {
    await post({ device_id: DEVICE });
    await env.DB.prepare("UPDATE devices SET pro_until = ? WHERE id = ?")
      .bind(Math.floor(Date.now() / 1000) + 86400, DEVICE)
      .run();
    const res = await post({ device_id: DEVICE, apns_token: "a1b2c3" });
    expect(await res.json()).toEqual({ ok: true, pro: true });
  });

  it("reports pro:false when pro_until has passed", async () => {
    await post({ device_id: DEVICE });
    await env.DB.prepare("UPDATE devices SET pro_until = 1 WHERE id = ?").bind(DEVICE).run();
    expect(await (await post({ device_id: DEVICE })).json()).toEqual({ ok: true, pro: false });
  });

  it("rejects a device id that is not a UUID", async () => {
    const res = await post({ device_id: "not-a-uuid" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("rejects a body that is not JSON", async () => {
    const res = await app.request("/v1/devices", { method: "POST", body: "{" }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_json" });
  });

  it("rejects more than 500 watches", async () => {
    const watches = Array.from({ length: 501 }, (_, i) => ({ gtin: `002840064${String(i).padStart(4, "0")}` }));
    const res = await post({ device_id: DEVICE, watches });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "too_many_watches" });
    expect(await watchRows()).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/devices.test.ts`
Expected: FAIL — `Cannot find module '../src/categories'`, then 404s from `/v1/devices`.

- [ ] **Step 3: Implement `canonicalCategory`**

`backend/src/categories.ts`:

```ts
/**
 * One spelling per category. The app's `GroceryCategory` titles, the curated
 * catalogue and `products.category` all use slightly different words for the
 * same shelf; the digest and the feed compare *canonical* names only.
 */
const ALIASES: Record<string, string> = {
  snack: "Snacks",
  snacks: "Snacks",
  drink: "Beverages",
  drinks: "Beverages",
  beverage: "Beverages",
  beverages: "Beverages",
  dairy: "Dairy",
  dairies: "Dairy",
  cleaning: "Cleaning",
  "cleaning products": "Cleaning",
  personal: "Personal care",
  "personal care": "Personal care",
  cosmetics: "Personal care",
  paper: "Paper products",
  "paper products": "Paper products",
  condiment: "Condiments",
  condiments: "Condiments",
  sugar: "Sugar",
};

export function canonicalCategory(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  return ALIASES[trimmed.toLowerCase()] ?? trimmed;
}
```

- [ ] **Step 4: Implement the route**

`backend/src/routes/devices.ts`:

```ts
import { Hono } from "hono";
import { getDevice, replaceWatches, upsertDevice, type WatchInput } from "../db";
import type { Env } from "../env";
import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";

/** Spec §3 says "unlimited items"; 500 is the abuse ceiling, not a product limit. */
export const MAX_WATCHES = 500;
const MAX_CATEGORIES = 32;
const MAX_TOKEN_LENGTH = 400;
const PREF_KEYS = ["sizeDrop", "priceHike", "verifiedCase", "digest"] as const;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export const devicesRoute = new Hono<{ Bindings: Env }>();

devicesRoute.post("/v1/devices", async (c) => {
  let body: Record<string, unknown>;
  try {
    body = (await c.req.json()) as Record<string, unknown>;
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  const id = typeof body.device_id === "string" ? body.device_id.trim() : "";
  if (!UUID_RE.test(id)) return c.json({ error: "invalid_device_id" }, 400);

  const rawWatches = body.watches;
  if (Array.isArray(rawWatches) && rawWatches.length > MAX_WATCHES) {
    return c.json({ error: "too_many_watches" }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  await upsertDevice(
    c.env.DB,
    {
      id,
      apns_token: text(body.apns_token, MAX_TOKEN_LENGTH),
      location_id: text(body.location_id, 32),
      categories: categories(body.categories),
      prefs: prefs(body.prefs),
      app_account_token: text(body.app_account_token, 64),
      transaction_jws: text(body.transaction_jws, 8192),
    },
    now
  );

  if (Array.isArray(rawWatches)) {
    await replaceWatches(c.env.DB, id, watches(rawWatches));
  }

  const device = await getDevice(c.env.DB, id);
  const pro = device?.pro_until != null && device.pro_until > now;
  return c.json({ ok: true, pro });
});

function text(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > max) return null;
  return trimmed;
}

function categories(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null;
  const out: string[] = [];
  for (const entry of value.slice(0, MAX_CATEGORIES)) {
    const name = canonicalCategory(text(entry, 64));
    if (name && !out.includes(name)) out.push(name);
  }
  return out;
}

function prefs(value: unknown): Record<string, boolean> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = value as Record<string, unknown>;
  const out: Record<string, boolean> = {};
  for (const key of PREF_KEYS) {
    if (typeof source[key] === "boolean") out[key] = source[key] as boolean;
  }
  return Object.keys(out).length > 0 ? out : null;
}

function watches(value: unknown[]): WatchInput[] {
  const out: WatchInput[] = [];
  const seen = new Set<string>();
  for (const entry of value) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    const gtin = normalizeGTIN(typeof row.gtin === "string" ? row.gtin : null);
    if (!gtin || seen.has(gtin)) continue;
    seen.add(gtin);
    out.push({
      gtin,
      brand: text(row.brand, 120),
      alert_enabled: row.alert_enabled !== false,
    });
  }
  return out;
}
```

- [ ] **Step 5: Mount the route**

In `backend/src/index.ts`, add the import and the mount next to the routers Phases 1–3 already mount:

```ts
import { devicesRoute } from "./routes/devices";
```

```ts
app.route("/", devicesRoute);
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/devices.test.ts && npx tsc --noEmit`
Expected: `11 passed`; typecheck clean.

- [ ] **Step 7: Commit**

```bash
git add backend/src/categories.ts backend/src/routes/devices.ts backend/src/index.ts backend/test/devices.test.ts
git commit -m "feat(backend): POST /v1/devices upserts the device and replaces its watches"
```

---

### Task 3: `GET /v1/feed` — curated catalogue merged with recent accepted shrinks

**Files:**
- Create: `backend/src/data/trending.json` (copy of `data/trending.json`)
- Create: `backend/src/feed.ts`
- Create: `backend/src/routes/feed.ts`
- Modify: `backend/package.json`
- Modify: `backend/src/index.ts`
- Test: `backend/test/feed.test.ts`

**Interfaces:**
- Consumes: `parsePackageWeight` (Phase 1), `normalizeGTIN` (Phase 1), `previousAcceptedQuantity` (Task 1), `canonicalCategory` (Task 2).
- Produces: `FeedItem { gtin: string; name: string; brand: string; category: string; previous_quantity: number; current_quantity: number; unit_kind: string; shrink_percent: number; observed_at: number; source: string }` and `FeedResponse { updated: number; items: FeedItem[] }` in `src/feed.ts`.
- Produces: `curatedItems(): FeedItem[]` and `buildFeed(env: Env, category: string | null, now: number): Promise<FeedResponse>`; `FEED_WINDOW_SECONDS = 30 * 24 * 60 * 60`.
- Produces: `feedRoute` exported from `src/routes/feed.ts`, serving `GET /v1/feed?category=`.
- Produces: npm scripts `sync:trending` (copies `data/trending.json` into the Worker) and `check:trending` (fails when the copy has drifted).
- `shrink_percent` is negative for a shrink and rounded to one decimal. `observed_at` and `updated` are unix seconds.

- [ ] **Step 1: Copy the catalogue into the Worker and wire the drift check**

```bash
cd /Users/drao/Projects/shrunk/backend
mkdir -p src/data
cp ../data/trending.json src/data/trending.json
npm pkg set scripts.sync:trending="cp ../data/trending.json src/data/trending.json"
npm pkg set scripts.check:trending="diff -u ../data/trending.json src/data/trending.json"
npm run check:trending && echo "trending copy is in sync"
```

`backend/tsconfig.json` already sets `"resolveJsonModule": true`, so `import trending from "./data/trending.json"` type-checks and bundles.

- [ ] **Step 2: Write the failing tests**

`backend/test/feed.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { curatedItems } from "../src/feed";

const GATORADE = "0052000133417";   // curated: 32 fl oz -> 28 fl oz
const SNACK = "0028400642262";

const NOW = Math.floor(Date.now() / 1000);
const DAY = 86400;

async function feed(query = "") {
  const res = await app.request(`/v1/feed${query}`, {}, env);
  expect(res.status).toBe(200);
  return (await res.json()) as { updated: number; items: any[] };
}

async function seedShrink(gtin: string, category: string, previous: number, current: number, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Doritos Nacho Cheese', 'Doritos', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', '12 oz', ?, 'fdc', '1', 0.9, 'accepted', ?)"
  ).bind(gtin, previous, createdAt - 400 * DAY, createdAt - 400 * DAY).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', '10.5 oz', ?, 'kroger', '01400943', 0.8, 'accepted', ?)"
  ).bind(gtin, current, createdAt, createdAt).run();
}

beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM observations"), env.DB.prepare("DELETE FROM products")]);
});

describe("curatedItems", () => {
  it("turns the bundled catalogue into shrink items", () => {
    const items = curatedItems();
    expect(items.length).toBeGreaterThanOrEqual(30);

    const gatorade = items.find((i) => i.gtin === GATORADE)!;
    expect(gatorade).toMatchObject({
      gtin: GATORADE,
      brand: "Gatorade",
      category: "Beverages",
      unit_kind: "volume",
      source: "curated",
      shrink_percent: -12.5,
      observed_at: 1630454400,   // 2021-09-01T00:00:00Z
    });
    expect(gatorade.previous_quantity).toBeCloseTo(946.353, 2);
    expect(gatorade.current_quantity).toBeCloseTo(828.058, 2);
  });

  it("never emits a growth or an unparseable entry", () => {
    for (const item of curatedItems()) {
      expect(item.shrink_percent).toBeLessThan(0);
      expect(item.previous_quantity).toBeGreaterThan(0);
      expect(["mass", "volume", "count"]).toContain(item.unit_kind);
    }
  });
});

describe("GET /v1/feed", () => {
  it("serves the curated catalogue when the database is empty", async () => {
    const body = await feed();
    expect(body.items.some((i) => i.gtin === GATORADE)).toBe(true);
    expect(body.updated).toBeGreaterThan(0);
    expect(body.items[0].observed_at).toBeGreaterThanOrEqual(body.items[body.items.length - 1].observed_at);
  });

  it("merges an accepted Kroger shrink from the last 30 days", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 300, NOW - 2 * DAY);
    const item = (await feed()).items.find((i) => i.gtin === SNACK)!;
    expect(item).toMatchObject({
      name: "Doritos Nacho Cheese",
      brand: "Doritos",
      category: "Snacks",
      unit_kind: "mass",
      source: "kroger",
      shrink_percent: -11.8,
    });
    expect(item.previous_quantity).toBeCloseTo(340.194, 2);
    expect(item.current_quantity).toBe(300);
  });

  it("ignores observations older than the 30-day window", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 300, NOW - 45 * DAY);
    expect((await feed()).items.some((i) => i.gtin === SNACK)).toBe(false);
  });

  it("ignores an accepted observation that did not shrink", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 341, NOW - DAY);
    expect((await feed()).items.some((i) => i.gtin === SNACK)).toBe(false);
  });

  it("lets a database observation win over the curated row for the same gtin", async () => {
    await seedShrink(GATORADE, "Beverages", 828.058, 700, NOW - DAY);
    const item = (await feed()).items.find((i) => i.gtin === GATORADE)!;
    expect(item.source).toBe("kroger");
    expect(item.current_quantity).toBe(700);
    expect((await feed()).items.filter((i) => i.gtin === GATORADE)).toHaveLength(1);
  });

  it("filters by category, canonicalising the query", async () => {
    const drinks = await feed("?category=Drinks");
    expect(drinks.items.length).toBeGreaterThan(0);
    expect(drinks.items.every((i) => i.category === "Beverages")).toBe(true);
    expect(drinks.items.some((i) => i.gtin === GATORADE)).toBe(true);

    const snacks = await feed("?category=Snacks");
    expect(snacks.items.some((i) => i.gtin === GATORADE)).toBe(false);
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/feed.test.ts`
Expected: FAIL — `Cannot find module '../src/feed'`.

- [ ] **Step 4: Implement the feed**

`backend/src/feed.ts`:

```ts
import { canonicalCategory } from "./categories";
import { previousAcceptedQuantity } from "./db";
import type { Env } from "./env";
import { normalizeGTIN } from "./gtin";
import { parsePackageWeight } from "./normalize";
import catalogue from "./data/trending.json";

/** Spec §6.1 — the feed shows the last 30 days of accepted observations. */
export const FEED_WINDOW_SECONDS = 30 * 24 * 60 * 60;
/** Spec §5.1 — inside 1% is the same size, so it is not a shrink. */
const SHRINK_TOLERANCE = 0.01;
const OBSERVATION_LIMIT = 200;

export interface FeedItem {
  gtin: string;
  name: string;
  brand: string;
  category: string;
  previous_quantity: number;
  current_quantity: number;
  unit_kind: string;
  shrink_percent: number;
  observed_at: number;
  source: string;
}

export interface FeedResponse {
  updated: number;
  items: FeedItem[];
}

interface CuratedEntry {
  barcode: string;
  name: string;
  brand: string;
  category: string;
  history: { date: string; quantity: number; unit: string }[];
}

const CURATED = (catalogue as unknown as { trending: CuratedEntry[] }).trending;

const round1 = (n: number) => Math.round(n * 10) / 10;

/** The verified cases shipped in `data/trending.json`, as feed items. */
export function curatedItems(): FeedItem[] {
  const items: FeedItem[] = [];
  for (const entry of CURATED) {
    const gtin = normalizeGTIN(entry.barcode);
    const history = entry.history ?? [];
    if (!gtin || history.length < 2) continue;

    const before = parsePackageWeight(`${history[history.length - 2].quantity} ${history[history.length - 2].unit}`);
    const after = parsePackageWeight(`${history[history.length - 1].quantity} ${history[history.length - 1].unit}`);
    if (!before || !after || before.unitKind !== after.unitKind || before.quantity <= 0) continue;
    if ((before.quantity - after.quantity) / before.quantity <= SHRINK_TOLERANCE) continue;

    const observedAt = Date.parse(`${history[history.length - 1].date}T00:00:00Z`);
    if (Number.isNaN(observedAt)) continue;

    items.push({
      gtin,
      name: entry.name,
      brand: entry.brand,
      category: canonicalCategory(entry.category) ?? "",
      previous_quantity: before.quantity,
      current_quantity: after.quantity,
      unit_kind: after.unitKind,
      shrink_percent: round1(((after.quantity - before.quantity) / before.quantity) * 100),
      observed_at: Math.floor(observedAt / 1000),
      source: "curated",
    });
  }
  return items;
}

interface ObservationRow {
  id: number;
  gtin: string;
  quantity: number;
  unit_kind: string;
  observed_at: number;
  source: string;
  name: string;
  brand: string;
  category: string;
}

/**
 * Spec §6.1 — curated catalogue plus every accepted crowd/Kroger observation
 * from the last 30 days that is actually smaller than the one before it.
 * Database rows win over curated rows for the same product: they are fresher.
 */
export async function buildFeed(env: Env, category: string | null, now: number): Promise<FeedResponse> {
  const { results } = await env.DB
    .prepare(
      `SELECT o.id AS id, o.gtin AS gtin, o.quantity AS quantity, o.unit_kind AS unit_kind,
              o.observed_at AS observed_at, o.source AS source,
              p.name AS name, p.brand AS brand, p.category AS category
       FROM observations o JOIN products p ON p.gtin = o.gtin
       WHERE o.status = 'accepted' AND o.source IN ('crowd','kroger') AND o.created_at >= ?
       ORDER BY o.observed_at DESC, o.id DESC
       LIMIT ?`
    )
    .bind(now - FEED_WINDOW_SECONDS, OBSERVATION_LIMIT)
    .all<ObservationRow>();

  const byGtin = new Map<string, FeedItem>();

  for (const row of results) {
    if (byGtin.has(row.gtin)) continue;   // newest row per product wins
    const previous = await previousAcceptedQuantity(env.DB, row.gtin, row.unit_kind, row.observed_at, row.id);
    if (previous === null || previous <= 0) continue;
    if ((previous - row.quantity) / previous <= SHRINK_TOLERANCE) continue;

    byGtin.set(row.gtin, {
      gtin: row.gtin,
      name: row.name,
      brand: row.brand,
      category: canonicalCategory(row.category) ?? "",
      previous_quantity: previous,
      current_quantity: row.quantity,
      unit_kind: row.unit_kind,
      shrink_percent: round1(((row.quantity - previous) / previous) * 100),
      observed_at: row.observed_at,
      source: row.source,
    });
  }

  for (const item of curatedItems()) {
    if (!byGtin.has(item.gtin)) byGtin.set(item.gtin, item);
  }

  const wanted = canonicalCategory(category);
  const items = [...byGtin.values()]
    .filter((item) => !wanted || item.category === wanted)
    .sort((a, b) => b.observed_at - a.observed_at);

  return { updated: items.reduce((max, item) => Math.max(max, item.observed_at), 0), items };
}
```

`backend/src/routes/feed.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";
import { buildFeed } from "../feed";

export const feedRoute = new Hono<{ Bindings: Env }>();

feedRoute.get("/v1/feed", async (c) => {
  const feed = await buildFeed(c.env, c.req.query("category") ?? null, Math.floor(Date.now() / 1000));
  c.header("Cache-Control", "public, max-age=300");
  return c.json(feed);
});
```

- [ ] **Step 5: Mount the route**

In `backend/src/index.ts`:

```ts
import { feedRoute } from "./routes/feed";
```

```ts
app.route("/", feedRoute);
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/feed.test.ts && npx tsc --noEmit`
Expected: `8 passed`; typecheck clean. If the JSON import fails to resolve, confirm `"resolveJsonModule": true` is present in `backend/tsconfig.json`.

- [ ] **Step 7: Commit**

```bash
git add backend/src/data/trending.json backend/src/feed.ts backend/src/routes/feed.ts backend/src/index.ts backend/package.json backend/test/feed.test.ts
git commit -m "feat(backend): GET /v1/feed merges the curated catalogue with recent accepted shrinks"
```

---

### Task 4: `PushSender` interface and the APNs sender

**Files:**
- Create: `backend/src/push/PushSender.ts`
- Create: `backend/src/push/apns.ts`
- Test: `backend/test/push-apns.test.ts`

**Interfaces:**
- Produces (`src/push/PushSender.ts`):
  - `PushPayload { title: string; body: string; gtin?: string; kind: string; collapseId?: string }`
  - `PushResult { ok: boolean; status: number; invalidToken: boolean }`
  - `PushSender { send(token: string, payload: PushPayload): Promise<PushResult> }`
  - `APNS_TOPIC = "com.shrunk.app"`, `pemToDer(pem: string): ArrayBuffer`, `base64url(bytes: Uint8Array): string`, `base64urlText(text: string): string`
- Produces (`src/push/apns.ts`): `class APNsSender implements PushSender { constructor(env: Env); host(): string; jwt(now?: number): Promise<string>; send(token, payload): Promise<PushResult> }` and `mintAPNsJWT(env: Env, now: number): Promise<string>`.
- The JWT is cached in KV under `apns:jwt` for 3000 seconds (50 minutes, spec §6.5). `invalidToken` is true on HTTP 410 or a 400 whose body names `BadDeviceToken`.
- The payload is `{aps: {alert: {title, body}, sound: "default", "content-available": 1}, kind, gtin?}`. `content-available` is what lets the app be woken in the background to write the row into the Alerts feed (Task 14); `gtin` is omitted entirely when absent.

- [ ] **Step 1: Write the failing tests**

`backend/test/push-apns.test.ts`:

```ts
import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { APNsSender, mintAPNsJWT } from "../src/push/apns";
import type { Env } from "../src/env";

const TOKEN = "740f4707bebcf74f9b7c25d48e3358945f6aa01da5ddb387462c7eaf61bb78ad";

/** A throwaway P-256 key in the same PEM shape as Apple's AuthKey_*.p8. */
async function generateP8(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
}

function decodeJWT(jwt: string) {
  const [header, claims, signature] = jwt.split(".");
  const pad = (s: string) => s + "=".repeat((4 - (s.length % 4)) % 4);
  const json = (part: string) => JSON.parse(atob(pad(part.replace(/-/g, "+").replace(/_/g, "/"))));
  return { header: json(header), claims: json(claims), signature };
}

interface Call { url: string; init: RequestInit }

function stubFetch(replies: Array<{ status: number; body?: string }>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: unknown, init: RequestInit) => {
      calls.push({ url: String(input), init });
      const reply = replies.shift() ?? { status: 200 };
      return new Response(reply.body ?? "", { status: reply.status });
    })
  );
  return calls;
}

let p8: string;
let apnsEnv: Env;

beforeEach(async () => {
  p8 = await generateP8();
  apnsEnv = { ...env, APNS_KEY_P8: p8, APNS_KEY_ID: "ABC1234567", APNS_TEAM_ID: "TEAM123456", APNS_ENV: "sandbox" } as Env;
  await env.KV.delete("apns:jwt");
});

afterEach(() => vi.unstubAllGlobals());

describe("mintAPNsJWT", () => {
  it("signs an ES256 JWT with the key id and team id", async () => {
    const jwt = await mintAPNsJWT(apnsEnv, 1700000000);
    const { header, claims, signature } = decodeJWT(jwt);
    expect(header).toEqual({ alg: "ES256", kid: "ABC1234567" });
    expect(claims).toEqual({ iss: "TEAM123456", iat: 1700000000 });
    expect(signature).not.toContain("=");
    expect(signature).not.toContain("+");
    // ES256 signatures are 64 raw bytes -> 86 base64url characters.
    expect(signature.length).toBe(86);
  });
});

describe("APNsSender", () => {
  it("posts to the sandbox host with the required headers and payload", async () => {
    const calls = stubFetch([{ status: 200 }]);
    const result = await new APNsSender(apnsEnv).send(TOKEN, {
      title: "Gatorade just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: "0052000133417",
      kind: "sizeDrop",
      collapseId: "size_drop:0052000133417",
    });

    expect(result).toEqual({ ok: true, status: 200, invalidToken: false });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(calls[0].init.method).toBe("POST");

    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["apns-topic"]).toBe("com.shrunk.app");
    expect(headers["apns-push-type"]).toBe("alert");
    expect(headers["apns-priority"]).toBe("10");
    expect(headers["apns-collapse-id"]).toBe("size_drop:0052000133417");
    expect(headers.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);

    expect(JSON.parse(calls[0].init.body as string)).toEqual({
      aps: {
        alert: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
        sound: "default",
        "content-available": 1,
      },
      kind: "sizeDrop",
      gtin: "0052000133417",
    });
  });

  it("uses the production host when APNS_ENV says so and omits an absent gtin", async () => {
    const calls = stubFetch([{ status: 200 }]);
    await new APNsSender({ ...apnsEnv, APNS_ENV: "production" } as Env).send(TOKEN, {
      title: "What shrank this week",
      body: "3 new shrinks in Snacks, 1 in Dairy",
      kind: "digest",
    });
    expect(calls[0].url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    const body = JSON.parse(calls[0].init.body as string);
    expect(body.gtin).toBeUndefined();
    expect((calls[0].init.headers as Record<string, string>)["apns-collapse-id"]).toBeUndefined();
  });

  it("caches the JWT in KV and reuses it on the next send", async () => {
    const calls = stubFetch([{ status: 200 }, { status: 200 }]);
    const sender = new APNsSender(apnsEnv);
    await sender.send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" });
    const cached = await env.KV.get("apns:jwt");
    expect(cached).toBeTruthy();

    await sender.send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" });
    const first = (calls[0].init.headers as Record<string, string>).authorization;
    const second = (calls[1].init.headers as Record<string, string>).authorization;
    expect(second).toBe(first);
    expect(second).toBe(`bearer ${cached}`);
  });

  it("reports an invalid token on 410", async () => {
    stubFetch([{ status: 410, body: JSON.stringify({ reason: "Unregistered" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 410, invalidToken: true,
    });
  });

  it("reports an invalid token on 400 BadDeviceToken", async () => {
    stubFetch([{ status: 400, body: JSON.stringify({ reason: "BadDeviceToken" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 400, invalidToken: true,
    });
  });

  it("does not blame the token for other failures", async () => {
    stubFetch([{ status: 500, body: JSON.stringify({ reason: "InternalServerError" }) }]);
    expect(await new APNsSender(apnsEnv).send(TOKEN, { title: "a", body: "b", kind: "sizeDrop" })).toEqual({
      ok: false, status: 500, invalidToken: false,
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/push-apns.test.ts`
Expected: FAIL — `Cannot find module '../src/push/apns'`.

- [ ] **Step 3: Implement the shared push types**

`backend/src/push/PushSender.ts`:

```ts
/** One push. `kind` is the iOS camelCase alert kind the app maps straight onto `ShrinkAlert.Kind`. */
export interface PushPayload {
  title: string;
  body: string;
  gtin?: string;
  kind: string;
  collapseId?: string;
}

export interface PushResult {
  ok: boolean;
  status: number;
  /** The device token is dead — the caller clears `devices.apns_token`. */
  invalidToken: boolean;
}

export interface PushSender {
  send(token: string, payload: PushPayload): Promise<PushResult>;
}

/** Bundle id, and therefore the APNs topic (spec §6.5). */
export const APNS_TOPIC = "com.shrunk.app";

/** PEM (PKCS#8) -> DER bytes, for `crypto.subtle.importKey`. */
export function pemToDer(pem: string): ArrayBuffer {
  const base64 = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlText(text: string): string {
  return base64url(new TextEncoder().encode(text));
}
```

- [ ] **Step 4: Implement the APNs sender**

`backend/src/push/apns.ts`:

```ts
import type { Env } from "../env";
import { APNS_TOPIC, base64url, base64urlText, pemToDer, type PushPayload, type PushResult, type PushSender } from "./PushSender";

const JWT_KV_KEY = "apns:jwt";
/** Apple rejects a token older than 60 minutes; refresh at 50 (spec §6.5). */
const JWT_TTL_SECONDS = 3000;
const MAX_COLLAPSE_ID = 64;

/** ES256 JWT: `{alg:"ES256",kid}` / `{iss:teamId,iat}` signed with the .p8 key. */
export async function mintAPNsJWT(env: Env, now: number): Promise<string> {
  const signingInput =
    `${base64urlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }))}.` +
    `${base64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APNS_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput))
  );
  return `${signingInput}.${base64url(signature)}`;
}

export class APNsSender implements PushSender {
  constructor(private readonly env: Env) {}

  host(): string {
    return this.env.APNS_ENV === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  }

  async jwt(now: number = Math.floor(Date.now() / 1000)): Promise<string> {
    const cached = await this.env.KV.get(JWT_KV_KEY);
    if (cached) return cached;
    const fresh = await mintAPNsJWT(this.env, now);
    await this.env.KV.put(JWT_KV_KEY, fresh, { expirationTtl: JWT_TTL_SECONDS });
    return fresh;
  }

  async send(token: string, payload: PushPayload): Promise<PushResult> {
    const headers: Record<string, string> = {
      authorization: `bearer ${await this.jwt()}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };
    if (payload.collapseId) headers["apns-collapse-id"] = payload.collapseId.slice(0, MAX_COLLAPSE_ID);

    const body: Record<string, unknown> = {
      // `content-available` lets iOS wake the app in the background so the row
      // reaches the Alerts feed even if the banner is never tapped (spec §7).
      aps: { alert: { title: payload.title, body: payload.body }, sound: "default", "content-available": 1 },
      kind: payload.kind,
    };
    if (payload.gtin) body.gtin = payload.gtin;

    const res = await fetch(`https://${this.host()}/3/device/${token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    if (res.ok) return { ok: true, status: res.status, invalidToken: false };

    const text = await res.text().catch(() => "");
    return {
      ok: false,
      status: res.status,
      invalidToken: res.status === 410 || text.includes("BadDeviceToken"),
    };
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/push-apns.test.ts && npx tsc --noEmit`
Expected: `7 passed`; typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add backend/src/push/PushSender.ts backend/src/push/apns.ts backend/test/push-apns.test.ts
git commit -m "feat(backend): PushSender interface and APNs token-auth sender"
```

---

### Task 5: FCM sender and the provider switch

**Files:**
- Create: `backend/src/push/fcm.ts`
- Create: `backend/src/push/index.ts`
- Test: `backend/test/push-fcm.test.ts`

**Interfaces:**
- Consumes: `PushSender`, `PushPayload`, `PushResult`, `APNS_TOPIC`, `pemToDer`, `base64url`, `base64urlText` (Task 4).
- Produces: `class FCMSender implements PushSender { constructor(env: Env); accessToken(now?: number): Promise<string>; send(token, payload): Promise<PushResult> }` — service-account RS256 JWT exchanged for an OAuth token, cached in KV under `fcm:token` for 3000 seconds; project id comes from the service-account JSON.
- Produces: `pushSender(env: Env): PushSender` in `src/push/index.ts` — `FCMSender` when `env.PUSH_PROVIDER === "fcm"`, `APNsSender` otherwise. Re-exports `PushSender`, `PushPayload`, `PushResult`.
- `invalidToken` is true on HTTP 404 or a body naming `UNREGISTERED`.

- [ ] **Step 1: Write the failing tests**

`backend/test/push-fcm.test.ts`:

```ts
import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FCMSender } from "../src/push/fcm";
import { APNsSender } from "../src/push/apns";
import { pushSender } from "../src/push";
import type { Env } from "../src/env";

const TOKEN = "fcm-registration-token";

async function serviceAccountJSON(): Promise<string> {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"]
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g)!.join("\n");
  return JSON.stringify({
    type: "service_account",
    project_id: "shrunk-app",
    client_email: "pusher@shrunk-app.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`,
    token_uri: "https://oauth2.googleapis.com/token",
  });
}

function decodeJWT(jwt: string) {
  const pad = (s: string) => s + "=".repeat((4 - (s.length % 4)) % 4);
  const json = (part: string) => JSON.parse(atob(pad(part.replace(/-/g, "+").replace(/_/g, "/"))));
  const [header, claims] = jwt.split(".");
  return { header: json(header), claims: json(claims) };
}

interface Call { url: string; init: RequestInit }

function stubFetch(replies: Array<{ status: number; body?: string }>): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: unknown, init: RequestInit) => {
      calls.push({ url: String(input), init });
      const reply = replies.shift() ?? { status: 200, body: "{}" };
      return new Response(reply.body ?? "{}", { status: reply.status });
    })
  );
  return calls;
}

const OAUTH_OK = { status: 200, body: JSON.stringify({ access_token: "ya29.test", expires_in: 3599 }) };

let fcmEnv: Env;

beforeEach(async () => {
  fcmEnv = { ...env, PUSH_PROVIDER: "fcm", FCM_SERVICE_ACCOUNT_JSON: await serviceAccountJSON() } as Env;
  await env.KV.delete("fcm:token");
});

afterEach(() => vi.unstubAllGlobals());

describe("pushSender", () => {
  it("picks the sender named by PUSH_PROVIDER, defaulting to APNs", () => {
    expect(pushSender({ ...env, PUSH_PROVIDER: "fcm" } as Env)).toBeInstanceOf(FCMSender);
    expect(pushSender({ ...env, PUSH_PROVIDER: "apns" } as Env)).toBeInstanceOf(APNsSender);
    expect(pushSender({ ...env, PUSH_PROVIDER: "" } as Env)).toBeInstanceOf(APNsSender);
  });
});

describe("FCMSender", () => {
  it("exchanges a service-account JWT for an OAuth token, then sends", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200, body: JSON.stringify({ name: "projects/shrunk-app/messages/1" }) }]);

    const result = await new FCMSender(fcmEnv).send(TOKEN, {
      title: "Gatorade just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: "0052000133417",
      kind: "sizeDrop",
      collapseId: "size_drop:0052000133417",
    });
    expect(result).toEqual({ ok: true, status: 200, invalidToken: false });

    expect(calls[0].url).toBe("https://oauth2.googleapis.com/token");
    expect((calls[0].init.headers as Record<string, string>)["content-type"]).toBe("application/x-www-form-urlencoded");
    const form = new URLSearchParams(calls[0].init.body as string);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const { header, claims } = decodeJWT(form.get("assertion")!);
    expect(header).toEqual({ alg: "RS256", typ: "JWT" });
    expect(claims.iss).toBe("pusher@shrunk-app.iam.gserviceaccount.com");
    expect(claims.aud).toBe("https://oauth2.googleapis.com/token");
    expect(claims.scope).toBe("https://www.googleapis.com/auth/firebase.messaging");
    expect(claims.exp - claims.iat).toBe(3600);

    expect(calls[1].url).toBe("https://fcm.googleapis.com/v1/projects/shrunk-app/messages:send");
    expect((calls[1].init.headers as Record<string, string>).authorization).toBe("Bearer ya29.test");
    expect(JSON.parse(calls[1].init.body as string)).toEqual({
      message: {
        token: TOKEN,
        notification: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
        data: { kind: "sizeDrop", gtin: "0052000133417" },
        apns: {
          headers: {
            "apns-topic": "com.shrunk.app",
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": "size_drop:0052000133417",
          },
          payload: {
            aps: {
              alert: { title: "Gatorade just shrank", body: "Now 28 fl oz — was 32 fl oz. Tap to see the history." },
              sound: "default",
              "content-available": 1,
            },
            kind: "sizeDrop",
            gtin: "0052000133417",
          },
        },
      },
    });
  });

  it("caches the OAuth token in KV", async () => {
    const calls = stubFetch([OAUTH_OK, { status: 200 }, { status: 200 }]);
    const sender = new FCMSender(fcmEnv);
    await sender.send(TOKEN, { title: "a", body: "b", kind: "digest" });
    expect(await env.KV.get("fcm:token")).toBe("ya29.test");

    await sender.send(TOKEN, { title: "a", body: "b", kind: "digest" });
    expect(calls).toHaveLength(3);                       // one OAuth call, two sends
    expect(calls[2].url).toContain("messages:send");
  });

  it("reports an invalid token when FCM says UNREGISTERED", async () => {
    stubFetch([OAUTH_OK, { status: 404, body: JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 404, invalidToken: true,
    });
  });

  it("does not blame the token for a server error", async () => {
    stubFetch([OAUTH_OK, { status: 503, body: JSON.stringify({ error: { status: "UNAVAILABLE" } }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 503, invalidToken: false,
    });
  });

  it("fails cleanly when the OAuth exchange fails", async () => {
    stubFetch([{ status: 401, body: JSON.stringify({ error: "invalid_grant" }) }]);
    expect(await new FCMSender(fcmEnv).send(TOKEN, { title: "a", body: "b", kind: "digest" })).toEqual({
      ok: false, status: 401, invalidToken: false,
    });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/push-fcm.test.ts`
Expected: FAIL — `Cannot find module '../src/push/fcm'`.

- [ ] **Step 3: Implement the FCM sender**

`backend/src/push/fcm.ts`:

```ts
import type { Env } from "../env";
import { APNS_TOPIC, base64url, base64urlText, pemToDer, type PushPayload, type PushResult, type PushSender } from "./PushSender";

const TOKEN_KV_KEY = "fcm:token";
const TOKEN_TTL_SECONDS = 3000;
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const MAX_COLLAPSE_ID = 64;

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri?: string;
}

/** Thrown internally when the OAuth exchange fails; turned into a PushResult. */
class OAuthError extends Error {
  constructor(readonly status: number) {
    super(`oauth ${status}`);
  }
}

export class FCMSender implements PushSender {
  constructor(private readonly env: Env) {}

  private account(): ServiceAccount {
    return JSON.parse(this.env.FCM_SERVICE_ACCOUNT_JSON) as ServiceAccount;
  }

  async accessToken(now: number = Math.floor(Date.now() / 1000)): Promise<string> {
    const cached = await this.env.KV.get(TOKEN_KV_KEY);
    if (cached) return cached;

    const account = this.account();
    const tokenUri = account.token_uri ?? DEFAULT_TOKEN_URI;
    const signingInput =
      `${base64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.` +
      `${base64urlText(JSON.stringify({ iss: account.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 }))}`;

    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToDer(account.private_key),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const signature = new Uint8Array(
      await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput))
    );

    const res = await fetch(tokenUri, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: `${signingInput}.${base64url(signature)}`,
      }).toString(),
    });
    if (!res.ok) throw new OAuthError(res.status);

    const { access_token } = (await res.json()) as { access_token: string };
    await this.env.KV.put(TOKEN_KV_KEY, access_token, { expirationTtl: TOKEN_TTL_SECONDS });
    return access_token;
  }

  async send(token: string, payload: PushPayload): Promise<PushResult> {
    let access: string;
    try {
      access = await this.accessToken();
    } catch (error) {
      const status = error instanceof OAuthError ? error.status : 0;
      return { ok: false, status, invalidToken: false };
    }

    const apnsHeaders: Record<string, string> = {
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    };
    if (payload.collapseId) apnsHeaders["apns-collapse-id"] = payload.collapseId.slice(0, MAX_COLLAPSE_ID);

    const data: Record<string, string> = { kind: payload.kind };
    if (payload.gtin) data.gtin = payload.gtin;

    const aps: Record<string, unknown> = {
      // Same `content-available` as the direct APNs path, for the same reason.
      aps: { alert: { title: payload.title, body: payload.body }, sound: "default", "content-available": 1 },
      kind: payload.kind,
    };
    if (payload.gtin) aps.gtin = payload.gtin;

    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${this.account().project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: payload.title, body: payload.body },
          data,
          apns: { headers: apnsHeaders, payload: aps },
        },
      }),
    });
    if (res.ok) return { ok: true, status: res.status, invalidToken: false };

    const text = await res.text().catch(() => "");
    return { ok: false, status: res.status, invalidToken: res.status === 404 || text.includes("UNREGISTERED") };
  }
}
```

- [ ] **Step 4: Implement the provider switch**

`backend/src/push/index.ts`:

```ts
import type { Env } from "../env";
import { APNsSender } from "./apns";
import { FCMSender } from "./fcm";
import type { PushSender } from "./PushSender";

export type { PushPayload, PushResult, PushSender } from "./PushSender";

/** Spec §6.5 — APNs by default; FCM is the fallback if HTTP/2 to Apple ever fails. */
export function pushSender(env: Env): PushSender {
  return env.PUSH_PROVIDER === "fcm" ? new FCMSender(env) : new APNsSender(env);
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/push-fcm.test.ts && npx tsc --noEmit`
Expected: `6 passed`; typecheck clean. Generating the RSA key makes this suite a second or two slower than the others — that is expected.

- [ ] **Step 6: Commit**

```bash
git add backend/src/push/fcm.ts backend/src/push/index.ts backend/test/push-fcm.test.ts
git commit -m "feat(backend): FCM HTTP v1 sender behind the PushSender interface"
```

---

### Task 6: The `alert_jobs` drain cron (`*/5 * * * *`)

**Files:**
- Create: `backend/src/alerts.ts`
- Modify: `backend/src/worker.ts`
- Modify: `backend/wrangler.toml`
- Test: `backend/test/alerts-drain.test.ts`

**Interfaces:**
- Consumes: `pushSender(env)` and `PushSender`/`PushPayload` (Task 5); `devices`/`watches`/`alert_jobs.sent_count` (Task 1); `runKrogerSweep` (Phase 3).
- Produces (`src/alerts.ts`):
  - `MAX_PUSHES_PER_RUN = 40`
  - `AlertJobRow { id: number; kind: string; gtin: string | null; brand: string | null; location_id: string | null; payload: string | null; sent_count: number }`
  - `DrainResult { jobs: number; pushes: number; cleared: number }`
  - `prefAllows(prefsJSON: string | null, kind: string): boolean`
  - `alertCopy(job: AlertJobRow, product: { name: string; brand: string } | null): PushPayload`
  - `runAlertDrain(env: Env, sender?: PushSender, now?: number): Promise<DrainResult>`
- Produces: `src/worker.ts` `scheduled` dispatching on `event.cron`; `wrangler.toml` `crons = ["*/5 * * * *", "0 */6 * * *"]`.
- Recipient rules (spec §6.2 and §3): `watches.alert_enabled = 1`, `devices.apns_token IS NOT NULL`, `devices.pro_until > now`. `verified_case` also reaches devices watching the job's **brand**. `price_hike` reaches only devices whose `location_id` matches the job's, because the price is store-specific. A job resumes from `sent_count` and is marked `sent_at` only once its recipient list is exhausted.

- [ ] **Step 1: Write the failing tests**

`backend/test/alerts-drain.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_PUSHES_PER_RUN, alertCopy, prefAllows, runAlertDrain } from "../src/alerts";
import type { PushPayload, PushResult, PushSender } from "../src/push/PushSender";

const NOW = 1800000000;
const PRO_UNTIL = NOW + 86400;
const GTIN = "0052000133417";
const LOCATION = "01400943";

function fakeSender(results: PushResult[] = []) {
  const sent: Array<{ token: string; payload: PushPayload }> = [];
  const sender: PushSender = {
    async send(token, payload) {
      sent.push({ token, payload });
      return results.shift() ?? { ok: true, status: 200, invalidToken: false };
    },
  };
  return { sender, sent };
}

async function seedDevice(
  id: string,
  opts: { token?: string | null; proUntil?: number | null; locationId?: string | null; prefs?: string | null } = {}
) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, ?, ?, NULL, ?, ?, NULL, NULL, ?)"
  )
    .bind(
      id,
      opts.token === undefined ? `token-${id}` : opts.token,
      opts.locationId === undefined ? LOCATION : opts.locationId,
      opts.prefs ?? null,
      opts.proUntil === undefined ? PRO_UNTIL : opts.proUntil,
      NOW
    )
    .run();
}

async function seedWatch(deviceId: string, gtin: string, brand: string | null, enabled = true) {
  await env.DB.prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, ?, ?)")
    .bind(deviceId, gtin, brand, enabled ? 1 : 0)
    .run();
}

async function seedJob(
  kind: string,
  opts: { gtin?: string | null; brand?: string | null; locationId?: string | null; payload?: unknown } = {}
): Promise<number> {
  const result = await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at, sent_count) VALUES (?, ?, ?, ?, ?, ?, NULL, 0)"
  )
    .bind(
      kind,
      opts.gtin === undefined ? GTIN : opts.gtin,
      opts.brand === undefined ? "Gatorade" : opts.brand,
      opts.locationId ?? null,
      JSON.stringify(opts.payload ?? { previous_size: "32 fl oz", size: "28 fl oz" }),
      NOW - 60
    )
    .run();
  return result.meta.last_row_id as number;
}

async function jobRow(id: number) {
  return env.DB.prepare("SELECT sent_at, sent_count FROM alert_jobs WHERE id = ?").bind(id).first<{ sent_at: number | null; sent_count: number }>();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade Thirst Quencher', 'Gatorade', 'Beverages', NULL, 'volume', 1, 1)"
  ).bind(GTIN).run();
});

describe("prefAllows", () => {
  it("defaults to on and honours an explicit false", () => {
    expect(prefAllows(null, "size_drop")).toBe(true);
    expect(prefAllows("{}", "size_drop")).toBe(true);
    expect(prefAllows(JSON.stringify({ sizeDrop: false }), "size_drop")).toBe(false);
    expect(prefAllows(JSON.stringify({ sizeDrop: false }), "price_hike")).toBe(true);
    expect(prefAllows(JSON.stringify({ priceHike: false }), "price_hike")).toBe(false);
    expect(prefAllows(JSON.stringify({ verifiedCase: false }), "verified_case")).toBe(false);
    expect(prefAllows("not json", "size_drop")).toBe(true);
  });
});

describe("alertCopy", () => {
  const base = { id: 1, gtin: GTIN, brand: "Gatorade", location_id: null, sent_count: 0 };

  it("writes size-drop copy from the Kroger sweep payload", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", payload: JSON.stringify({ previous_size: "32 fl oz", size: "28 fl oz" }) },
      { name: "Gatorade Thirst Quencher", brand: "Gatorade" }
    );
    expect(payload).toEqual({
      title: "Gatorade Thirst Quencher just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: GTIN,
      kind: "sizeDrop",
      collapseId: `size_drop:${GTIN}`,
    });
  });

  it("writes size-drop copy from the crowd payload", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", payload: JSON.stringify({ percent_change: -12.5, source: "crowd" }) },
      null
    );
    expect(payload.title).toBe("Gatorade just shrank");
    expect(payload.body).toBe("Down 12.5% since the last size we saw. Tap to see the history.");
    expect(payload.kind).toBe("sizeDrop");
  });

  it("writes price-hike copy with the percentage", () => {
    const payload = alertCopy(
      { ...base, kind: "price_hike", location_id: LOCATION, payload: JSON.stringify({ previous_per_unit: 2, per_unit: 2.1 }) },
      { name: "Gatorade Thirst Quencher", brand: "Gatorade" }
    );
    expect(payload.title).toBe("Gatorade Thirst Quencher costs more per unit");
    expect(payload.body).toBe("Now $2.10 per unit at your store — was $2.00 (+5.0%).");
    expect(payload.kind).toBe("priceHike");
  });

  it("writes verified-case copy", () => {
    const payload = alertCopy({ ...base, kind: "verified_case", payload: null }, null);
    expect(payload.title).toBe("New verified case: Gatorade");
    expect(payload.kind).toBe("verifiedCase");
    expect(payload.body).toBe("We just published a confirmed shrink for this one. Tap to see the evidence.");
  });

  it("falls back when there is no product and no brand", () => {
    const payload = alertCopy({ ...base, kind: "size_drop", brand: null, payload: null }, null);
    expect(payload.title).toBe("A watched product just shrank");
    expect(payload.body).toBe("A smaller size was just observed. Tap to see the history.");
  });
});

describe("runAlertDrain", () => {
  it("pushes a size drop to a Pro watcher and marks the job sent", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    const id = await seedJob("size_drop");

    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 1, cleared: 0 });

    expect(sent).toHaveLength(1);
    expect(sent[0].token).toBe("token-dev-1");
    expect(sent[0].payload.kind).toBe("sizeDrop");
    expect(sent[0].payload.gtin).toBe(GTIN);
    expect(await jobRow(id)).toEqual({ sent_at: NOW, sent_count: 1 });
  });

  it("never pushes twice for the same job", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    await seedJob("size_drop");

    const first = fakeSender();
    await runAlertDrain(env, first.sender, NOW);
    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 0, pushes: 0, cleared: 0 });
    expect(second.sent).toHaveLength(0);
  });

  it("skips devices that are not Pro, muted, tokenless, or opted out", async () => {
    await seedDevice("dev-pro");
    await seedWatch("dev-pro", GTIN, "Gatorade");
    await seedDevice("dev-free", { proUntil: null });
    await seedWatch("dev-free", GTIN, "Gatorade");
    await seedDevice("dev-expired", { proUntil: NOW - 1 });
    await seedWatch("dev-expired", GTIN, "Gatorade");
    await seedDevice("dev-muted");
    await seedWatch("dev-muted", GTIN, "Gatorade", false);
    await seedDevice("dev-notoken", { token: null });
    await seedWatch("dev-notoken", GTIN, "Gatorade");
    await seedDevice("dev-optout", { prefs: JSON.stringify({ sizeDrop: false }) });
    await seedWatch("dev-optout", GTIN, "Gatorade");
    await seedJob("size_drop");

    const { sender, sent } = fakeSender();
    const result = await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-pro"]);
    expect(result.pushes).toBe(1);
  });

  it("reaches a brand watcher for a verified case", async () => {
    await seedDevice("dev-brand");
    await seedWatch("dev-brand", "0099999999999", "gatorade");   // different product, same brand
    await seedDevice("dev-other");
    await seedWatch("dev-other", "0099999999998", "Doritos");
    await seedJob("verified_case");

    const { sender, sent } = fakeSender();
    await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-brand"]);
    expect(sent[0].payload.kind).toBe("verifiedCase");
  });

  it("sends a price hike only to devices at that store", async () => {
    await seedDevice("dev-here", { locationId: LOCATION });
    await seedWatch("dev-here", GTIN, "Gatorade");
    await seedDevice("dev-elsewhere", { locationId: "09999999" });
    await seedWatch("dev-elsewhere", GTIN, "Gatorade");
    await seedJob("price_hike", { locationId: LOCATION, payload: { previous_per_unit: 2, per_unit: 2.1 } });

    const { sender, sent } = fakeSender();
    await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-here"]);
  });

  it("clears a device token that APNs rejected", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    await seedJob("size_drop");

    const { sender } = fakeSender([{ ok: false, status: 410, invalidToken: true }]);
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 1 });

    const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
    expect(row!.apns_token).toBeNull();
  });

  it("caps a run at 40 pushes and resumes the job on the next run", async () => {
    for (let i = 0; i < 45; i++) {
      const id = `dev-${String(i).padStart(2, "0")}`;
      await seedDevice(id);
      await seedWatch(id, GTIN, "Gatorade");
    }
    const id = await seedJob("size_drop");

    const first = fakeSender();
    expect(await runAlertDrain(env, first.sender, NOW)).toEqual({ jobs: 1, pushes: MAX_PUSHES_PER_RUN, cleared: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: null, sent_count: 40 });

    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 1, pushes: 5, cleared: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: NOW + 300, sent_count: 45 });
    expect(new Set([...first.sent, ...second.sent].map((s) => s.token)).size).toBe(45);
  });

  it("marks a job with no recipients sent, without pushing", async () => {
    const id = await seedJob("size_drop");
    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 0 });
    expect(sent).toHaveLength(0);
    expect(await jobRow(id)).toEqual({ sent_at: NOW, sent_count: 0 });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/alerts-drain.test.ts`
Expected: FAIL — `Cannot find module '../src/alerts'`.

- [ ] **Step 3: Implement the drain**

`backend/src/alerts.ts`:

```ts
import type { Env } from "./env";
import { pushSender } from "./push";
import type { PushPayload, PushSender } from "./push/PushSender";

/** Spec §6.2 — at most 40 pushes per five-minute invocation. */
export const MAX_PUSHES_PER_RUN = 40;
/** How many unsent jobs one run will even look at. */
const JOB_SCAN_LIMIT = 50;

export interface AlertJobRow {
  id: number;
  kind: string;
  gtin: string | null;
  brand: string | null;
  location_id: string | null;
  payload: string | null;
  sent_count: number;
}

export interface DrainResult {
  jobs: number;
  pushes: number;
  cleared: number;
}

interface RecipientRow {
  id: string;
  apns_token: string;
  prefs: string | null;
}

/** D1 alert_jobs.kind (snake) -> the app's per-kind toggle (camel). */
const PREF_KEY: Record<string, string> = {
  size_drop: "sizeDrop",
  price_hike: "priceHike",
  verified_case: "verifiedCase",
  digest: "digest",
};

/** D1 alert_jobs.kind -> the wire `kind` the app maps onto ShrinkAlert.Kind. */
const WIRE_KIND: Record<string, string> = {
  size_drop: "sizeDrop",
  price_hike: "priceHike",
  verified_case: "verifiedCase",
  digest: "digest",
};

/** A missing or unparseable prefs blob means every kind is on. */
export function prefAllows(prefsJSON: string | null, kind: string): boolean {
  const key = PREF_KEY[kind];
  if (!key || !prefsJSON) return true;
  try {
    const prefs = JSON.parse(prefsJSON) as Record<string, unknown>;
    return prefs[key] !== false;
  } catch {
    return true;
  }
}

function parsePayload(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function sizeDropBody(p: Record<string, unknown>): string {
  const previousSize = typeof p.previous_size === "string" ? p.previous_size : null;
  const size = typeof p.size === "string" ? p.size : null;
  if (previousSize && size) return `Now ${size} — was ${previousSize}. Tap to see the history.`;
  const percent = typeof p.percent_change === "number" ? p.percent_change : null;
  if (percent !== null) return `Down ${Math.abs(percent).toFixed(1)}% since the last size we saw. Tap to see the history.`;
  return "A smaller size was just observed. Tap to see the history.";
}

function priceHikeBody(p: Record<string, unknown>): string {
  const before = typeof p.previous_per_unit === "number" ? p.previous_per_unit : null;
  const after = typeof p.per_unit === "number" ? p.per_unit : null;
  if (before !== null && after !== null && before > 0) {
    const percent = ((after - before) / before) * 100;
    return `Now $${after.toFixed(2)} per unit at your store — was $${before.toFixed(2)} (+${percent.toFixed(1)}%).`;
  }
  return "The price per unit went up at your store. Tap to see the details.";
}

/** The push a job turns into. Copy lives here so it is testable without a network. */
export function alertCopy(job: AlertJobRow, product: { name: string; brand: string } | null): PushPayload {
  const payload = parsePayload(job.payload);
  const label = product?.name?.trim() || job.brand?.trim() || "A watched product";
  const kind = WIRE_KIND[job.kind] ?? job.kind;
  const collapseId = `${job.kind}:${job.gtin ?? job.brand ?? "all"}`;
  const gtin = job.gtin ?? undefined;

  switch (job.kind) {
    case "size_drop":
      return { title: `${label} just shrank`, body: sizeDropBody(payload), gtin, kind, collapseId };
    case "price_hike":
      return { title: `${label} costs more per unit`, body: priceHikeBody(payload), gtin, kind, collapseId };
    case "verified_case":
      return {
        title: `New verified case: ${label}`,
        body: "We just published a confirmed shrink for this one. Tap to see the evidence.",
        gtin,
        kind,
        collapseId,
      };
    default:
      return { title: `Update on ${label}`, body: "Tap to see what changed.", gtin, kind, collapseId };
  }
}

/**
 * The devices that should receive this job, ordered so `OFFSET` is a stable
 * resume cursor. Spec §6.2: Pro only, alerts enabled, token present.
 */
async function recipientsFor(env: Env, job: AlertJobRow, now: number, limit: number, offset: number): Promise<RecipientRow[]> {
  const clauses = ["w.alert_enabled = 1", "d.apns_token IS NOT NULL", "d.pro_until IS NOT NULL", "d.pro_until > ?"];
  const binds: unknown[] = [now];

  if (job.kind === "verified_case" && job.brand) {
    // Spec §3: a verified case for a watched product **or brand**.
    clauses.push("(w.gtin = ? OR (w.brand IS NOT NULL AND lower(w.brand) = lower(?)))");
    binds.push(job.gtin ?? "", job.brand);
  } else {
    if (!job.gtin) return [];
    clauses.push("w.gtin = ?");
    binds.push(job.gtin);
  }

  if (job.kind === "price_hike" && job.location_id) {
    // A per-unit price is store-specific; only that store's shoppers care.
    clauses.push("d.location_id = ?");
    binds.push(job.location_id);
  }

  binds.push(limit, offset);
  const { results } = await env.DB
    .prepare(
      `SELECT d.id AS id, d.apns_token AS apns_token, d.prefs AS prefs
       FROM watches w JOIN devices d ON d.id = w.device_id
       WHERE ${clauses.join(" AND ")}
       GROUP BY d.id
       ORDER BY d.id
       LIMIT ? OFFSET ?`
    )
    .bind(...binds)
    .all<RecipientRow>();
  return results;
}

/**
 * Spec §6.2 — every five minutes, turn unsent `alert_jobs` rows into pushes.
 * A job larger than the per-run budget keeps its `sent_at` NULL and resumes
 * from `sent_count` next time, so nobody is pushed twice and nobody is dropped.
 */
export async function runAlertDrain(
  env: Env,
  sender: PushSender = pushSender(env),
  now: number = Math.floor(Date.now() / 1000)
): Promise<DrainResult> {
  const result: DrainResult = { jobs: 0, pushes: 0, cleared: 0 };
  let budget = MAX_PUSHES_PER_RUN;

  const { results: jobs } = await env.DB
    .prepare(
      "SELECT id, kind, gtin, brand, location_id, payload, sent_count FROM alert_jobs WHERE sent_at IS NULL ORDER BY created_at ASC, id ASC LIMIT ?"
    )
    .bind(JOB_SCAN_LIMIT)
    .all<AlertJobRow>();

  for (const job of jobs) {
    if (budget <= 0) break;
    result.jobs += 1;

    const limit = budget;
    const recipients = await recipientsFor(env, job, now, limit, job.sent_count);

    const product = job.gtin
      ? await env.DB.prepare("SELECT name, brand FROM products WHERE gtin = ?").bind(job.gtin).first<{ name: string; brand: string }>()
      : null;
    const payload = alertCopy(job, product);

    for (const device of recipients) {
      if (!prefAllows(device.prefs, job.kind)) continue;
      const sendResult = await sender.send(device.apns_token, payload);
      if (sendResult.ok) result.pushes += 1;
      if (sendResult.invalidToken) {
        await env.DB.prepare("UPDATE devices SET apns_token = NULL WHERE id = ?").bind(device.id).run();
        result.cleared += 1;
      }
    }

    const processed = job.sent_count + recipients.length;
    if (recipients.length < limit) {
      await env.DB.prepare("UPDATE alert_jobs SET sent_at = ?, sent_count = ? WHERE id = ?").bind(now, processed, job.id).run();
    } else {
      await env.DB.prepare("UPDATE alert_jobs SET sent_count = ? WHERE id = ?").bind(processed, job.id).run();
    }
    budget -= recipients.length;
  }

  return result;
}
```

- [ ] **Step 4: Dispatch the cron**

Replace the body of `scheduled` in `backend/src/worker.ts` (keep the Phase 3 `fetch` line and the file's existing imports, adding `runAlertDrain`):

```ts
import type { Env } from "./env";
import app from "./index";
import { runAlertDrain } from "./alerts";
import { runKrogerSweep } from "./sweep";

/**
 * Workers entry point. `src/index.ts` stays the Hono app so tests can keep
 * calling `app.request(...)`; this module only adds the cron surface (spec §6.2).
 */
export default {
  fetch: app.fetch,
  async scheduled(event: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    switch (event.cron) {
      case "*/5 * * * *":
        ctx.waitUntil(runAlertDrain(env));
        break;
      case "0 */6 * * *":
        ctx.waitUntil(runKrogerSweep(env));
        break;
    }
  },
} satisfies ExportedHandler<Env>;
```

`backend/wrangler.toml` — extend the `[triggers]` block Phase 3 added:

```toml
[triggers]
crons = ["*/5 * * * *", "0 */6 * * *"]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/alerts-drain.test.ts && npx tsc --noEmit`
Expected: `14 passed`; typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add backend/src/alerts.ts backend/src/worker.ts backend/wrangler.toml backend/test/alerts-drain.test.ts
git commit -m "feat(backend): five-minute alert_jobs drain with Pro gating and a 40-push cap"
```

---

### Task 7: `POST /v1/admin/verified-case`

**Files:**
- Create: `backend/src/routes/admin-verified.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/admin-verified.test.ts`

**Interfaces:**
- Consumes: `insertAlertJob` and `NewAlertJob` (Phase 2 `src/db.ts`), `normalizeGTIN` (Phase 1), `Env.ADMIN_SECRET` (Phase 2).
- Produces: `adminVerifiedRoute` exported from `src/routes/admin-verified.ts`, mounted with `app.route("/", adminVerifiedRoute)`.
- Produces: `POST /v1/admin/verified-case` with `Authorization: Bearer <ADMIN_SECRET>` and body `{gtin?, brand?}` → `200 {ok: true}`; `401 {error:"unauthorized"}`; `400 {error:"invalid_case"}` when neither a normalizable gtin nor a brand is supplied. This is how a curated addition notifies watchers: it files an `alert_jobs(kind='verified_case')` row that the Task 6 drain picks up.

- [ ] **Step 1: Write the failing tests**

`backend/test/admin-verified.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0052000133417";

async function post(body: unknown, secret: string | null = "test-admin-secret") {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers.Authorization = `Bearer ${secret}`;
  return app.request("/v1/admin/verified-case", { method: "POST", headers, body: JSON.stringify(body) }, env);
}

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM alert_jobs").run();
});

describe("POST /v1/admin/verified-case", () => {
  it("files an unsent verified_case job", async () => {
    const res = await post({ gtin: "052000133417", brand: "Gatorade" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });

    const row = await env.DB.prepare("SELECT kind, gtin, brand, location_id, sent_at, sent_count FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ kind: "verified_case", gtin: GTIN, brand: "Gatorade", location_id: null, sent_at: null, sent_count: 0 });
  });

  it("accepts a brand-only case", async () => {
    expect((await post({ brand: "Doritos" })).status).toBe(200);
    const row = await env.DB.prepare("SELECT gtin, brand FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ gtin: null, brand: "Doritos" });
  });

  it("rejects an empty case", async () => {
    const res = await post({ gtin: "nope" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_case" });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>()).toEqual({ n: 0 });
  });

  it("requires the admin bearer secret", async () => {
    expect((await post({ brand: "Doritos" }, null)).status).toBe(401);
    expect((await post({ brand: "Doritos" }, "wrong")).status).toBe(401);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>()).toEqual({ n: 0 });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/admin-verified.test.ts`
Expected: FAIL — 404 from the unmounted route.

- [ ] **Step 3: Implement the route**

`backend/src/routes/admin-verified.ts`:

```ts
import { Hono } from "hono";
import { insertAlertJob } from "../db";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";

export const adminVerifiedRoute = new Hono<{ Bindings: Env }>();

/**
 * Publishes a verified case: files the alert job the five-minute drain turns
 * into pushes for everyone watching that product or brand (spec §3, §6.2).
 */
adminVerifiedRoute.post("/v1/admin/verified-case", async (c) => {
  if (c.req.header("Authorization") !== `Bearer ${c.env.ADMIN_SECRET}`) {
    return c.json({ error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = (await c.req.json()) as Record<string, unknown>;
  } catch {
    return c.json({ error: "invalid_case" }, 400);
  }

  const gtin = normalizeGTIN(typeof body.gtin === "string" ? body.gtin : null);
  const brandRaw = typeof body.brand === "string" ? body.brand.trim() : "";
  const brand = brandRaw && brandRaw.length <= 120 ? brandRaw : null;
  if (!gtin && !brand) return c.json({ error: "invalid_case" }, 400);

  await insertAlertJob(c.env.DB, {
    kind: "verified_case",
    gtin: gtin as string,          // insertAlertJob binds NULL for a null gtin
    brand,
    location_id: null,
    payload: JSON.stringify({ source: "curated" }),
    created_at: Math.floor(Date.now() / 1000),
  });

  return c.json({ ok: true });
});
```

If Phase 2's `NewAlertJob.gtin` is typed `string` (not `string | null`), the brand-only case needs the cast shown above; the column itself is nullable, so the row stores `NULL` correctly.

- [ ] **Step 4: Mount the route**

In `backend/src/index.ts`:

```ts
import { adminVerifiedRoute } from "./routes/admin-verified";
```

```ts
app.route("/", adminVerifiedRoute);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/admin-verified.test.ts && npx tsc --noEmit`
Expected: `4 passed`; typecheck clean.

- [ ] **Step 6: Commit**

```bash
git add backend/src/routes/admin-verified.ts backend/src/index.ts backend/test/admin-verified.test.ts
git commit -m "feat(backend): admin endpoint that publishes a verified case as an alert job"
```

---

### Task 8: The Kroger sweep iterates `watches × devices`

**Files:**
- Modify: `backend/src/sweep.ts` (the pairs query only)
- Test: `backend/test/sweep-pairs.test.ts`

**Interfaces:**
- Consumes: `runKrogerSweep(env, client?)` and `SweepResult` (Phase 3) — the signature does **not** change.
- Produces: no new exports. Spec §6.2: the sweep's `(gtin, location_id)` set becomes the distinct pairs from `watches JOIN devices` (devices with a store set) **unioned** with the pairs already present in `price_snapshots`, so nothing that was being tracked stops being tracked.
- The new test file injects a fake `KrogerClient` and never touches the network, so it is independent of however the Phase 3 suite stubs `fetch`.

- [ ] **Step 1: Write the failing test**

`backend/test/sweep-pairs.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { runKrogerSweep } from "../src/sweep";
import type { KrogerClient } from "../src/kroger/client";
import type { Env } from "../src/env";

// Both are 13-digit GTINs that Phase 3's `krogerProductId` converts cleanly —
// the sweep silently drops any it cannot convert, which would mask a bug here.
const GTIN_WATCHED = "0028400642255";
const GTIN_SNAPSHOT = "0028400642262";
const LOCATION = "01400943";
const OTHER_LOCATION = "09999999";

interface Batch { ids: string[]; locationId: string }

/** A KrogerClient that answers every batch with no products and records the call. */
function fakeClient(): { client: KrogerClient; batches: Batch[] } {
  const batches: Batch[] = [];
  const client = {
    async products(ids: string[], locationId: string) {
      batches.push({ ids, locationId });
      return { data: [] };
    },
  } as unknown as KrogerClient;
  return { client, batches };
}

const on = () => ({ ...env, KROGER_PERSIST: "on" }) as Env;

async function seedDevice(id: string, locationId: string | null) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, 'tok', ?, NULL, NULL, NULL, NULL, NULL, 1)"
  ).bind(id, locationId).run();
}

async function seedWatch(deviceId: string, gtin: string) {
  await env.DB.prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, 'Gatorade', 1)")
    .bind(deviceId, gtin)
    .run();
}

async function seedSnapshot(gtin: string, locationId: string) {
  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, 2.0, '32 fl oz', 'HIGH', 1700000000)"
  ).bind(gtin, locationId).run();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM alert_jobs"),
  ]);
});

describe("runKrogerSweep pair selection", () => {
  it("sweeps a watched product at the watcher's store", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);

    const { client, batches } = fakeClient();
    const result = await runKrogerSweep(on(), client);

    expect(result.pairs).toBe(1);
    expect(batches).toHaveLength(1);
    expect(batches[0].locationId).toBe(LOCATION);
    expect(batches[0].ids).toHaveLength(1);
  });

  it("ignores a watcher with no store set", async () => {
    await seedDevice("dev-1", null);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", "");
    await seedWatch("dev-2", GTIN_WATCHED);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(0);
    expect(batches).toHaveLength(0);
  });

  it("keeps sweeping pairs we already hold snapshots for", async () => {
    await seedSnapshot(GTIN_SNAPSHOT, LOCATION);
    const { client } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(1);
  });

  it("counts a pair once when it is both watched and snapshotted", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", LOCATION);
    await seedWatch("dev-2", GTIN_WATCHED);
    await seedSnapshot(GTIN_WATCHED, LOCATION);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(1);
    expect(batches[0].ids).toHaveLength(1);
  });

  it("groups by store", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", OTHER_LOCATION);
    await seedWatch("dev-2", GTIN_SNAPSHOT);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(2);
    expect(new Set(batches.map((b) => b.locationId))).toEqual(new Set([LOCATION, OTHER_LOCATION]));
  });

  it("still does nothing when persistence is off", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    const { client, batches } = fakeClient();
    expect(await runKrogerSweep(env, client)).toEqual({ pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0 });
    expect(batches).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/sweep-pairs.test.ts`
Expected: FAIL — the first test reports `pairs: 0`, because the Phase 3 sweep only reads `price_snapshots`.

- [ ] **Step 3: Replace the pairs query**

In `backend/src/sweep.ts`, replace the single `SELECT DISTINCT gtin, location_id FROM price_snapshots` query (and update the comment above `runKrogerSweep` that says Phase 4 will do this) with:

```ts
  // Spec §6.2 — the sweep follows the watchlists: every product a device
  // watches, at that device's store, plus every pair we already snapshot.
  const { results: pairs } = await env.DB
    .prepare(
      `SELECT DISTINCT w.gtin AS gtin, d.location_id AS location_id
       FROM watches w JOIN devices d ON d.id = w.device_id
       WHERE d.location_id IS NOT NULL AND d.location_id <> ''
       UNION
       SELECT DISTINCT gtin AS gtin, location_id AS location_id FROM price_snapshots`
    )
    .all<{ gtin: string; location_id: string }>();
```

Update the doc comment on `runKrogerSweep` to:

```ts
/**
 * Six-hourly Kroger sweep (spec §6.2). The (gtin, location_id) set is the
 * distinct pairs from `watches x devices` — a device only counts once it has a
 * store — unioned with the pairs we already hold snapshots for. Compares the
 * new snapshot with the previous one for the same pair and files
 * `alert_jobs(kind='size_drop' | 'price_hike')`.
 */
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/sweep-pairs.test.ts test/sweep.test.ts && npx tsc --noEmit`
Expected: `sweep-pairs.test.ts` `6 passed`; the Phase 3 `sweep.test.ts` still green — its fixtures seed `price_snapshots`, which the `UNION` still covers.

- [ ] **Step 5: Commit**

```bash
git add backend/src/sweep.ts backend/test/sweep-pairs.test.ts
git commit -m "feat(backend): Kroger sweep follows watches x devices, not just past snapshots"
```

---

### Task 9: The weekly digest cron (`0 1 * * 1`)

**Files:**
- Create: `backend/src/digest.ts`
- Modify: `backend/src/worker.ts`
- Modify: `backend/wrangler.toml`
- Test: `backend/test/digest.test.ts`

**Interfaces:**
- Consumes: `previousAcceptedQuantity` (Task 1), `canonicalCategory` (Task 2), `pushSender`/`PushSender` (Task 5), `prefAllows` (Task 6).
- Produces (`src/digest.ts`):
  - `DIGEST_WINDOW_SECONDS = 7 * 24 * 60 * 60`
  - `DigestResult { counts: Record<string, number>; devices: number; pushes: number; cleared: number }`
  - `weeklyCounts(env: Env, now: number): Promise<Map<string, number>>` — distinct products per canonical category that shrank, counting accepted shrink observations and `verified_case` jobs from the last 7 days (a product counted by both counts once).
  - `digestBody(counts: Array<[string, number]>): string` — `"3 new shrinks in Snacks, 1 in Dairy"`.
  - `runWeeklyDigest(env: Env, sender?: PushSender, now?: number): Promise<DigestResult>` — one push per Pro device whose subscribed categories have a non-zero count; a device with no categories gets nothing.
- Produces: the third cron trigger and its `worker.ts` case.

- [ ] **Step 1: Write the failing tests**

`backend/test/digest.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { digestBody, runWeeklyDigest, weeklyCounts } from "../src/digest";
import type { PushPayload, PushResult, PushSender } from "../src/push/PushSender";

const NOW = 1800000000;
const DAY = 86400;
const PRO_UNTIL = NOW + DAY;

function fakeSender(results: PushResult[] = []) {
  const sent: Array<{ token: string; payload: PushPayload }> = [];
  const sender: PushSender = {
    async send(token, payload) {
      sent.push({ token, payload });
      return results.shift() ?? { ok: true, status: 200, invalidToken: false };
    },
  };
  return { sender, sent };
}

async function seedShrink(gtin: string, category: string, previous: number, current: number, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'P', 'B', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', 'old', ?, 'fdc', '1', 0.9, 'accepted', ?)"
  ).bind(gtin, previous, createdAt - 400 * DAY, createdAt - 400 * DAY).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', 'new', ?, 'crowd', 'sub-1', 0.9, 'accepted', ?)"
  ).bind(gtin, current, createdAt, createdAt).run();
}

async function seedVerifiedCase(gtin: string, category: string, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'P', 'B', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at, sent_count) VALUES ('verified_case', ?, 'B', NULL, '{}', ?, NULL, 0)"
  ).bind(gtin, createdAt).run();
}

async function seedDevice(
  id: string,
  categories: string[] | null,
  opts: { token?: string | null; proUntil?: number | null; prefs?: string | null } = {}
) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, ?, '01400943', ?, ?, ?, NULL, NULL, 1)"
  )
    .bind(
      id,
      opts.token === undefined ? `token-${id}` : opts.token,
      categories === null ? null : JSON.stringify(categories),
      opts.prefs ?? null,
      opts.proUntil === undefined ? PRO_UNTIL : opts.proUntil
    )
    .run();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM products"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM watches"),
  ]);
});

describe("digestBody", () => {
  it("spells the first category out and abbreviates the rest", () => {
    expect(digestBody([["Snacks", 3], ["Dairy", 1]])).toBe("3 new shrinks in Snacks, 1 in Dairy");
    expect(digestBody([["Dairy", 1]])).toBe("1 new shrink in Dairy");
  });
});

describe("weeklyCounts", () => {
  it("counts shrinks and verified cases per canonical category, once per product", async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000012", "snacks", 340, 300, NOW - 2 * DAY);
    await seedShrink("0000000000013", "Dairy", 946, 800, NOW - 3 * DAY);
    await seedVerifiedCase("0000000000014", "Drinks", NOW - DAY);
    await seedVerifiedCase("0000000000011", "Snacks", NOW - DAY);   // same product, already counted

    const counts = await weeklyCounts(env, NOW);
    expect(Object.fromEntries(counts)).toEqual({ Snacks: 2, Dairy: 1, Beverages: 1 });
  });

  it("ignores anything older than seven days, and anything that did not shrink", async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - 8 * DAY);
    await seedShrink("0000000000012", "Snacks", 340, 341, NOW - DAY);
    await seedVerifiedCase("0000000000013", "Snacks", NOW - 30 * DAY);
    expect(Object.fromEntries(await weeklyCounts(env, NOW))).toEqual({});
  });
});

describe("runWeeklyDigest", () => {
  beforeEach(async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000012", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000013", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000014", "Dairy", 946, 800, NOW - DAY);
  });

  it("sends one push per Pro device summarising its categories", async () => {
    await seedDevice("dev-1", ["Snacks", "Dairy", "Paper products"]);
    const { sender, sent } = fakeSender();

    const result = await runWeeklyDigest(env, sender, NOW);
    expect(result).toMatchObject({ devices: 1, pushes: 1, cleared: 0 });
    expect(sent).toHaveLength(1);
    expect(sent[0].token).toBe("token-dev-1");
    expect(sent[0].payload).toEqual({
      title: "What shrank this week",
      body: "3 new shrinks in Snacks, 1 in Dairy",
      kind: "digest",
      collapseId: "digest",
    });
  });

  it("skips devices with no matching category, no categories, no token, no Pro, or digest off", async () => {
    await seedDevice("dev-match", ["Snacks"]);
    await seedDevice("dev-other", ["Cleaning"]);
    await seedDevice("dev-nocats", []);
    await seedDevice("dev-nullcats", null);
    await seedDevice("dev-notoken", ["Snacks"], { token: null });
    await seedDevice("dev-free", ["Snacks"], { proUntil: null });
    await seedDevice("dev-expired", ["Snacks"], { proUntil: NOW - 1 });
    await seedDevice("dev-optout", ["Snacks"], { prefs: JSON.stringify({ digest: false }) });

    const { sender, sent } = fakeSender();
    await runWeeklyDigest(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-match"]);
  });

  it("canonicalises the device's stored category names", async () => {
    await seedDevice("dev-1", ["Drinks", "Snacks"]);
    const { sender, sent } = fakeSender();
    await runWeeklyDigest(env, sender, NOW);
    expect(sent[0].payload.body).toBe("3 new shrinks in Snacks");
  });

  it("clears a token the push provider rejected", async () => {
    await seedDevice("dev-1", ["Snacks"]);
    const { sender } = fakeSender([{ ok: false, status: 410, invalidToken: true }]);
    const result = await runWeeklyDigest(env, sender, NOW);
    expect(result).toMatchObject({ pushes: 0, cleared: 1 });
    const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
    expect(row!.apns_token).toBeNull();
  });

  it("sends nothing at all in a quiet week", async () => {
    await env.DB.prepare("DELETE FROM observations").run();
    await seedDevice("dev-1", ["Snacks"]);
    const { sender, sent } = fakeSender();
    expect(await runWeeklyDigest(env, sender, NOW)).toEqual({ counts: {}, devices: 0, pushes: 0, cleared: 0 });
    expect(sent).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/digest.test.ts`
Expected: FAIL — `Cannot find module '../src/digest'`.

- [ ] **Step 3: Implement the digest**

`backend/src/digest.ts`:

```ts
import { canonicalCategory } from "./categories";
import { previousAcceptedQuantity } from "./db";
import type { Env } from "./env";
import { prefAllows } from "./alerts";
import { pushSender } from "./push";
import type { PushSender } from "./push/PushSender";

/** Spec §6.2 — "the last 7 days". */
export const DIGEST_WINDOW_SECONDS = 7 * 24 * 60 * 60;
/** Spec §5.1 — inside 1% is the same size. */
const SHRINK_TOLERANCE = 0.01;
const OBSERVATION_LIMIT = 500;
/** A hard ceiling, not a paging scheme: past 1000 Pro devices this needs paging. */
const DEVICE_LIMIT = 1000;

export interface DigestResult {
  counts: Record<string, number>;
  devices: number;
  pushes: number;
  cleared: number;
}

interface WeekObservation {
  id: number;
  gtin: string;
  quantity: number;
  unit_kind: string;
  observed_at: number;
  category: string | null;
}

/**
 * Distinct products per canonical category that shrank in the last seven days:
 * accepted observations smaller than the previous same-kind one, plus curated
 * additions published as `verified_case` jobs (spec §6.2).
 */
export async function weeklyCounts(env: Env, now: number): Promise<Map<string, number>> {
  const since = now - DIGEST_WINDOW_SECONDS;
  const byCategory = new Map<string, Set<string>>();
  const add = (category: string, gtin: string) => {
    const set = byCategory.get(category) ?? new Set<string>();
    set.add(gtin);
    byCategory.set(category, set);
  };

  const { results: observations } = await env.DB
    .prepare(
      `SELECT o.id AS id, o.gtin AS gtin, o.quantity AS quantity, o.unit_kind AS unit_kind,
              o.observed_at AS observed_at, p.category AS category
       FROM observations o JOIN products p ON p.gtin = o.gtin
       WHERE o.status = 'accepted' AND o.created_at >= ?
       ORDER BY o.id DESC
       LIMIT ?`
    )
    .bind(since, OBSERVATION_LIMIT)
    .all<WeekObservation>();

  for (const row of observations) {
    const category = canonicalCategory(row.category);
    if (!category) continue;
    const previous = await previousAcceptedQuantity(env.DB, row.gtin, row.unit_kind, row.observed_at, row.id);
    if (previous === null || previous <= 0) continue;
    if ((previous - row.quantity) / previous <= SHRINK_TOLERANCE) continue;
    add(category, row.gtin);
  }

  const { results: cases } = await env.DB
    .prepare(
      `SELECT j.gtin AS gtin, p.category AS category
       FROM alert_jobs j LEFT JOIN products p ON p.gtin = j.gtin
       WHERE j.kind = 'verified_case' AND j.created_at >= ?`
    )
    .bind(since)
    .all<{ gtin: string | null; category: string | null }>();

  for (const row of cases) {
    const category = canonicalCategory(row.category);
    if (!category || !row.gtin) continue;   // a brand-only case has no category to file under
    add(category, row.gtin);
  }

  return new Map([...byCategory].map(([category, gtins]) => [category, gtins.size]));
}

/** "3 new shrinks in Snacks, 1 in Dairy" (spec §6.2). */
export function digestBody(counts: Array<[string, number]>): string {
  return counts
    .map(([category, count], index) =>
      index === 0 ? `${count} new shrink${count === 1 ? "" : "s"} in ${category}` : `${count} in ${category}`
    )
    .join(", ");
}

function subscribedCategories(raw: string | null): string[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const out: string[] = [];
    for (const entry of parsed) {
      const name = canonicalCategory(typeof entry === "string" ? entry : null);
      if (name && !out.includes(name)) out.push(name);
    }
    return out;
  } catch {
    return [];
  }
}

/**
 * Monday 01:00 (spec §6.2): one push per Pro device that subscribes to a
 * category something shrank in. A device with no categories gets nothing.
 */
export async function runWeeklyDigest(
  env: Env,
  sender: PushSender = pushSender(env),
  now: number = Math.floor(Date.now() / 1000)
): Promise<DigestResult> {
  const counts = await weeklyCounts(env, now);
  const result: DigestResult = { counts: Object.fromEntries(counts), devices: 0, pushes: 0, cleared: 0 };
  if (counts.size === 0) return result;

  const { results: devices } = await env.DB
    .prepare(
      `SELECT id, apns_token, categories, prefs FROM devices
       WHERE apns_token IS NOT NULL AND pro_until IS NOT NULL AND pro_until > ?
       ORDER BY id LIMIT ?`
    )
    .bind(now, DEVICE_LIMIT)
    .all<{ id: string; apns_token: string; categories: string | null; prefs: string | null }>();

  for (const device of devices) {
    result.devices += 1;
    if (!prefAllows(device.prefs, "digest")) continue;

    const mine = subscribedCategories(device.categories)
      .map((category) => [category, counts.get(category) ?? 0] as [string, number])
      .filter(([, count]) => count > 0)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    if (mine.length === 0) continue;

    const sendResult = await sender.send(device.apns_token, {
      title: "What shrank this week",
      body: digestBody(mine),
      kind: "digest",
      collapseId: "digest",
    });
    if (sendResult.ok) result.pushes += 1;
    if (sendResult.invalidToken) {
      await env.DB.prepare("UPDATE devices SET apns_token = NULL WHERE id = ?").bind(device.id).run();
      result.cleared += 1;
    }
  }

  return result;
}
```

- [ ] **Step 4: Dispatch the third cron**

`backend/src/worker.ts` — add the import and the case:

```ts
import { runWeeklyDigest } from "./digest";
```

```ts
      case "0 1 * * 1":
        ctx.waitUntil(runWeeklyDigest(env));
        break;
```

`backend/wrangler.toml`:

```toml
[triggers]
crons = ["*/5 * * * *", "0 */6 * * *", "0 1 * * 1"]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/digest.test.ts && npx tsc --noEmit`
Expected: `9 passed`; typecheck clean.

- [ ] **Step 6: Run the whole backend suite**

Run: `cd backend && npx vitest run && npm run check:trending`
Expected: every suite green; the trending copy is identical to `data/trending.json`.

- [ ] **Step 7: Commit**

```bash
git add backend/src/digest.ts backend/src/worker.ts backend/wrangler.toml backend/test/digest.test.ts
git commit -m "feat(backend): weekly what-shrank digest cron"
```

---

### Task 10: Provision the APNs key, set the secrets, deploy and verify

**Files:**
- Modify: `backend/wrangler.toml` (only if `wrangler deploy` reports a cron or binding problem)
- No test file — this task is verified against the deployed Worker.

**Interfaces:**
- Consumes: everything Tasks 1–9 produced.
- Produces: a deployed Worker with three cron triggers, the APNs secrets set, and migration `0004` applied remotely.

- [ ] **Step 1: Create the APNs auth key (Apple Developer portal, manual)**

1. https://developer.apple.com/account → Certificates, Identifiers & Profiles → **Keys** → **+**.
2. Name it `Shrunk APNs`, tick **Apple Push Notifications service (APNs)**, Continue → Register.
3. Download `AuthKey_XXXXXXXXXX.p8` (**one download only**) and note:
   - the **Key ID** (the `XXXXXXXXXX` in the filename),
   - your **Team ID** (top right of the portal, also in Membership).
4. Confirm the App ID `com.shrunk.app` exists under **Identifiers** with **Push Notifications** capability enabled.

Store the `.p8` outside the repo (e.g. `~/keys/`). It must never be committed.

- [ ] **Step 2: Apply the migration and set the secrets**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler d1 migrations apply shrunk --remote

npx wrangler secret put APNS_KEY_P8      # paste the whole .p8 file including BEGIN/END lines, then Ctrl-D
npx wrangler secret put APNS_KEY_ID      # the 10-character key id
npx wrangler secret put APNS_TEAM_ID     # the 10-character team id
```

Mirror them into the git-ignored `backend/.dev.vars` for `wrangler dev` (a single-line PEM with `\n` escapes is fine there):

```
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=YYYYYYYYYY
APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\nMIG...\n-----END PRIVATE KEY-----\n"
```

`APNS_ENV` stays `"sandbox"` in `[vars]` for TestFlight/development builds; flip it to `"production"` in the same file when the App Store build ships.

- [ ] **Step 3: Deploy**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler deploy
```

Expected: the output lists the three schedules `*/5 * * * *`, `0 */6 * * *`, `0 1 * * 1`.

- [ ] **Step 4: Verify the endpoints against the deployed Worker**

```bash
BASE=https://shrunk-api.<your-subdomain>.workers.dev

curl -s "$BASE/v1/feed?category=Snacks" | head -c 400; echo

curl -s -X POST "$BASE/v1/devices" -H 'Content-Type: application/json' \
  -d '{"device_id":"6f9619ff-8b86-d011-b42d-00cf4fc964ff","location_id":"01400943","categories":["Snacks"],"watches":[{"gtin":"0052000133417","brand":"Gatorade","alert_enabled":true}]}'
# expected: {"ok":true,"pro":false}

curl -s -X POST "$BASE/v1/admin/verified-case" -H "Authorization: Bearer $ADMIN_SECRET" \
  -H 'Content-Type: application/json' -d '{"gtin":"0052000133417","brand":"Gatorade"}'
# expected: {"ok":true}
```

- [ ] **Step 5: Watch a cron run**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler tail --format pretty
```

Within five minutes a `scheduled` event for `*/5 * * * *` appears. The test device above is not Pro, so the drain marks the verified-case job sent with `sent_count = 0` and pushes nothing — confirm with:

```bash
npx wrangler d1 execute shrunk --remote --command \
  "SELECT kind, sent_at, sent_count FROM alert_jobs ORDER BY id DESC LIMIT 5"
```

- [ ] **Step 6: Clean up the probe rows**

```bash
npx wrangler d1 execute shrunk --remote --command \
  "DELETE FROM watches WHERE device_id = '6f9619ff-8b86-d011-b42d-00cf4fc964ff'; DELETE FROM devices WHERE id = '6f9619ff-8b86-d011-b42d-00cf4fc964ff'"
```

- [ ] **Step 7: Commit any wrangler.toml fix**

```bash
git add backend/wrangler.toml
git commit -m "chore(backend): deploy phase 4 crons and push secrets"
```

(If nothing changed, skip the commit.)

---

### Task 11: iOS device-sync payload — one device id, per-kind prefs, `syncDevice`

**Files:**
- Create: `Shrunk/Models/GroceryCategory+Feed.swift`
- Modify: `Shrunk/Services/DeviceIdentity.swift`
- Modify: `Shrunk/Services/ShrunkAPIClient.swift`
- Modify: `Shrunk/Services/DataProviders.swift`
- Modify: `Shrunk/Models/NotificationPreferences.swift`
- Create: `ShrunkTests/TestHTTPHelpers.swift`
- Create: `ShrunkTests/DeviceRegistrationTests.swift`

**Interfaces:**
- Consumes: `POST /v1/devices` (Task 2); `ShrunkAPIClient.init(baseURL:session:)` and `.deviceId` (Phases 1, 3); `OnboardingProfile.decoded(_:)` and `GroceryCategory` (existing); `@AppStorage("storeLocationId")` (Phase 3).
- Produces: `struct DeviceWatch: Encodable, Equatable, Sendable { let gtin: String; let brand: String; let alertEnabled: Bool }`, encoding `alert_enabled`.
- Produces: `ShrunkAPIClient.apnsTokenKey = "apnsToken"` and
  ```swift
  @discardableResult
  func syncDevice(deviceId: String, transactionJWS: String,
                  apnsToken: String? = nil, locationId: String? = nil,
                  categories: [String]? = nil, watches: [DeviceWatch]? = nil) async -> Bool
  ```
  — every parameter after `transactionJWS` defaults to `nil` and is read from local storage when nil; `watches: nil` omits the key so the server keeps the stored set; the method **never throws** and returns `true` on 2xx.
- Produces: `protocol WatchlistSyncing: Sendable` in `DataProviders.swift` with that six-parameter method, and `extension ShrunkAPIClient: WatchlistSyncing {}`.
- Produces: `GroceryCategory.feedCategory: String` — the backend's canonical category name.
- Produces: `NotificationPreferences.sizeDropEnabled / priceHikeEnabled / verifiedCaseEnabled / digestEnabled` (all default `true`, decoded with `decodeIfPresent` so stored JSON from earlier builds still loads) and `kindTogglePayload: [String: Bool]` — the `prefs` object `/v1/devices` stores. `paused` now also switches every server push off.
- Produces: `extension URLRequest { func bodyData() -> Data? }` in `ShrunkTests/TestHTTPHelpers.swift` (a `URLProtocol` stub sees `httpBodyStream`, never `httpBody`).
- Reconciles the device id: `DeviceIdentity.key` becomes `"shrunk.device_id"` — the key Phase 3's `ShrunkAPIClient.deviceId` already writes and the key Phase 5's `DeviceIdentity.storageKey` expects — and `ShrunkAPIClient.deviceId` now reads through `DeviceIdentity`, so there is exactly one per-install id. Any id minted by a Phase 2 build under `"device_id"` is abandoned; only local dev installs are affected.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/TestHTTPHelpers.swift`:

```swift
import Foundation

extension URLRequest {
    /// `URLProtocol` strips `httpBody` and hands the body over as a stream;
    /// this drains whichever one is present.
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

`ShrunkTests/DeviceRegistrationTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class NotificationPreferenceToggleTests: XCTestCase {
    func test_newTogglesDefaultToOn() {
        let prefs = NotificationPreferences.default
        XCTAssertTrue(prefs.sizeDropEnabled)
        XCTAssertTrue(prefs.priceHikeEnabled)
        XCTAssertTrue(prefs.verifiedCaseEnabled)
        XCTAssertTrue(prefs.digestEnabled)
    }

    func test_decodesLegacyJSONWithoutTheNewKeys() {
        let legacy = #"{"paused":false,"quietHoursEnabled":false,"quietHoursStartHour":22,"quietHoursEndHour":8,"minimumShrinkPercent":0.03}"#
        let prefs = NotificationPreferences.decoded(legacy)
        XCTAssertTrue(prefs.sizeDropEnabled)
        XCTAssertTrue(prefs.digestEnabled)
        XCTAssertFalse(prefs.paused)
    }

    func test_roundTripsTheNewToggles() {
        var prefs = NotificationPreferences.default
        prefs.digestEnabled = false
        XCTAssertFalse(NotificationPreferences.decoded(prefs.encoded()).digestEnabled)
    }

    func test_kindTogglePayloadMatchesTheWireNames() {
        var prefs = NotificationPreferences.default
        prefs.priceHikeEnabled = false
        XCTAssertEqual(prefs.kindTogglePayload,
                       ["sizeDrop": true, "priceHike": false, "verifiedCase": true, "digest": true])
    }

    func test_pauseSilencesEveryServerPush() {
        var prefs = NotificationPreferences.default
        prefs.paused = true
        XCTAssertEqual(prefs.kindTogglePayload,
                       ["sizeDrop": false, "priceHike": false, "verifiedCase": false, "digest": false])
    }
}

final class GroceryCategoryFeedTests: XCTestCase {
    func test_mapsEveryCategoryToTheBackendName() {
        XCTAssertEqual(GroceryCategory.snacks.feedCategory, "Snacks")
        XCTAssertEqual(GroceryCategory.drinks.feedCategory, "Beverages")
        XCTAssertEqual(GroceryCategory.dairy.feedCategory, "Dairy")
        XCTAssertEqual(GroceryCategory.cleaning.feedCategory, "Cleaning")
        XCTAssertEqual(GroceryCategory.personal.feedCategory, "Personal care")
        XCTAssertEqual(GroceryCategory.paper.feedCategory, "Paper products")
    }
}

/// Named for Phase 4 so it cannot collide with the `DeviceIdentityTests` class
/// Phase 5's Task 5 adds to the same test target.
final class DeviceIdentityUnificationTests: XCTestCase {
    func test_deviceIdentityAndTheClientShareOneId() {
        UserDefaults.standard.removeObject(forKey: DeviceIdentity.key)
        let minted = DeviceIdentity.current
        XCTAssertNotNil(UUID(uuidString: minted))
        XCTAssertEqual(DeviceIdentity.key, "shrunk.device_id")
        XCTAssertEqual(ShrunkAPIClient.deviceId, minted)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "shrunk.device_id"), minted)
    }
}

/// Likewise named for Phase 4: Phase 5's Task 5 adds a `SyncDeviceTests`.
final class DeviceSyncPayloadTests: XCTestCase {
    private var client: ShrunkAPIClient!
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = ShrunkAPIClient(baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
        defaults.removeObject(forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.removeObject(forKey: "storeLocationId")
        defaults.removeObject(forKey: "shrunk.onboarding_profile")
        defaults.removeObject(forKey: NotificationPreferences.appStorageKey)
    }

    override func tearDown() {
        defaults.removeObject(forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.removeObject(forKey: "storeLocationId")
        defaults.removeObject(forKey: "shrunk.onboarding_profile")
        defaults.removeObject(forKey: NotificationPreferences.appStorageKey)
        super.tearDown()
    }

    /// Captures the one request the stub sees.
    private final class Captured: @unchecked Sendable {
        var url: String?
        var method: String?
        var body: [String: Any]?
    }

    private func capture(status: Int = 200) -> Captured {
        let captured = Captured()
        StubURLProtocol.handler = { request in
            captured.url = request.url?.absoluteString
            captured.method = request.httpMethod
            if let data = request.bodyData() {
                captured.body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            return (status, Data(#"{"ok":true,"pro":false}"#.utf8))
        }
        return captured
    }

    func test_syncDevice_postsEverythingItWasGiven() async {
        let captured = capture()

        let ok = await client.syncDevice(
            deviceId: "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
            transactionJWS: "aaa.bbb.ccc",
            apnsToken: "a1b2c3",
            locationId: "01400943",
            categories: ["Snacks", "Beverages"],
            watches: [DeviceWatch(gtin: "0052000133417", brand: "Gatorade", alertEnabled: true)]
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(captured.url, "https://api.test/v1/devices")
        XCTAssertEqual(captured.method, "POST")

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["device_id"] as? String, "6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        XCTAssertEqual(body["transaction_jws"] as? String, "aaa.bbb.ccc")
        XCTAssertEqual(body["apns_token"] as? String, "a1b2c3")
        XCTAssertEqual(body["location_id"] as? String, "01400943")
        XCTAssertEqual(body["categories"] as? [String], ["Snacks", "Beverages"])
        XCTAssertEqual(body["prefs"] as? [String: Bool],
                       ["sizeDrop": true, "priceHike": true, "verifiedCase": true, "digest": true])

        let watches = try! XCTUnwrap(body["watches"] as? [[String: Any]])
        XCTAssertEqual(watches.count, 1)
        XCTAssertEqual(watches[0]["gtin"] as? String, "0052000133417")
        XCTAssertEqual(watches[0]["brand"] as? String, "Gatorade")
        XCTAssertEqual(watches[0]["alert_enabled"] as? Bool, true)
    }

    func test_syncDevice_isCallableWithJustTheTwoPhase5Arguments() async {
        let captured = capture()
        let ok = await client.syncDevice(deviceId: "device-1", transactionJWS: "aaa.bbb.ccc")
        XCTAssertTrue(ok)

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["device_id"] as? String, "device-1")
        XCTAssertEqual(body["transaction_jws"] as? String, "aaa.bbb.ccc")
        XCTAssertNil(body["watches"], "an omitted watch list must not clear the server's copy")
    }

    func test_syncDevice_fillsTheGapsFromLocalStorage() async {
        defaults.set("cafe01", forKey: ShrunkAPIClient.apnsTokenKey)
        defaults.set("01400943", forKey: "storeLocationId")
        var profile = OnboardingProfile.empty
        profile.categories = [.drinks, .snacks]
        defaults.set(profile.encoded(), forKey: "shrunk.onboarding_profile")
        var prefs = NotificationPreferences.default
        prefs.digestEnabled = false
        defaults.set(prefs.encoded(), forKey: NotificationPreferences.appStorageKey)

        let captured = capture()
        await client.syncDevice(deviceId: "device-1", transactionJWS: "")

        let body = try! XCTUnwrap(captured.body)
        XCTAssertEqual(body["apns_token"] as? String, "cafe01")
        XCTAssertEqual(body["location_id"] as? String, "01400943")
        XCTAssertEqual(body["categories"] as? [String], ["Beverages", "Snacks"])
        XCTAssertEqual((body["prefs"] as? [String: Bool])?["digest"], false)
        XCTAssertNil(body["transaction_jws"], "an empty JWS is omitted, not sent as \"\"")
    }

    func test_syncDevice_sendsAnEmptyWatchListWhenAsked() async {
        let captured = capture()
        await client.syncDevice(deviceId: "device-1", transactionJWS: "", watches: [])
        XCTAssertEqual((try! XCTUnwrap(captured.body))["watches"] as? [[String: Any]], [])
    }

    func test_syncDevice_returnsFalseAndNeverThrowsOnFailure() async {
        _ = capture(status: 500)
        let ok = await client.syncDevice(deviceId: "device-1", transactionJWS: "")
        XCTAssertFalse(ok)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/DeviceSyncPayloadTests -quiet 2>&1 | tail -30
```
Expected: compile errors — `value of type 'ShrunkAPIClient' has no member 'syncDevice'`, `cannot find 'DeviceWatch' in scope`.

- [ ] **Step 3: Unify the device id**

Replace `Shrunk/Services/DeviceIdentity.swift` entirely:

```swift
import Foundation

/// The stable per-install id. It is the `device_id` sent to `/v1/devices`, the
/// `X-Device-Id` header on every proxied call, and (from Phase 5) the
/// `appAccountToken` handed to StoreKit — one value, minted once.
enum DeviceIdentity {
    static let key = "shrunk.device_id"

    /// Reads the stored id, minting one on first use. Deliberately not cached
    /// in a `static let`: a test that clears the key must get a fresh mint.
    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
```

In `Shrunk/Services/ShrunkAPIClient.swift`, replace Phase 3's `static let deviceId: String = { ... }()` block with:

```swift
    /// Stable per-install id, tied to no account (spec §6.6).
    static var deviceId: String { DeviceIdentity.current }

    /// `@AppStorage` key holding the APNs device token as lowercase hex.
    static let apnsTokenKey = "apnsToken"
```

- [ ] **Step 4: Add the category mapping**

`Shrunk/Models/GroceryCategory+Feed.swift`:

```swift
import Foundation

extension GroceryCategory {
    /// The category name the backend uses in `products.category`, `/v1/feed`
    /// and the weekly digest. The app's own titles are shorter ("Drinks",
    /// "Personal"); the Worker canonicalises both spellings onto these.
    var feedCategory: String {
        switch self {
        case .snacks:   return "Snacks"
        case .drinks:   return "Beverages"
        case .dairy:    return "Dairy"
        case .cleaning: return "Cleaning"
        case .personal: return "Personal care"
        case .paper:    return "Paper products"
        }
    }
}
```

- [ ] **Step 5: Add the per-kind toggles**

In `Shrunk/Models/NotificationPreferences.swift`, add the four stored properties after `minimumShrinkPercent`, update `.default`, and add the decoder + payload. The `init(from:)` lives in an **extension** so the memberwise initializer survives:

```swift
struct NotificationPreferences: Codable, Equatable {
    var paused: Bool
    var quietHoursEnabled: Bool
    var quietHoursStartHour: Int   // 0..23
    var quietHoursEndHour: Int     // 0..23
    var minimumShrinkPercent: Double  // 0...1, threshold below which we don't fire

    // Per-kind switches for the server-sent alerts (spec §3, §6.2).
    var sizeDropEnabled: Bool = true
    var priceHikeEnabled: Bool = true
    var verifiedCaseEnabled: Bool = true
    var digestEnabled: Bool = true

    static let `default` = NotificationPreferences(
        paused: false,
        quietHoursEnabled: false,
        quietHoursStartHour: 22,
        quietHoursEndHour: 8,
        minimumShrinkPercent: 0.03,   // ignore anything under 3% — likely noise
        sizeDropEnabled: true,
        priceHikeEnabled: true,
        verifiedCaseEnabled: true,
        digestEnabled: true
    )
```

Append to the same file:

```swift
extension NotificationPreferences {
    /// Hand-written so preferences saved by an earlier build — which have none
    /// of the per-kind keys — still decode, with every kind on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        quietHoursStartHour = try container.decodeIfPresent(Int.self, forKey: .quietHoursStartHour) ?? 22
        quietHoursEndHour = try container.decodeIfPresent(Int.self, forKey: .quietHoursEndHour) ?? 8
        minimumShrinkPercent = try container.decodeIfPresent(Double.self, forKey: .minimumShrinkPercent) ?? 0.03
        sizeDropEnabled = try container.decodeIfPresent(Bool.self, forKey: .sizeDropEnabled) ?? true
        priceHikeEnabled = try container.decodeIfPresent(Bool.self, forKey: .priceHikeEnabled) ?? true
        verifiedCaseEnabled = try container.decodeIfPresent(Bool.self, forKey: .verifiedCaseEnabled) ?? true
        digestEnabled = try container.decodeIfPresent(Bool.self, forKey: .digestEnabled) ?? true
    }

    /// The `prefs` object `POST /v1/devices` stores, keyed by the Worker's wire
    /// kind names. "Pause all alerts" switches every server push off too.
    var kindTogglePayload: [String: Bool] {
        [
            "sizeDrop": sizeDropEnabled && !paused,
            "priceHike": priceHikeEnabled && !paused,
            "verifiedCase": verifiedCaseEnabled && !paused,
            "digest": digestEnabled && !paused,
        ]
    }
}
```

- [ ] **Step 6: Add `DeviceWatch` and `syncDevice`**

Append to `Shrunk/Services/ShrunkAPIClient.swift`, inside the `actor ShrunkAPIClient` body:

```swift
    /// Upserts this device on the Worker (spec §6.1). Never throws — a failed
    /// sync must not disturb the UI (spec §8). Every parameter after
    /// `transactionJWS` is read from local storage when left nil; `watches: nil`
    /// omits the key entirely so the server keeps the set it already has.
    @discardableResult
    func syncDevice(
        deviceId: String,
        transactionJWS: String,
        apnsToken: String? = nil,
        locationId: String? = nil,
        categories: [String]? = nil,
        watches: [DeviceWatch]? = nil
    ) async -> Bool {
        let defaults = UserDefaults.standard
        let resolvedToken = apnsToken ?? defaults.string(forKey: Self.apnsTokenKey)
        let resolvedLocation = locationId ?? defaults.string(forKey: "storeLocationId")
        let resolvedCategories = categories ?? OnboardingProfile
            .decoded(defaults.string(forKey: "shrunk.onboarding_profile") ?? "{}")
            .categories
            .map(\.feedCategory)
            .sorted()
        let prefs = NotificationPreferences
            .decoded(defaults.string(forKey: NotificationPreferences.appStorageKey) ?? "{}")
            .kindTogglePayload

        let body = DeviceSyncBody(
            deviceId: deviceId,
            apnsToken: resolvedToken?.isEmpty == false ? resolvedToken : nil,
            locationId: resolvedLocation?.isEmpty == false ? resolvedLocation : nil,
            categories: resolvedCategories.isEmpty ? nil : resolvedCategories,
            prefs: prefs,
            watches: watches,
            transactionJWS: transactionJWS.isEmpty ? nil : transactionJWS
        )

        var request = URLRequest(url: baseURL.appending(path: "v1/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.deviceId, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200...299).contains(status)
        } catch {
            return false
        }
    }
```

Append at file scope (below `ProductDTO`):

```swift
// MARK: - Device sync wire format

/// One watched product as `POST /v1/devices` expects it.
struct DeviceWatch: Encodable, Equatable, Sendable {
    let gtin: String
    let brand: String
    let alertEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case gtin, brand
        case alertEnabled = "alert_enabled"
    }
}

/// Optional fields are dropped by the encoder when nil, which is exactly the
/// "leave this alone" semantics the Worker implements.
private struct DeviceSyncBody: Encodable {
    let deviceId: String
    let apnsToken: String?
    let locationId: String?
    let categories: [String]?
    let prefs: [String: Bool]?
    let watches: [DeviceWatch]?
    let transactionJWS: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case apnsToken = "apns_token"
        case locationId = "location_id"
        case categories
        case prefs
        case watches
        case transactionJWS = "transaction_jws"
    }
}
```

- [ ] **Step 7: Add the sync seam**

Append to `Shrunk/Services/DataProviders.swift`:

```swift
/// The device-upsert seam used by the watchlist. Phase 5 adds its own
/// two-argument `DeviceSyncing` protocol on top of the same method.
protocol WatchlistSyncing: Sendable {
    @discardableResult
    func syncDevice(
        deviceId: String,
        transactionJWS: String,
        apnsToken: String?,
        locationId: String?,
        categories: [String]?,
        watches: [DeviceWatch]?
    ) async -> Bool
}

extension ShrunkAPIClient: WatchlistSyncing {}
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests -quiet 2>&1 | tail -30
```
Expected: the whole `ShrunkTests` bundle passes, including the 14 new assertions in `DeviceRegistrationTests`.

- [ ] **Step 9: Commit**

```bash
git add Shrunk/Models/GroceryCategory+Feed.swift Shrunk/Models/NotificationPreferences.swift Shrunk/Services/DeviceIdentity.swift Shrunk/Services/ShrunkAPIClient.swift Shrunk/Services/DataProviders.swift ShrunkTests/TestHTTPHelpers.swift ShrunkTests/DeviceRegistrationTests.swift Shrunk.xcodeproj
git commit -m "feat(ios): device sync payload — one device id, per-kind prefs, syncDevice"
```

---

### Task 12: Per-kind notification toggles in Settings

**Files:**
- Modify: `Shrunk/Features/Settings/NotificationPreferencesView.swift`

**Interfaces:**
- Consumes: `NotificationPreferences.sizeDropEnabled/priceHikeEnabled/verifiedCaseEnabled/digestEnabled` and `preferenceToggle(title:subtitle:icon:tint:isOn:)` (existing private helper); `ShrunkAPIClient.syncDevice` and `.deviceId` (Task 11).
- Produces: no new types. Changing any preference now also pushes the new `prefs` object to the Worker, so the crons stop sending what the user switched off.

- [ ] **Step 1: Add the card**

In `Shrunk/Features/Settings/NotificationPreferencesView.swift`, add `alertKindsCard` to the `VStack` between `masterControlsCard` and `quietHoursCard`:

```swift
                    iosAuthorizationCard
                    masterControlsCard
                    alertKindsCard
                    quietHoursCard
```

and add the card itself next to the other card properties:

```swift
    // MARK: - Alert kinds

    private var alertKindsCard: some View {
        VStack(spacing: 0) {
            preferenceToggle(
                title: "Size drops",
                subtitle: "A product you watch got smaller.",
                icon: "arrow.down.right.circle.fill",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.sizeDropEnabled }, set: { prefs.sizeDropEnabled = $0 })
            )
            Divider().overlay(Color.borderSoft)
            preferenceToggle(
                title: "Price per unit up",
                subtitle: "Up 5% or more at your store.",
                icon: "chart.line.uptrend.xyaxis",
                tint: .verdictWarn,
                isOn: Binding(get: { prefs.priceHikeEnabled }, set: { prefs.priceHikeEnabled = $0 })
            )
            Divider().overlay(Color.borderSoft)
            preferenceToggle(
                title: "Verified cases",
                subtitle: "We publish a confirmed shrink for something you watch.",
                icon: "checkmark.seal.fill",
                tint: .verdictGood,
                isOn: Binding(get: { prefs.verifiedCaseEnabled }, set: { prefs.verifiedCaseEnabled = $0 })
            )
            Divider().overlay(Color.borderSoft)
            preferenceToggle(
                title: "Weekly digest",
                subtitle: "Monday summary of what shrank in your categories.",
                icon: "calendar",
                tint: .shrunkRed,
                isOn: Binding(get: { prefs.digestEnabled }, set: { prefs.digestEnabled = $0 })
            )
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                .stroke(Color.borderSoft, lineWidth: 0.5)
        )
        .shrunkElevation(ShrunkTheme.Elevation.whisper)
    }
```

- [ ] **Step 2: Push the change to the Worker**

Replace the existing `.onChange(of: prefs)` modifier with:

```swift
        .onChange(of: prefs) { _, newValue in
            rawPrefs = newValue.encoded()
            // The crons read `devices.prefs`, so the switch has to reach the
            // Worker or it only silences local notifications.
            Task {
                await ShrunkAPIClient.shared.syncDevice(
                    deviceId: ShrunkAPIClient.deviceId,
                    transactionJWS: ""
                )
            }
        }
```

- [ ] **Step 3: Build and run the suite**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Check it by hand**

Run the app, open Settings → Notifications, toggle "Weekly digest" off, and confirm with `npx wrangler tail` (or a local `wrangler dev`) that a `POST /v1/devices` arrives whose `prefs.digest` is `false`.

- [ ] **Step 5: Commit**

```bash
git add Shrunk/Features/Settings/NotificationPreferencesView.swift
git commit -m "feat(ios): per-kind alert toggles in Settings, synced to the Worker"
```

---

### Task 13: New alert kinds in the Alerts feed

**Files:**
- Modify: `Shrunk/Models/ShrinkAlert.swift`
- Modify: `Shrunk/Features/Alerts/AlertRow.swift`
- Modify: `Shrunk/Features/Alerts/AlertsViewModel.swift`
- Modify: `Shrunk/Features/Alerts/AlertsFeedView.swift`
- Create: `ShrunkTests/PushAlertTests.swift`

**Interfaces:**
- Produces: `ShrinkAlert.Kind` gains `sizeDrop`, `priceHike`, `verifiedCase`, `digest` (spec §7), plus `Kind.isConfirmedShrink: Bool` (`newShrink`, `sizeDrop`, `verifiedCase`).
- Produces: `ShrinkAlert.message: String?` — the push body, stored verbatim — and `headline: String`, which prefers `message` and otherwise falls back to per-kind copy. `AlertRow` renders `alert.headline`.
- Produces: `static func ShrinkAlert.from(pushUserInfo: [AnyHashable: Any]) -> ShrinkAlert?` — reads `kind` and `gtin` from the payload root and title/body from `aps.alert`; returns nil for a missing or unknown kind.
- Produces: `static func ShrinkAlert.unconfirmed(from: WatchedProduct, liveQuantity: Double) -> ShrinkAlert` (used by Task 15).
- `message` is a new optional property on a SwiftData `@Model`, which SwiftData migrates automatically; the new `init` parameter is last, so every existing call site still compiles.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/PushAlertTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class ShrinkAlertKindTests: XCTestCase {
    private func alert(_ kind: ShrinkAlert.Kind, message: String? = nil) -> ShrinkAlert {
        ShrinkAlert(barcode: "0052000133417", productName: "Gatorade Thirst Quencher", brand: "Gatorade",
                    kind: kind, message: message)
    }

    func test_everyKindHasCopy() {
        XCTAssertEqual(alert(.sizeDrop).headline, "Gatorade just shrank — tap to see the new size.")
        XCTAssertEqual(alert(.priceHike).headline, "Gatorade costs more per unit at your store.")
        XCTAssertEqual(alert(.verifiedCase).headline, "We published a verified case for Gatorade.")
        XCTAssertEqual(alert(.digest).headline, "Your weekly shrink digest is ready.")
        XCTAssertEqual(alert(.unconfirmed).headline, "Possible size change in Gatorade — scan to confirm.")
        XCTAssertEqual(alert(.stable).headline, "Gatorade unchanged — still watching.")
        XCTAssertEqual(alert(.newShrink).headline, "Confirmed shrink. Tap to see details.")
    }

    func test_theServersOwnWordsWin() {
        XCTAssertEqual(alert(.digest, message: "3 new shrinks in Snacks, 1 in Dairy").headline,
                       "3 new shrinks in Snacks, 1 in Dairy")
    }

    func test_confirmedShrinkKinds() {
        XCTAssertTrue(ShrinkAlert.Kind.newShrink.isConfirmedShrink)
        XCTAssertTrue(ShrinkAlert.Kind.sizeDrop.isConfirmedShrink)
        XCTAssertTrue(ShrinkAlert.Kind.verifiedCase.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.priceHike.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.digest.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.unconfirmed.isConfirmedShrink)
        XCTAssertFalse(ShrinkAlert.Kind.stable.isConfirmedShrink)
    }
}

final class ShrinkAlertFromPushTests: XCTestCase {
    private func payload(kind: String, gtin: String?, title: String, body: String) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "kind": kind,
            "aps": ["alert": ["title": title, "body": body], "sound": "default"],
        ]
        if let gtin { userInfo["gtin"] = gtin }
        return userInfo
    }

    func test_mapsASizeDropPush() throws {
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: payload(
            kind: "sizeDrop", gtin: "0052000133417",
            title: "Gatorade Thirst Quencher just shrank",
            body: "Now 28 fl oz — was 32 fl oz. Tap to see the history."
        )))
        XCTAssertEqual(alert.kind, .sizeDrop)
        XCTAssertEqual(alert.barcode, "0052000133417")
        XCTAssertEqual(alert.productName, "Gatorade Thirst Quencher")
        XCTAssertEqual(alert.headline, "Now 28 fl oz — was 32 fl oz. Tap to see the history.")
        XCTAssertFalse(alert.isRead)
    }

    func test_aDigestPushHasNoBarcode() throws {
        let alert = try XCTUnwrap(ShrinkAlert.from(pushUserInfo: payload(
            kind: "digest", gtin: nil, title: "What shrank this week", body: "3 new shrinks in Snacks"
        )))
        XCTAssertEqual(alert.kind, .digest)
        XCTAssertEqual(alert.barcode, "")
    }

    func test_rejectsAPayloadWeDoNotUnderstand() {
        XCTAssertNil(ShrinkAlert.from(pushUserInfo: ["aps": ["alert": ["title": "hi"]]]))
        XCTAssertNil(ShrinkAlert.from(pushUserInfo: payload(kind: "somethingElse", gtin: "1", title: "t", body: "b")))
    }

    func test_unconfirmedFactoryDescribesTheMismatch() {
        let watched = WatchedProduct(barcode: "0052000133417", productName: "Gatorade Thirst Quencher",
                                     brand: "Gatorade", lastKnownSize: 946.353, lastKnownUnit: "ml")
        let alert = ShrinkAlert.unconfirmed(from: watched, liveQuantity: 828.058)
        XCTAssertEqual(alert.kind, .unconfirmed)
        XCTAssertEqual(alert.barcode, "0052000133417")
        XCTAssertEqual(alert.previousQuantity, 946.353)
        XCTAssertEqual(alert.currentQuantity, 828.058)
        XCTAssertEqual(alert.shrinkPercent, (828.058 - 946.353) / 946.353, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/ShrinkAlertKindTests -quiet 2>&1 | tail -30
```
Expected: compile errors — `type 'ShrinkAlert.Kind' has no member 'sizeDrop'`.

- [ ] **Step 3: Extend the model**

In `Shrunk/Models/ShrinkAlert.swift`: add the stored property, the init parameter, the new cases, and the copy.

Add after `var isRead: Bool`:

```swift
    /// The push body, kept verbatim so the feed shows exactly what we sent.
    var message: String?
```

Add as the **last** parameter of `init` (so existing call sites still compile) and assign it:

```swift
        isRead: Bool = false,
        message: String? = nil
    ) {
```

```swift
        self.isRead = isRead
        self.message = message
    }
```

Replace the `Kind` enum and add the copy:

```swift
    enum Kind: String, Codable, CaseIterable {
        case newShrink     // confirmed shrinkage just detected on device
        case unconfirmed   // possible change, needs user re-scan
        case stable        // no change since last check
        case sizeDrop      // push: a watched product got smaller (spec §3)
        case priceHike     // push: per-unit price up >= 5% at the user's store
        case verifiedCase  // push: we published a verified case for it
        case digest        // push: the Monday "what shrank this week" summary

        /// Kinds that mean "this really did shrink" — the Confirmed filter.
        var isConfirmedShrink: Bool {
            switch self {
            case .newShrink, .sizeDrop, .verifiedCase: return true
            case .unconfirmed, .stable, .priceHike, .digest: return false
            }
        }
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .stable }

    /// What the row says. A push carries its own copy; anything produced on
    /// device falls back to the per-kind wording below.
    var headline: String {
        if let message, !message.isEmpty { return message }
        let label = brand.isEmpty ? productName : brand
        switch kind {
        case .newShrink:
            if let prevQ = previousQuantity, let prevU = previousUnit,
               let currQ = currentQuantity, let currU = currentUnit {
                return "\(label) just shrank — \(prevQ.formattedQuantity(unit: prevU)) → \(currQ.formattedQuantity(unit: currU))"
            }
            return "Confirmed shrink. Tap to see details."
        case .unconfirmed:  return "Possible size change in \(label) — scan to confirm."
        case .stable:       return "\(label) unchanged — still watching."
        case .sizeDrop:     return "\(label) just shrank — tap to see the new size."
        case .priceHike:    return "\(label) costs more per unit at your store."
        case .verifiedCase: return "We published a verified case for \(label)."
        case .digest:       return "Your weekly shrink digest is ready."
        }
    }
```

Add the two factories to the existing `extension ShrinkAlert`:

```swift
    /// Builds a feed row from a remote-notification payload. `kind` is the
    /// Worker's camelCase alert kind; `gtin` is absent on the weekly digest.
    static func from(pushUserInfo userInfo: [AnyHashable: Any]) -> ShrinkAlert? {
        guard let rawKind = userInfo["kind"] as? String, let kind = Kind(rawValue: rawKind) else { return nil }
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let alert = aps?["alert"] as? [AnyHashable: Any]
        let title = (alert?["title"] as? String) ?? ""
        let body = (alert?["body"] as? String) ?? ""

        return ShrinkAlert(
            barcode: (userInfo["gtin"] as? String) ?? "",
            productName: title.isEmpty ? "Shrunk" : title,
            brand: "",
            kind: kind,
            message: body
        )
    }

    /// The device-side `BGAppRefresh` check found a live size that disagrees
    /// with the last one we recorded (spec §7).
    static func unconfirmed(from watched: WatchedProduct, liveQuantity: Double) -> ShrinkAlert {
        ShrinkAlert(
            barcode: watched.barcode,
            productName: watched.productName,
            brand: watched.brand,
            kind: .unconfirmed,
            previousQuantity: watched.lastKnownSize,
            previousUnit: watched.lastKnownUnit,
            currentQuantity: liveQuantity,
            currentUnit: watched.lastKnownUnit,
            shrinkPercent: watched.lastKnownSize > 0 ? (liveQuantity - watched.lastKnownSize) / watched.lastKnownSize : 0
        )
    }
```

- [ ] **Step 4: Teach the row about the new kinds**

In `Shrunk/Features/Alerts/AlertRow.swift`, delete the private `headline` property and use the model's. Replace the four switches:

```swift
                if alert.kind.isConfirmedShrink, alert.shrinkPercent != 0 {
```

```swift
                    Text(alert.headline)
```

```swift
    private var glyphSymbol: String {
        switch alert.kind {
        case .newShrink, .sizeDrop: return "exclamationmark.triangle.fill"
        case .unconfirmed:          return "questionmark"
        case .stable:               return "checkmark"
        case .priceHike:            return "chart.line.uptrend.xyaxis"
        case .verifiedCase:         return "checkmark.seal.fill"
        case .digest:               return "calendar"
        }
    }

    private var dotColor: Color {
        switch alert.kind {
        case .newShrink, .sizeDrop:      return .shrunkRed
        case .unconfirmed, .priceHike:   return .verdictWarn
        case .stable, .verifiedCase:     return .verdictGood
        case .digest:                    return .shrunkRed
        }
    }

    private var borderColor: Color {
        switch alert.kind {
        case .newShrink, .sizeDrop:    return .shrunkRed.opacity(0.35)
        case .unconfirmed, .priceHike: return .verdictWarn.opacity(0.25)
        case .stable, .verifiedCase, .digest: return .borderSoft
        }
    }

    private var borderWidth: CGFloat {
        alert.kind.isConfirmedShrink ? 1.5 : 0.5
    }
```

- [ ] **Step 5: Teach the filters and the feed about them**

In `Shrunk/Features/Alerts/AlertsViewModel.swift`, replace `filtered(_:)`:

```swift
    func filtered(_ alerts: [ShrinkAlert]) -> [ShrinkAlert] {
        switch selectedFilter {
        case .all:       return alerts
        case .new:       return alerts.filter { !$0.isRead }
        case .confirmed: return alerts.filter { $0.kind.isConfirmedShrink }
        case .watching:  return alerts.filter { !$0.kind.isConfirmedShrink }
        }
    }
```

and widen the savings roll-up the same way:

```swift
            .filter { $0.kind.isConfirmedShrink }
```

In `Shrunk/Features/Alerts/AlertsFeedView.swift`, a digest row has no product to open:

```swift
                        AlertRow(alert: alert) {
                            vm?.markRead(alert)
                            if !alert.barcode.isEmpty {
                                vm?.presentedBarcode = alert.barcode
                            }
                        }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: all tests pass, including the 7 new ones.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Models/ShrinkAlert.swift Shrunk/Features/Alerts ShrunkTests/PushAlertTests.swift
git commit -m "feat(ios): sizeDrop, priceHike, verifiedCase and digest alert kinds"
```

---

### Task 14: Remote-notification registration, delivery and tap routing

**Files:**
- Create: `Shrunk/Shrunk.entitlements`
- Create: `Shrunk/Services/AppDelegate.swift`
- Create: `Shrunk/Services/PushInbox.swift`
- Modify: `Shrunk/Resources/Info.plist`
- Modify: `project.yml`
- Modify: `Shrunk/Services/NotificationScheduler.swift`
- Modify: `Shrunk/ShrunkApp.swift`
- Modify: `Shrunk/Features/Watchlist/WatchlistView.swift` (the existing `.task` block only)
- Create: `ShrunkTests/PushInboxTests.swift`

**Interfaces:**
- Consumes: `ShrinkAlert.from(pushUserInfo:)` (Task 13); `ShrunkAPIClient.syncDevice`, `.deviceId`, `.apnsTokenKey` (Task 11).
- Produces: `Shrunk/Shrunk.entitlements` with `aps-environment = development`, wired through `CODE_SIGN_ENTITLEMENTS` in `project.yml`; `UIBackgroundModes` gains `remote-notification`.
- Produces: `enum PushRegistration { static func hexString(from token: Data) -> String }`.
- Produces: `@MainActor @Observable final class PushInbox` with `static let shared`, `var container: ModelContainer?`, `var pendingBarcode: String?`, `@discardableResult func record(userInfo:) -> ShrinkAlert?` (deduplicated per process by kind + gtin + copy), and `func open(userInfo:)`.
- Produces: `final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate` — registers for remote notifications on every launch, stores the hex token in `@AppStorage("apnsToken")`, syncs the device, records foreground/background/tapped pushes, and routes a tap to the product.
- Produces: `NotificationScheduler.requestPermissionAndRegister() async -> Bool`; `scheduleShrinkAlert(productName:brand:record:barcode:)` is replaced by `scheduleLocalAlert(title:body:barcode:)`.
- `RootView` presents `ResultView(barcode:)` for `PushInbox.shared.pendingBarcode`.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/PushInboxTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Shrunk

final class PushRegistrationTests: XCTestCase {
    func test_deviceTokenBecomesLowercaseHex() {
        XCTAssertEqual(PushRegistration.hexString(from: Data([0x74, 0x0f, 0x47, 0xff])), "740f47ff")
        XCTAssertEqual(PushRegistration.hexString(from: Data()), "")
    }
}

@MainActor
final class PushInboxTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: WatchedProduct.self, ShrinkAlert.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        PushInbox.shared.container = container
        PushInbox.shared.pendingBarcode = nil
        PushInbox.shared.resetDeduplication()
    }

    private func payload(kind: String, gtin: String?, body: String) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "kind": kind,
            "aps": ["alert": ["title": "Gatorade just shrank", "body": body]],
        ]
        if let gtin { userInfo["gtin"] = gtin }
        return userInfo
    }

    private func storedAlerts() throws -> [ShrinkAlert] {
        try ModelContext(container).fetch(FetchDescriptor<ShrinkAlert>())
    }

    func test_recordWritesTheAlertIntoTheFeed() throws {
        PushInbox.shared.record(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz"))
        let alerts = try storedAlerts()
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sizeDrop)
        XCTAssertEqual(alerts[0].barcode, "0052000133417")
        XCTAssertEqual(alerts[0].headline, "Now 28 fl oz")
    }

    func test_theSamePushIsRecordedOnce() throws {
        let userInfo = payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz")
        PushInbox.shared.record(userInfo: userInfo)     // background wake
        PushInbox.shared.record(userInfo: userInfo)     // then the user taps it
        XCTAssertEqual(try storedAlerts().count, 1)
    }

    func test_aDifferentPushIsStillRecorded() throws {
        PushInbox.shared.record(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "Now 28 fl oz"))
        PushInbox.shared.record(userInfo: payload(kind: "priceHike", gtin: "0052000133417", body: "Now $2.10 per unit"))
        XCTAssertEqual(try storedAlerts().count, 2)
    }

    func test_ignoresAPayloadThatIsNotOurs() throws {
        PushInbox.shared.record(userInfo: ["aps": ["alert": "hello"]])
        XCTAssertEqual(try storedAlerts().count, 0)
    }

    func test_tappingAProductPushRoutesToIt() {
        PushInbox.shared.open(userInfo: payload(kind: "sizeDrop", gtin: "0052000133417", body: "b"))
        XCTAssertEqual(PushInbox.shared.pendingBarcode, "0052000133417")
    }

    func test_tappingTheDigestRoutesNowhere() {
        PushInbox.shared.open(userInfo: payload(kind: "digest", gtin: nil, body: "3 new shrinks in Snacks"))
        XCTAssertNil(PushInbox.shared.pendingBarcode)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/PushInboxTests -quiet 2>&1 | tail -30
```
Expected: `cannot find 'PushInbox' in scope`.

- [ ] **Step 3: Add the entitlement and the background mode**

`Shrunk/Shrunk.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
</dict>
</plist>
```

(`development` matches `APNS_ENV = "sandbox"`. Xcode rewrites it to `production` for App Store/TestFlight distribution builds; flip `APNS_ENV` at the same time.)

`project.yml` — add the setting to the `Shrunk` target and keep the entitlements file out of the copied resources:

```yaml
  Shrunk:
    type: application
    platform: iOS
    sources:
      - path: Shrunk
        excludes:
          - "**/*.md"
          - "**/*.entitlements"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.shrunk.app
        CODE_SIGN_ENTITLEMENTS: Shrunk/Shrunk.entitlements
```

(Add only the `- "**/*.entitlements"` exclude line and the `CODE_SIGN_ENTITLEMENTS` line; leave every other key in that target untouched.)

`Shrunk/Resources/Info.plist` — extend `UIBackgroundModes`:

```xml
    <key>UIBackgroundModes</key>
    <array>
        <string>fetch</string>
        <string>processing</string>
        <string>remote-notification</string>
    </array>
```

- [ ] **Step 4: Implement the inbox**

`Shrunk/Services/PushInbox.swift`:

```swift
import Foundation
import SwiftData
import Observation

/// Everything that arrives by push lands here: the alert is written into the
/// Alerts feed, and a tapped alert leaves a barcode for `RootView` to open
/// (spec §7).
@MainActor
@Observable
final class PushInbox {
    static let shared = PushInbox()

    /// Set by `ShrunkApp.init` so a push can be written from the app delegate.
    @ObservationIgnored var container: ModelContainer?

    /// Barcode a tapped push asked us to open; `RootView` consumes it.
    var pendingBarcode: String?

    /// iOS can hand us the same push twice — once to wake us in the background,
    /// once when the user taps it. The key is the payload, not the delivery.
    @ObservationIgnored private var seen = Set<String>()

    private init() {}

    @discardableResult
    func record(userInfo: [AnyHashable: Any]) -> ShrinkAlert? {
        guard let alert = ShrinkAlert.from(pushUserInfo: userInfo) else { return nil }
        let key = "\(alert.kindRaw)|\(alert.barcode)|\(alert.productName)|\(alert.message ?? "")"
        guard !seen.contains(key) else { return nil }
        seen.insert(key)

        guard let container else { return nil }
        let context = ModelContext(container)
        context.insert(alert)
        try? context.save()
        return alert
    }

    /// The user tapped a push. Digest pushes carry no product.
    func open(userInfo: [AnyHashable: Any]) {
        guard let gtin = userInfo["gtin"] as? String, !gtin.isEmpty else { return }
        pendingBarcode = gtin
    }

    /// Test seam: clears the per-process dedup window.
    func resetDeduplication() {
        seen.removeAll()
    }
}
```

- [ ] **Step 5: Implement the app delegate**

`Shrunk/Services/AppDelegate.swift`:

```swift
import UIKit
import UserNotifications

/// Owns APNs registration and delivery. Attached by `@UIApplicationDelegateAdaptor`
/// on `ShrunkApp`. `@MainActor` on the class means every callback can touch
/// `PushInbox` (also main-actor) directly, with no hops to get wrong.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Re-register every launch: iOS may rotate the token at any time, and
        // registering is a no-op until the user grants permission.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = PushRegistration.hexString(from: deviceToken)
        UserDefaults.standard.set(hex, forKey: ShrunkAPIClient.apnsTokenKey)
        Task {
            await ShrunkAPIClient.shared.syncDevice(
                deviceId: ShrunkAPIClient.deviceId,
                transactionJWS: "",
                apnsToken: hex
            )
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulators and unentitled builds land here. Everything else in the
        // app keeps working; we simply never receive a remote alert (spec §8).
    }

    /// Woken in the background by an alert push carrying `content-available`,
    /// so the row reaches the feed even if the banner is never tapped.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        PushInbox.shared.record(userInfo: userInfo) == nil ? .noData : .newData
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        PushInbox.shared.record(userInfo: notification.request.content.userInfo)
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        PushInbox.shared.record(userInfo: userInfo)
        PushInbox.shared.open(userInfo: userInfo)
    }
}

enum PushRegistration {
    /// APNs device token as lowercase hex — the form `/v1/devices` stores.
    static func hexString(from token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6: Register for permission and drop the record-shaped local alert**

In `Shrunk/Services/NotificationScheduler.swift`, add `import UIKit` at the top, add the registration helper next to `requestPermission()`:

```swift
    /// Asks for permission and, if granted, registers for APNs. The token
    /// arrives asynchronously in `AppDelegate`.
    @discardableResult
    func requestPermissionAndRegister() async -> Bool {
        let granted = await requestPermission()
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }
```

and replace `scheduleShrinkAlert(productName:brand:record:barcode:)` and its private `body(for:)` helper with:

```swift
    /// A local notification for something the device worked out by itself —
    /// today that is only the `BGAppRefresh` live-size mismatch (spec §7).
    func scheduleLocalAlert(title: String, body: String, barcode: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["barcode": barcode]
        content.threadIdentifier = "shrunk-watchlist"

        let request = UNNotificationRequest(
            identifier: "local_\(barcode)_\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil  // immediate
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
```

- [ ] **Step 7: Wire the delegate and the route into the app**

In `Shrunk/ShrunkApp.swift`, add `import UIKit` and:

```swift
@main
struct ShrunkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var storeKit = StoreKitService.shared
```

and, at the end of `init()` (after the `ModelContainer` is built, before `registerBackgroundTask`):

```swift
        // The app delegate writes pushes into this container.
        PushInbox.shared.container = modelContainer
```

Give `RootView` the push route:

```swift
struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabsView()
            } else {
                OnboardingContainerView {
                    hasCompletedOnboarding = true
                }
            }
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { PushInbox.shared.pendingBarcode.map { ScannedBarcode(id: $0) } },
            set: { PushInbox.shared.pendingBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
        }
    }
}
```

- [ ] **Step 8: Ask for permission at the moment it makes sense**

Nothing in the app calls `requestPermission()` today, so without this the whole
push path stays silent. The Watchlist tab is the Pro alerts surface — ask there,
not at launch. In `Shrunk/Features/Watchlist/WatchlistView.swift`, extend the
existing `.task` block:

```swift
        .task {
            if vm == nil {
                vm = WatchlistViewModel(service: WatchlistService(context: modelContext))
            }
            // Asking here rather than at launch: the user is looking at the
            // feature the permission is for. Already-answered prompts no-op.
            await NotificationScheduler.shared.requestPermissionAndRegister()
        }
```

- [ ] **Step 9: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: all tests pass. If the build fails with a code-signing error about `aps-environment`, confirm the App ID `com.shrunk.app` has the Push Notifications capability (Task 10, Step 1).

- [ ] **Step 10: Verify on a device**

APNs needs real hardware. On an iPhone with the app installed and notifications allowed:

```bash
npx wrangler d1 execute shrunk --remote --command \
  "SELECT id, substr(apns_token,1,8) AS token_prefix, location_id FROM devices ORDER BY updated_at DESC LIMIT 3"
```

Then give that device a Pro window and a watch, and publish a verified case so the drain has something to send:

```bash
npx wrangler d1 execute shrunk --remote --command \
  "UPDATE devices SET pro_until = strftime('%s','now') + 86400 WHERE id = '<device id>'; \
   INSERT OR REPLACE INTO watches (device_id, gtin, brand, alert_enabled) VALUES ('<device id>','0052000133417','Gatorade',1)"

curl -s -X POST "$BASE/v1/admin/verified-case" -H "Authorization: Bearer $ADMIN_SECRET" \
  -H 'Content-Type: application/json' -d '{"gtin":"0052000133417","brand":"Gatorade"}'
```

Within five minutes the phone shows "New verified case: …". Tap it and confirm the product opens and the row appears in Alerts. Afterwards, reset the probe row:

```bash
npx wrangler d1 execute shrunk --remote --command "UPDATE devices SET pro_until = NULL WHERE id = '<device id>'"
```

- [ ] **Step 11: Commit**

```bash
git add Shrunk/Shrunk.entitlements Shrunk/Services/AppDelegate.swift Shrunk/Services/PushInbox.swift Shrunk/Services/NotificationScheduler.swift Shrunk/ShrunkApp.swift Shrunk/Features/Watchlist/WatchlistView.swift Shrunk/Resources/Info.plist project.yml ShrunkTests/PushInboxTests.swift Shrunk.xcodeproj
git commit -m "feat(ios): APNs registration, push-to-feed delivery and tap routing"
```

---

### Task 15: Watchlist sync, and `BGAppRefresh` becomes a live-size check

**Files:**
- Modify: `Shrunk/Services/WatchlistService.swift`
- Modify: `Shrunk/ShrunkApp.swift`
- Modify: `Shrunk/Features/Watchlist/WatchlistViewModel.swift`
- Modify: `Shrunk/Features/Watchlist/WatchlistView.swift`
- Create: `ShrunkTests/WatchlistSyncTests.swift`

**Interfaces:**
- Consumes: `WatchlistSyncing`, `DeviceWatch`, `ShrunkAPIClient.deviceId` (Task 11); `StoreDataProviding.liveProduct(barcode:locationId:)` and `LivePrice` (Phase 3); `ShrinkAlert.unconfirmed(from:liveQuantity:)` (Task 13); `NotificationScheduler.scheduleLocalAlert(title:body:barcode:)` (Task 14); `ProductDTO.unit(forKind:)` (Phase 1).
- Produces: `WatchlistService.init(context:store:sync:)` (the `api:`/`detector:` parameters are gone — `ShrinkDetector` was only used by the deleted sweep).
- Produces: `WatchlistService.syncToBackend() async` — posts the whole watch list to `/v1/devices`; called after `add`, `remove`, `setAlertEnabled`, on foreground, and from `BGAppRefresh`.
- Produces: `WatchlistService.liveSizeCheck() async -> [(WatchedProduct, Double)]` — replaces `refreshAll()`. Compares the live Kroger size at the user's store with `lastKnownSize`, **inserts an `.unconfirmed` `ShrinkAlert` for each mismatch**, and returns them. It never rewrites `lastKnownSize`: only a real observation may do that.
- Produces: `WatchlistViewModel.refresh() async -> Int` (the number of mismatches found).

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/WatchlistSyncTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Shrunk

/// Records what the watchlist sends to `/v1/devices`.
final class StubWatchlistSync: WatchlistSyncing, @unchecked Sendable {
    private(set) var calls: [[DeviceWatch]?] = []
    var onSync: (() -> Void)?

    func syncDevice(
        deviceId: String,
        transactionJWS: String,
        apnsToken: String?,
        locationId: String?,
        categories: [String]?,
        watches: [DeviceWatch]?
    ) async -> Bool {
        calls.append(watches)
        onSync?()
        return true
    }
}

/// Answers `liveProduct` from a fixture table.
final class StubWatchlistStore: StoreDataProviding, @unchecked Sendable {
    var live: [String: LivePrice] = [:]

    func locations(zip: String) async throws -> [StoreLocation] { [] }
    func search(term: String, locationId: String) async throws -> [StoreSearchResult] { [] }
    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice {
        guard let price = live[barcode] else { throw ShrunkError.productNotFound }
        return price
    }
}

@MainActor
final class WatchlistSyncTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var sync: StubWatchlistSync!
    private var store: StubWatchlistStore!
    private var service: WatchlistService!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: WatchedProduct.self, ShrinkAlert.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        sync = StubWatchlistSync()
        store = StubWatchlistStore()
        service = WatchlistService(context: context, store: store, sync: sync)
        UserDefaults.standard.set("01400943", forKey: "storeLocationId")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "storeLocationId")
        try await super.tearDown()
    }

    private func product(_ barcode: String) -> ShrunkProduct {
        ShrunkProduct(id: barcode, name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
                      imageURL: nil, sizeHistory: [], currentPrice: nil, currency: "USD")
    }

    private func size(_ quantity: Double) -> SizeRecord {
        SizeRecord(date: Date(), quantity: quantity, unit: "ml", source: "fdc")
    }

    private func livePrice(_ barcode: String, quantity: Double?, unitKind: String? = "volume") -> LivePrice {
        LivePrice(gtin: barcode, locationId: "01400943", brand: "Gatorade", description: "Gatorade Thirst Quencher",
                  size: "28 fl oz", quantity: quantity, unitKind: unitKind,
                  regular: 1.89, promo: nil, perUnitEstimate: 0.07, stockLevel: "HIGH")
    }

    private func alerts() throws -> [ShrinkAlert] {
        try context.fetch(FetchDescriptor<ShrinkAlert>())
    }

    func test_addingAWatchSyncsTheWholeList() async throws {
        let synced = expectation(description: "synced")
        sync.onSync = { synced.fulfill() }

        try service.add(product: product("0052000133417"), currentSize: size(946.353))
        await fulfillment(of: [synced], timeout: 2)

        let watches = try XCTUnwrap(sync.calls.last ?? nil)
        XCTAssertEqual(watches, [DeviceWatch(gtin: "0052000133417", brand: "Gatorade", alertEnabled: true)])
    }

    func test_togglingAndRemovingAlsoSync() async throws {
        // Wait for the add's own sync first, so its Task cannot land on a later
        // expectation and make this test lie.
        let added = expectation(description: "added")
        sync.onSync = { added.fulfill() }
        try service.add(product: product("0052000133417"), currentSize: size(946.353))
        await fulfillment(of: [added], timeout: 2)

        let watched = try XCTUnwrap(try service.fetch(barcode: "0052000133417"))

        let toggled = expectation(description: "toggled")
        sync.onSync = { toggled.fulfill() }
        try service.setAlertEnabled(false, for: watched)
        await fulfillment(of: [toggled], timeout: 2)
        XCTAssertEqual((sync.calls.last ?? nil)?.first?.alertEnabled, false)

        let removed = expectation(description: "removed")
        sync.onSync = { removed.fulfill() }
        try service.remove(watched)
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(sync.calls.last ?? nil, [])
    }

    func test_liveSizeCheckFilesAnUnconfirmedAlert() async throws {
        try service.add(product: product("0052000133417"), currentSize: size(946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)

        let mismatches = await service.liveSizeCheck()
        XCTAssertEqual(mismatches.count, 1)
        XCTAssertEqual(mismatches[0].1, 828.058)

        let filed = try alerts()
        XCTAssertEqual(filed.count, 1)
        XCTAssertEqual(filed[0].kind, .unconfirmed)
        XCTAssertEqual(filed[0].barcode, "0052000133417")

        // The live size is a hint, not an observation: the stored size stands.
        XCTAssertEqual(try XCTUnwrap(try service.fetch(barcode: "0052000133417")).lastKnownSize, 946.353)
    }

    func test_liveSizeCheckIgnoresAMatchingOrIncomparableSize() async throws {
        try service.add(product: product("0052000133417"), currentSize: size(946.353))

        store.live["0052000133417"] = livePrice("0052000133417", quantity: 946.353)
        XCTAssertTrue(await service.liveSizeCheck().isEmpty)

        store.live["0052000133417"] = livePrice("0052000133417", quantity: 340.194, unitKind: "mass")
        XCTAssertTrue(await service.liveSizeCheck().isEmpty, "a different unit kind is never compared")

        store.live["0052000133417"] = livePrice("0052000133417", quantity: nil)
        XCTAssertTrue(await service.liveSizeCheck().isEmpty)

        XCTAssertTrue(try alerts().isEmpty)
    }

    func test_liveSizeCheckNeedsAStore() async throws {
        UserDefaults.standard.removeObject(forKey: "storeLocationId")
        try service.add(product: product("0052000133417"), currentSize: size(946.353))
        store.live["0052000133417"] = livePrice("0052000133417", quantity: 828.058)
        XCTAssertTrue(await service.liveSizeCheck().isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/WatchlistSyncTests -quiet 2>&1 | tail -30
```
Expected: compile errors — `extra argument 'store' in call`, `value of type 'WatchlistService' has no member 'liveSizeCheck'`.

- [ ] **Step 3: Rewrite the service**

Replace `Shrunk/Services/WatchlistService.swift` entirely:

```swift
import Foundation
import SwiftData

/// Wraps the SwiftData ModelContext for watched-product CRUD, keeps the
/// Worker's copy of the watch list current (spec §7), and runs the device-side
/// live-size check that `BGAppRefresh` wakes us for. The view layer uses
/// `@Query` directly for live fetches; this service handles writes.
@MainActor
final class WatchlistService {
    private let context: ModelContext
    private let store: StoreDataProviding
    private let sync: WatchlistSyncing

    init(
        context: ModelContext,
        store: StoreDataProviding = ShrunkAPIClient.shared,
        sync: WatchlistSyncing = ShrunkAPIClient.shared
    ) {
        self.context = context
        self.store = store
        self.sync = sync
    }

    // MARK: - CRUD

    func add(product: ShrunkProduct, currentSize: SizeRecord) throws {
        if let existing = try fetch(barcode: product.id) {
            existing.lastKnownSize = currentSize.quantity
            existing.lastKnownUnit = currentSize.unit
            existing.lastChecked = Date()
            try context.save()
            scheduleSync()
            return
        }
        let watched = WatchedProduct.from(product: product, currentSize: currentSize)
        context.insert(watched)
        try context.save()
        scheduleSync()
    }

    func remove(_ watched: WatchedProduct) throws {
        context.delete(watched)
        try context.save()
        scheduleSync()
    }

    func setAlertEnabled(_ enabled: Bool, for watched: WatchedProduct) throws {
        watched.alertEnabled = enabled
        try context.save()
        scheduleSync()
    }

    func fetch(barcode: String) throws -> WatchedProduct? {
        var descriptor = FetchDescriptor<WatchedProduct>(
            predicate: #Predicate { $0.barcode == barcode }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func all() throws -> [WatchedProduct] {
        let descriptor = FetchDescriptor<WatchedProduct>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Backend sync

    /// Fire and forget — the UI never waits on the network (spec §8).
    private func scheduleSync() {
        Task { await syncToBackend() }
    }

    /// Posts the whole watch list to `/v1/devices`; the Worker replaces its
    /// copy wholesale (spec §6.1). Never throws.
    func syncToBackend() async {
        let payload: [DeviceWatch]
        do {
            payload = try all().map {
                DeviceWatch(gtin: $0.barcode, brand: $0.brand, alertEnabled: $0.alertEnabled)
            }
        } catch {
            return
        }
        await sync.syncDevice(
            deviceId: ShrunkAPIClient.deviceId,
            transactionJWS: "",
            apnsToken: nil,
            locationId: nil,
            categories: nil,
            watches: payload
        )
    }

    // MARK: - Device-side live-size check

    /// Spec §7 — `BGAppRefresh` compares the live size at the user's store with
    /// the last size we recorded. A mismatch is a hint, not an observation, so
    /// it files an `.unconfirmed` alert asking for a re-scan and leaves
    /// `lastKnownSize` alone. Returns the mismatches it filed.
    @discardableResult
    func liveSizeCheck() async -> [(WatchedProduct, Double)] {
        let locationId = UserDefaults.standard.string(forKey: "storeLocationId") ?? ""
        guard !locationId.isEmpty else { return [] }

        let watched: [WatchedProduct]
        do {
            watched = try all()
        } catch {
            return []
        }

        var mismatches: [(WatchedProduct, Double)] = []
        for item in watched where item.alertEnabled {
            guard let live = try? await store.liveProduct(barcode: item.barcode, locationId: locationId),
                  let quantity = live.quantity, quantity > 0,
                  let unitKind = live.unitKind,
                  ProductDTO.unit(forKind: unitKind) == item.lastKnownUnit,
                  item.lastKnownSize > 0
            else { continue }

            item.lastChecked = Date()
            if abs(quantity - item.lastKnownSize) / item.lastKnownSize > 0.01 {
                context.insert(ShrinkAlert.unconfirmed(from: item, liveQuantity: quantity))
                mismatches.append((item, quantity))
            }
        }
        try? context.save()
        return mismatches
    }
}
```

(The `add` path that updated an existing row never called `save()` before — that is fixed here.)

- [ ] **Step 4: Rewrite the background sweep**

In `Shrunk/ShrunkApp.swift`, replace `runWatchlistSweep` and add the foreground sync:

```swift
    // MARK: - Background sweep

    @MainActor
    private static func runWatchlistSweep(container: ModelContainer) async {
        let context = ModelContext(container)
        let watchlist = WatchlistService(context: context)

        // Keep the Worker's copy of the watch list current, then do the
        // device-side live-size check that files `.unconfirmed` alerts (spec §7).
        await watchlist.syncToBackend()

        let prefsRaw = UserDefaults.standard.string(forKey: NotificationPreferences.appStorageKey)
            ?? NotificationPreferences.default.encoded()
        let prefs = NotificationPreferences.decoded(prefsRaw)

        for (watched, liveQuantity) in await watchlist.liveSizeCheck() {
            let percent = watched.lastKnownSize > 0
                ? (liveQuantity - watched.lastKnownSize) / watched.lastKnownSize
                : 0
            guard prefs.shouldFire(shrinkPercent: percent) else { continue }
            await NotificationScheduler.shared.scheduleLocalAlert(
                title: "\(watched.productName) may have changed size",
                body: "Your store lists a different size. Scan it to confirm.",
                barcode: watched.barcode
            )
        }
    }
```

and sync when the app comes to the foreground, by adding the scene-phase hook to the `WindowGroup`:

```swift
    @Environment(\.scenePhase) private var scenePhase
```

```swift
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(storeKit)
                .tint(Color.shrunkRed)
                .task {
                    await storeKit.bootstrap()
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let container = modelContainer
            Task { @MainActor in
                await WatchlistService(context: ModelContext(container)).syncToBackend()
            }
        }
```

- [ ] **Step 5: Update the pull-to-refresh**

`Shrunk/Features/Watchlist/WatchlistViewModel.swift`:

```swift
    /// Syncs the list to the Worker, then runs the live-size check. Returns the
    /// number of products whose store size disagrees with what we last recorded.
    func refresh() async -> Int {
        isRefreshing = true
        await service.syncToBackend()
        let mismatches = await service.liveSizeCheck()
        isRefreshing = false
        return mismatches.count
    }
```

`Shrunk/Features/Watchlist/WatchlistView.swift` — replace the body of `.refreshable`:

```swift
        .refreshable {
            guard let vm else { return }
            let detected = await vm.refresh()
            let total = watched.count
            let message = detected == 0
                ? "Checked \(total) product\(total == 1 ? "" : "s") · all stable"
                : "\(detected) size change\(detected == 1 ? "" : "s") to confirm"
            showToast(message)
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: all tests pass, including the 5 new `WatchlistSyncTests`.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Services/WatchlistService.swift Shrunk/ShrunkApp.swift Shrunk/Features/Watchlist ShrunkTests/WatchlistSyncTests.swift
git commit -m "feat(ios): watchlist syncs to /v1/devices; BGAppRefresh does the live-size check"
```

---

### Task 16: Browse reads `/v1/feed`

**Files:**
- Modify: `Shrunk/Services/TrendingFeedService.swift`
- Create: `ShrunkTests/TrendingFeedServiceTests.swift`

**Interfaces:**
- Consumes: `GET /v1/feed` (Task 3); `ShrunkAPIClient.defaultBaseURL` and `ProductDTO.unit(forKind:)` (Phase 1).
- Produces: `TrendingFeedService.init(baseURL:session:)` (both defaulted, so `TrendingFeedService.shared` and every existing call site are unchanged), `FeedItemDTO`, and `static func entry(from: FeedItemDTO, bundled: TrendingEntry?) -> TrendingEntry`.
- `fetch()` / `fetchRemote()` keep their signatures and return `TrendingFeed`, so `BrowseViewModel` and `TrendingFeedProviding` (Phase 3) are untouched. The bundled `trending.json` remains the offline fallback **and** supplies image/evidence/price for curated products, which `/v1/feed` does not carry.
- The feed gives only the current observation's date, so the mapped "before" point is placed one day earlier — enough for `ShrinkDetector` to order the pair; Browse shows the delta, not a timeline.

- [ ] **Step 1: Write the failing tests**

`ShrunkTests/TrendingFeedServiceTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class TrendingFeedServiceTests: XCTestCase {
    private var service: TrendingFeedService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        service = TrendingFeedService(baseURL: URL(string: "https://api.test")!,
                                      session: URLSession(configuration: config))
    }

    func test_entryMappingBuildsATwoPointHistory() {
        let item = FeedItemDTO(
            gtin: "0052000133417", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
            previous_quantity: 946.353, current_quantity: 828.058, unit_kind: "volume",
            shrink_percent: -12.5, observed_at: 1630454400, source: "curated"
        )
        let entry = TrendingFeedService.entry(from: item, bundled: nil)

        XCTAssertEqual(entry.barcode, "0052000133417")
        XCTAssertEqual(entry.name, "Gatorade Thirst Quencher")
        XCTAssertEqual(entry.category, "Beverages")
        XCTAssertEqual(entry.history.count, 2)
        XCTAssertEqual(entry.history[0].quantity, 946.353)
        XCTAssertEqual(entry.history[0].unit, "ml")
        XCTAssertEqual(entry.history[1].quantity, 828.058)
        XCTAssertEqual(entry.history[1].date.timeIntervalSince1970, 1630454400)
        XCTAssertLessThan(entry.history[0].date, entry.history[1].date)
        XCTAssertNil(entry.imageUrl)
    }

    func test_entryMappingBorrowsImageAndEvidenceFromTheBundledCopy() {
        let bundled = TrendingEntry(
            barcode: "0052000133417", name: "Gatorade", brand: "Gatorade", category: "Beverages",
            imageUrl: URL(string: "https://img/gatorade.jpg"), history: [],
            currentPrice: 1.89, currency: "USD",
            evidenceUrl: URL(string: "https://www.mouseprint.org/x"), addedAt: Date(timeIntervalSince1970: 0)
        )
        let item = FeedItemDTO(
            gtin: "0052000133417", name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Beverages",
            previous_quantity: 946.353, current_quantity: 828.058, unit_kind: "volume",
            shrink_percent: -12.5, observed_at: 1630454400, source: "curated"
        )
        let entry = TrendingFeedService.entry(from: item, bundled: bundled)

        XCTAssertEqual(entry.imageUrl?.absoluteString, "https://img/gatorade.jpg")
        XCTAssertEqual(entry.evidenceUrl?.absoluteString, "https://www.mouseprint.org/x")
        XCTAssertEqual(entry.currentPrice, 1.89)
        XCTAssertEqual(entry.name, "Gatorade Thirst Quencher", "the feed's name wins")
    }

    func test_fetchRemoteCallsTheFeedEndpointAndMaps() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.test/v1/feed")
            let json = """
            {"updated":1630454400,"items":[
              {"gtin":"0052000133417","name":"Gatorade Thirst Quencher","brand":"Gatorade","category":"Beverages",
               "previous_quantity":946.353,"current_quantity":828.058,"unit_kind":"volume",
               "shrink_percent":-12.5,"observed_at":1630454400,"source":"curated"}]}
            """
            return (200, Data(json.utf8))
        }

        let feed = await service.fetchRemote()
        let entries = try? XCTUnwrap(feed).trending
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.barcode, "0052000133417")
        XCTAssertEqual(feed?.updated.timeIntervalSince1970, 1630454400)
    }

    func test_fetchRemoteReturnsNilOnFailure() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let feed = await service.fetchRemote()
        XCTAssertNil(feed)
    }

    func test_fetchFallsBackToTheBundledCatalogue() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let feed = await service.fetch()
        XCTAssertGreaterThan(feed.trending.count, 0, "the bundled trending.json must ship in the app target")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' \
  -only-testing:ShrunkTests/TrendingFeedServiceTests -quiet 2>&1 | tail -30
```
Expected: `cannot find 'FeedItemDTO' in scope`.

- [ ] **Step 3: Point the service at the Worker**

In `Shrunk/Services/TrendingFeedService.swift`, replace the doc comment, the `remoteURL` property and the initializer with:

```swift
/// The Browse feed. Reads `/v1/feed` on the Shrunk Worker — curated verified
/// cases merged with recently accepted crowd and Kroger shrinks (spec §6.1) —
/// and falls back to the bundled `trending.json` when the network is gone, so
/// Browse is never blank (spec §8).
actor TrendingFeedService {
    static let shared = TrendingFeedService()

    private let feedURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    /// Plain decoder: the feed's wire names are already snake_case properties.
    private let feedDecoder = JSONDecoder()

    init(baseURL: URL = ShrunkAPIClient.defaultBaseURL, session: URLSession = .shared) {
        self.feedURL = baseURL.appending(path: "v1/feed")
        self.session = session
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
```

(keep the existing `d.dateDecodingStrategy = .custom { ... }` block and `self.decoder = d` exactly as they are — they still decode the bundled file).

Replace `fetchRemote()` with:

```swift
    /// Force-fetches the Worker feed, bypassing the bundled fallback. Used by
    /// pull-to-refresh on Browse. Returns nil if the Worker is unreachable.
    func fetchRemote() async -> TrendingFeed? {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadRevalidatingCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let dto = try feedDecoder.decode(FeedResponseDTO.self, from: data)
            let bundled = loadBundled()?.trending.reduce(into: [String: TrendingEntry]()) { $0[$1.barcode] = $1 } ?? [:]
            return TrendingFeed(
                version: 2,
                updated: Date(timeIntervalSince1970: TimeInterval(dto.updated)),
                trending: dto.items.map { Self.entry(from: $0, bundled: bundled[$0.gtin]) }
            )
        } catch {
            return nil
        }
    }

    /// Maps one feed item onto the model Browse already renders. `/v1/feed`
    /// carries no image, price or evidence link, so those come from the bundled
    /// catalogue when it knows the product.
    static func entry(from item: FeedItemDTO, bundled: TrendingEntry?) -> TrendingEntry {
        let unit = ProductDTO.unit(forKind: item.unit_kind)
        let observed = Date(timeIntervalSince1970: TimeInterval(item.observed_at))
        // The feed dates only the current observation; the earlier point sits a
        // day before so the pair sorts correctly for `ShrinkDetector`.
        let previous = observed.addingTimeInterval(-86_400)

        return TrendingEntry(
            barcode: item.gtin,
            name: item.name,
            brand: item.brand,
            category: item.category,
            imageUrl: bundled?.imageUrl,
            history: [
                TrendingEntry.HistoryPoint(date: previous, quantity: item.previous_quantity, unit: unit),
                TrendingEntry.HistoryPoint(date: observed, quantity: item.current_quantity, unit: unit),
            ],
            currentPrice: bundled?.currentPrice,
            currency: bundled?.currency ?? "USD",
            evidenceUrl: bundled?.evidenceUrl,
            addedAt: observed
        )
    }
```

Add the wire types at the bottom of the file, next to `TrendingFeed`:

```swift
// MARK: - /v1/feed wire format

struct FeedResponseDTO: Decodable {
    let updated: Int
    let items: [FeedItemDTO]
}

struct FeedItemDTO: Decodable {
    let gtin: String
    let name: String
    let brand: String
    let category: String
    let previous_quantity: Double
    let current_quantity: Double
    let unit_kind: String
    let shrink_percent: Double
    let observed_at: Int
    let source: String
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -20
```
Expected: all tests pass, including the 5 new `TrendingFeedServiceTests`. If `test_fetchFallsBackToTheBundledCatalogue` fails, `data/trending.json` is not in the app target's resources — check `project.yml`.

- [ ] **Step 5: Check Browse by hand**

Run the app against the deployed Worker, open Browse, pull to refresh, and confirm the tiles still show thumbnails and the same verified cases. Then publish a crowd observation (Phase 2's contribute flow) and confirm the product appears at the top of Browse after the next refresh.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Services/TrendingFeedService.swift ShrunkTests/TrendingFeedServiceTests.swift
git commit -m "feat(ios): Browse reads /v1/feed with the bundled catalogue as fallback"
```

---

## Phase 4 exit criteria

- [ ] `cd backend && npx vitest run && npx tsc --noEmit && npm run check:trending` — all green.
- [ ] `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'` — all green.
- [ ] `npx wrangler deploy` lists three schedules: `*/5 * * * *`, `0 */6 * * *`, `0 1 * * 1`.
- [ ] `POST /v1/devices` with a UUID, a token, categories and watches returns `{"ok":true,"pro":false}`, and the row's `pro_until` is still NULL — Phase 4 never grants Pro.
- [ ] A second `POST /v1/devices` carrying only `{device_id, transaction_jws}` leaves the stored watches and categories untouched (the Phase 5 call shape).
- [ ] `GET /v1/feed` returns the curated catalogue merged with the last 30 days of accepted crowd/Kroger shrinks, and `?category=Drinks` filters to `Beverages`.
- [ ] On a real device with `pro_until` in the future, a `POST /v1/admin/verified-case` for a watched brand produces a push within five minutes; tapping it opens the product and the row is in the Alerts feed.
- [ ] A device with `pro_until` NULL or in the past receives nothing.
- [ ] Turning "Weekly digest" off in Settings writes `prefs.digest = false` on the device row, and the Monday cron skips that device.
- [ ] `alert_jobs` rows are marked `sent_at` with a `sent_count`, and no job is ever pushed twice.
- [ ] `docs/superpowers/plans/2026-08-26-shrunk-v2-phase5-subscription-onboarding-dashboard.md` Preflight passes: `backend/src/routes/devices.ts` exists and exports `devicesRoute`, `transaction_jws` appears in it, `CREATE TABLE devices` is in `backend/migrations/0004_devices_watches.sql`, and `grep -n "func syncDevice" Shrunk/Services/ShrunkAPIClient.swift` finds the method.
