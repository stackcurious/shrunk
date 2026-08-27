# shrunk-api

The Cloudflare Worker behind the Shrunk iOS app: Hono 4 on Workers, D1 for owned data, R2 for label photos awaiting review, KV for the Kroger OAuth token and rate-limit counters. `wrangler.toml`'s `main` is `src/worker.ts`, which exports `{fetch, scheduled}` — `fetch` re-exports the Hono app in `src/index.ts` (kept separate so tests can call `app.request(...)` directly), `scheduled` dispatches the three cron triggers below.

## Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/health` | — | `{"ok":true}`. |
| GET | `/v1/product/:gtin?locationId=` | — | Product identity, every **accepted** observation merged across sources, and the last 12 `price_snapshots` for `locationId`. Creates unknown products from the FDC API, then Open Food Facts. Sets `needs_confirmation` when the live Kroger size disagrees with the latest non-Kroger observation. `Cache-Control: private, max-age=60` when `locationId` is given (the body may carry store-level snapshots), `public, max-age=3600` otherwise. |
| GET | `/v1/feed?category=` | — | The curated catalogue (`src/data/trending.json`) merged with accepted crowd/Kroger observations from the last 30 days that are a real shrink (>1%) vs. the previous observation of the same product. `Cache-Control: public, max-age=300`. This is what the app's Browse tab reads. |
| GET | `/v1/kroger/locations?zip=` | `X-Device-Id` (UUID) | Proxy to Kroger Locations, `filter.radiusInMiles=15`, `filter.limit=20`. |
| GET | `/v1/kroger/product/:gtin?locationId=` | `X-Device-Id` (UUID) | Proxy; forwards Kroger's `Cache-Control`; writes a snapshot (and an observation when the size parses) while `KROGER_PERSIST="on"`. A D1 write failure here is swallowed — the proxied response still succeeds. |
| GET | `/v1/kroger/search?term=&locationId=` | `X-Device-Id` (UUID) | Proxy for alternatives, ranked by per-unit price server-side. **Never persisted.** |
| POST | `/v1/observations` | — | Crowd submission (multipart: `gtin`, `device_id`, `quantity`, `unit_kind`, `raw_text`, `ocr_confidence`, optional `photo` as JPEG ≤5MB). Applies the confidence gate; returns `accepted` or `pending`. Rate-limited to 30/hour per `device_id`. |
| POST | `/v1/devices` | — | Upserts the device row: APNs token, `location_id`, categories, watches, notification prefs, and the App Store transaction JWS. Grants Pro (sets `pro_until`) only when the JWS verifies **and** its `appAccountToken` equals the posted `device_id` (case-insensitive) — a valid receipt for one device can't be replayed onto another. A verification failure leaves the existing entitlement untouched. |
| POST | `/v1/appstore/notifications` | Apple's signature | App Store Server Notifications V2. Verified against a pinned Apple Root CA - G3; answers `401 {"error":"invalid_signature"}` to anything unverifiable. No shared secret. |
| GET/POST | `/v1/admin/review` and `/v1/admin/review/:id` | `Bearer ADMIN_SECRET` | Single-page HTML queue of pending submissions; accept/reject. The photo is deleted from R2 either way. |
| GET | `/v1/admin/photo/:id` | `Bearer ADMIN_SECRET` | Serves a pending submission's photo out of R2. |
| POST | `/v1/admin/verified-case` | `Bearer ADMIN_SECRET` | Files a `verified_case` alert job for a gtin/brand, which the five-minute drain turns into pushes for watching Pro devices. |
| POST | `/v1/admin/purge-kroger` | `Bearer ADMIN_SECRET` | Deletes every `price_snapshots` row, every `observations` row with `source='kroger'`, and every `products` row with `origin='kroger'` that has no observation left after those deletes. |

`/v1/kroger/*` requires `X-Device-Id` to be a UUID (else `400 {"error":"invalid_device_id"}`), and is rate-limited to 400/hour globally and 60/hour per device (`429 {"error":"rate_limited"}`) — the global cap is checked first so a burst of spoofed device ids can't collectively exhaust it. Every response carrying Kroger data includes `"attribution": "Prices from Kroger"` (spec §6.6).

## Bindings

| Binding | Kind | Name | Holds |
|---|---|---|---|
| `DB` | D1 | `shrunk` | `products`, `observations`, `price_snapshots`, `devices`, `watches`, `alert_jobs`, `submissions` |
| `PHOTOS` | R2 | `shrunk-photos` | Label photos, for pending submissions only |
| `KV` | KV | — (`id` is a placeholder in `wrangler.toml` until Task 11 runs `wrangler kv namespace create`) | Kroger client-credentials token (25 min), the APNs/FCM auth token, and per-device rate-limit counters |

`products.origin` (`fdc \| lookup \| kroger \| curated`) records which path first created the row — only `origin='kroger'` rows are eligible for the purge above.

## Vars and secrets

`[vars]` in `wrangler.toml` — plain, committed, changeable without a code change:

| Var | Values | Meaning |
|---|---|---|
| `ENV` | `dev` / `production` | Environment label. |
| `KROGER_PERSIST` | `on` / `off` | `off` stops **every** Kroger write immediately (spec §9 kill switch). |
| `PUSH_PROVIDER` | `apns` / `fcm` | Which `PushSender` implementation runs (`src/push/index.ts`). |
| `APNS_ENV` | `sandbox` / `production` | `sandbox` for development and TestFlight builds; `production` for the App Store build — selects the APNs host. |

Secrets — `npx wrangler secret put <NAME>`, mirrored into the git-ignored `backend/.dev.vars` for `wrangler dev`. **Never committed.**

| Secret | Used by | Meaning |
|---|---|---|
| `FDC_API_KEY` | `src/lookup/fdc.ts` | USDA FoodData Central lookup for unknown GTINs. |
| `ADMIN_SECRET` | every `/v1/admin/*` route | Bearer token, compared with a constant-time check. |
| `KROGER_CLIENT_ID` / `KROGER_CLIENT_SECRET` | `src/kroger/client.ts` | Client-credentials OAuth against Kroger's API. |
| `APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` | `src/push/apns.ts` | ES256-signs the APNs auth JWT (the `.p8` key file's contents, PEM). |
| `FCM_SERVICE_ACCOUNT_JSON` | `src/push/fcm.ts` | Firebase service-account JSON; only read when `PUSH_PROVIDER="fcm"`. |

`APPSTORE_ROOT_CA_B64` (`src/env.ts`) is a test-only trust anchor (base64 DER of a root cert that replaces Apple's) — it is never set in `wrangler.toml` or as a deployed secret, so production always verifies App Store JWS against the real Apple Root CA - G3.

## Cron triggers

`[triggers].crons` in `wrangler.toml`; `src/worker.ts`'s `scheduled` handler dispatches on `event.cron`.

| Schedule | Job |
|---|---|
| `*/5 * * * *` | `runAlertDrain` (`src/alerts.ts`) — drain `alert_jobs`: push to watching Pro devices, mark sent. Max 40 pushes per invocation; a job that hits the budget resumes from its `sent_count` next run. |
| `0 */6 * * *` | `runKrogerSweep` (`src/sweep.ts`) — only while `KROGER_PERSIST="on"`: re-check every watched `(gtin, location_id)`, file `size_drop` and `price_hike` jobs. Per-pair failures are contained so one bad pair can't fail the whole sweep. |
| `0 1 * * 1` | `runWeeklyDigest` (`src/digest.ts`) — one push per Pro device with activity in a subscribed category. |

## Develop

```
npm ci
npm run dev          # http://localhost:8787 — needs backend/.dev.vars
npm test             # Vitest 4 in the Workers runtime, migrations applied by test/apply-migrations.ts
npm run typecheck
npm run check:trending   # fails when src/data/trending.json has drifted from ../data/trending.json
npm run sync:trending    # re-copies it
```

Test convention: outbound HTTP is stubbed with `vi.stubGlobal("fetch", vi.fn(...))` and `afterEach(() => vi.unstubAllGlobals())`. `fetchMock` from `cloudflare:test` does not exist in this toolchain. D1 and KV bindings are real; cron handlers are called directly (`runAlertDrain`, `runKrogerSweep`, `runWeeklyDigest`).

## Deploy

```
npm run migrate:remote
npm run deploy
```

First-time provisioning (account, D1, KV, R2, every secret) is in [`../docs/RELEASE_CHECKLIST.md`](../docs/RELEASE_CHECKLIST.md).

## Loading data

```
# USDA FoodData Central, ~twice a year on each release:
python3 ../scripts/fdc_import.py --zip /tmp/fdc_branded.zip --out ../scripts/out/fdc.sql \
  --report ../scripts/out/report.json --curated ../data/trending.json
npx wrangler d1 execute shrunk --remote --file ../scripts/out/fdc.sql

# The curated catalogue, after every edit to data/trending.json:
python3 ../scripts/seed_curated.py --curated ../data/trending.json --out ../scripts/out/curated.sql
npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
```

## Kroger kill switch (spec §9)

Kroger's terms prohibit building a database from their responses; snapshots are retained while a written-permission request is pending, and are isolated so they can go in one command.

```
# stop new writes
sed -i '' 's/KROGER_PERSIST = "on"/KROGER_PERSIST = "off"/' wrangler.toml && npx wrangler deploy

# remove everything already retained
curl -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer $ADMIN_SECRET"
```
