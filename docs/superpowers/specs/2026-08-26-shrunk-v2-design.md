# Shrunk v2 — Real Data, Real Pro

**Date:** 2026-08-26
**Status:** Approved design, pending implementation plan
**Goal:** Make every paid feature in Shrunk backed by observed size and price data, so a $2.99/mo Pro subscription is defensible, then ship to the App Store within ~6 weeks part-time.

## 1. Why

An audit on 2026-08-26 ran the app's only scan-time data source (Open Food Facts) against the 35 curated products that are *known* to have shrunk. Result: 11 UPCs are not in OFF at all, the rest have no before/after quantity, and **0 of 14 clean lookups produced a verdict**. The current Pro tier (watchlist sweeps over OFF, a savings dashboard driven by invented category constants, a quiz-based "$/yr exposure" number) therefore sells outcomes the app cannot observe.

Research (same day) established the data landscape:

| Source | Size | Price | Storable? | Role |
|---|---|---|---|---|
| USDA FoodData Central, Branded Foods | `package_weight` for ~409k US GTINs; every historical version retained (≈4.3 versions/GTIN); 14 archived releases 2019–2026 | — | Yes, CC0 public domain | **History backbone** (food only; skews 2017–2020 = good "before" baseline). Download-only, 2.9 GB CSV. |
| Kroger Products API | `items[].size` | store-level regular/promo + per-unit estimate | ToS prohibits building a database / caching past headers (see §9) | **Live layer + snapshots**, isolated and purgeable |
| Crowdsourced label photos | net content, dated | — | Yes, ours | "After" observations; non-food coverage |
| Curated `data/trending.json` | verified events + evidence URLs | — | Yes, ours | Browse feed, verified alerts |
| Open Food Facts | unreliable | — | Yes, ODbL | Name/image fallback only |
| Walmart Affiliate API | no structured net weight | online-only price | unclear | **Dropped from v1** |

## 2. Decisions

- **Backend:** Cloudflare Workers (Paid, $5/mo), D1, R2, Cron Triggers. Chosen over Vercel because Vercel's Hobby plan forbids commercial use ($20/mo minimum) and Cloudflare's free-tier write cap (100k D1 writes/day) is too low for the FDC import.
- **Data:** FDC + curated + crowdsourced form the owned history. Kroger is proxied live and, per the user's decision, **also snapshotted** while a written-permission request is pending with Kroger. Kroger-derived rows are tagged and purgeable in one command.
- **Pricing:** auto-renewable subscription, `com.shrunk.pro.monthly` $2.99 and `com.shrunk.pro.yearly` $14.99. The 7-day introductory free trial applies to `com.shrunk.pro.yearly` only (R32) — the monthly plan has no introductory offer. The `com.shrunk.pro.lifetime` non-consumable is removed (no purchases exist).
- **US only.** Barcodes are stored as 13-digit zero-padded GTINs (FDC and Kroger both use this form).
- **Timeline:** ~6 weeks part-time to App Store submission; Walmart, Android, and admin polish are out of scope.

## 3. Free vs Pro

**Free**
- Unlimited scans → verdict, size history (FDC/curated/crowd/Kroger), current price and cost-per-unit at the user's Kroger store.
- Browse feed.
- Contribute label photos (the growth loop must be free).
- 3 alternatives per scan.

**Pro**
1. **Watchlist alerts**, unlimited items: push when a smaller size is observed for a watched product, when the price-per-unit at the user's store rises ≥5% versus the previous snapshot, or when a verified case is published for a watched product or brand.
2. **Weekly "what shrank this week" digest** push for the user's categories.
3. **Unlimited ranked alternatives at the user's store**: same category, in stock, cheapest per unit.
4. **Price + size history charts** per product (free sees the latest before/after only).
5. **Real savings dashboard**: for each scanned or watched product, `shrink% × current unit price × purchases/yr`, from observed data.

**Removed:** the 10-screen quiz onboarding and its "$/yr exposure" reveal, `SavingsForecast` and its category constants, the lifetime SKU.

## 4. Architecture

```
iOS app ──▶ Worker API ──▶ D1: products, observations, price_snapshots, devices, watches, alert_jobs
   │            │    │                        ▲
   │            │    └─▶ Kroger API (OAuth client_credentials, proxied)
   │            └─▶ APNs (alerts, digest)     │
   │                                          │
   └─▶ Vision OCR (on device) ── POST /v1/observations ──┘  (+ R2 for pending-review photos)

scripts/fdc_import.py (run locally, ~twice a year) ──▶ SQL ──▶ wrangler d1 execute
```

Scan flow:
1. App calls `GET /v1/product/{gtin}?locationId=`. Worker returns product identity, all **accepted** observations merged from every source, and recent price snapshots for that store. If the product is unknown, Worker tries FDC API (name/brand) then OFF (name/image) and creates the product row.
2. If the user has a store set, app calls `GET /v1/kroger/product/{gtin}?locationId=`. Worker fetches live from Kroger, returns size/price/stock with Kroger's cache headers, and (when `KROGER_PERSIST=on`) writes a `price_snapshots` row and, if the size parses, an `observations` row with `source='kroger'`.
3. Device runs `ShrinkDetector` over observations; shows verdict, history, live price, cost-per-unit then/now.
4. If the live Kroger size differs from the latest non-Kroger observation, the result view offers "Confirm with a label photo" (§6.3).

## 5. Data model (D1)

```sql
products(
  gtin TEXT PRIMARY KEY,           -- 13-digit
  name TEXT, brand TEXT, category TEXT, image_url TEXT,
  unit_kind TEXT,                  -- dominant kind: mass | volume | count
  created_at INTEGER, updated_at INTEGER)

observations(
  id INTEGER PRIMARY KEY,
  gtin TEXT NOT NULL REFERENCES products,
  quantity REAL NOT NULL,          -- grams | millilitres | count
  unit_kind TEXT NOT NULL,         -- mass | volume | count
  raw_text TEXT,                   -- "12 oz/340 g", "15.25 ONZ", OCR line
  observed_at INTEGER NOT NULL,    -- unix seconds
  source TEXT NOT NULL,            -- fdc | curated | crowd | kroger
  source_ref TEXT,                 -- fdc_id, evidence_url, submission id, locationId
  confidence REAL NOT NULL,        -- 0..1
  status TEXT NOT NULL,            -- accepted | pending | rejected
  created_at INTEGER NOT NULL)
CREATE INDEX obs_gtin ON observations(gtin, status, observed_at);

price_snapshots(                   -- Kroger-derived, purgeable
  id INTEGER PRIMARY KEY,
  gtin TEXT NOT NULL, location_id TEXT NOT NULL,
  regular REAL, promo REAL, per_unit_estimate REAL,
  size_raw TEXT, stock_level TEXT,
  observed_at INTEGER NOT NULL)
CREATE INDEX ps_gtin_loc ON price_snapshots(gtin, location_id, observed_at);

devices(
  id TEXT PRIMARY KEY,             -- app-generated UUID
  apns_token TEXT, location_id TEXT,
  categories TEXT,                 -- JSON array
  pro_until INTEGER,               -- unix seconds, from verified transaction
  app_account_token TEXT,          -- UUID passed to StoreKit purchase
  updated_at INTEGER)

watches(device_id TEXT, gtin TEXT, brand TEXT, alert_enabled INTEGER, PRIMARY KEY(device_id, gtin))

alert_jobs(id INTEGER PRIMARY KEY, kind TEXT, gtin TEXT, brand TEXT, location_id TEXT,
           payload TEXT, created_at INTEGER, sent_at INTEGER)

submissions(id TEXT PRIMARY KEY, device_id TEXT, gtin TEXT, photo_key TEXT,
            ocr_text TEXT, parsed_quantity REAL, parsed_kind TEXT,
            status TEXT, created_at INTEGER, reviewed_at INTEGER)
```

### 5.1 Normalization

All quantities are normalized to a base unit per kind before storage or comparison:

| Kind | Base | Accepted inputs |
|---|---|---|
| mass | g | g, gram(s), kg, oz, ounce(s), lb(s), GS1 `GRM KGM ONZ LBR` |
| volume | mL | ml, l, fl oz, floz, pt, qt, gal, GS1 `MLT LTR OZA PTL QTL GLL` |
| count | each | ct, count, pk, pack, EA, `H87` |

Rules:
- FDC `package_weight` of the form `"16 oz/1 lbs/454 g"` is split on `/`; the first parseable mass or volume segment wins; segments must agree within 2% or the row is discarded as malformed.
- Observations of different kinds are never compared. `ShrinkDetector` selects the two most recent accepted observations whose kind matches the product's dominant kind.
- Two observations that normalize within 1% are the same size; consecutive duplicates are dropped at import.
- Verdict thresholds are unchanged: ≤ −10% significant, −10..−5 moderate, −5..−1 minor, ±1 unchanged, >1 grew.

### 5.2 Sources and trust

| source | confidence | status on insert |
|---|---|---|
| fdc | 0.9 | accepted |
| curated | 1.0 | accepted |
| kroger | 0.8 (only mass/volume/count that parse; `"each"` alone is discarded) | accepted |
| crowd | from OCR gate (§6.3) | accepted if ≥ 0.8, else pending |

## 6. Backend (Cloudflare)

### 6.1 Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/product/{gtin}?locationId=` | Product + accepted observations + the last 12 `price_snapshots` for `locationId` (if given). Creates product on miss via FDC API → OFF. |
| GET | `/v1/kroger/locations?zip=` | Proxy to Kroger Locations, `filter.radiusInMiles=15`, `limit=20`. |
| GET | `/v1/kroger/product/{gtin}?locationId=` | Proxy; persists snapshot/observation when `KROGER_PERSIST=on`. |
| GET | `/v1/kroger/search?term=&locationId=` | Proxy for alternatives; results ranked by per-unit price server-side. Never persisted. |
| POST | `/v1/observations` | Crowd submission: gtin, quantity, unit_kind, raw_text, confidence, optional photo (multipart → R2). Applies gate, returns status. |
| POST | `/v1/devices` | Upsert device: apns_token, location_id, categories, watches[], signed transaction JWS. |
| GET | `/v1/feed` | Trending (curated) + recently accepted shrink observations, filterable by category. |
| GET/POST | `/v1/admin/review` | Pending submissions with photos; accept/reject. Bearer secret. Single-page HTML. |
| POST | `/v1/admin/purge-kroger` | Deletes all `price_snapshots` and `observations WHERE source='kroger'`. Bearer secret. |
| POST | `/v1/appstore/notifications` | App Store Server Notifications V2; updates `pro_until`. |

### 6.2 Cron

- `*/5 * * * *` — drain `alert_jobs`: for each unsent job, find watching devices with `pro_until > now` and `alert_enabled`, send APNs, mark sent. Max 40 pushes per invocation (50-subrequest ceiling on the proxy path is not a concern on Paid, but keep batches small for retries).
- `0 */6 * * *` — Kroger sweep (only when `KROGER_PERSIST=on`): distinct `(gtin, location_id)` pairs from `watches × devices`, batched via `filter.productId` (comma-separated, ≤50 per call). Compare new snapshot to the previous for the same pair: size decreased → `alert_jobs(kind='size_drop')`; per-unit price up ≥5% → `alert_jobs(kind='price_hike')`.
- `0 1 * * 1` — weekly digest: per category, count accepted shrink observations and curated additions in the last 7 days; one push per Pro device with a non-zero count in a subscribed category.

### 6.3 Crowd submission gate

On device, Vision `VNRecognizeTextRequest` (accurate, English) runs on the captured label. Lines matching `NET\s*(WT|WEIGHT|CONTENTS?)|e\s*\d` are parsed with the same normalizer. Confidence = 0.5 (parsed) + 0.2 (kind matches product's dominant kind) + 0.2 (within 0.5×–1.5× of the latest accepted observation) + 0.1 (OCR confidence ≥ 0.9). ≥ 0.8 → `accepted` immediately and, if smaller than the previous observation, an `alert_jobs(kind='size_drop')` row. Otherwise `pending` with the photo stored in R2 for admin review; photos are deleted on accept/reject.

### 6.4 FDC import (`scripts/fdc_import.py`)

Streams `branded_food.csv` from the latest release zip; for each row with a parseable `package_weight`, emits a product upsert and an observation (`observed_at = available_date`, falling back to `modified_date`). Dedupes consecutive equal sizes per GTIN. Output is a SQL file loaded with `wrangler d1 execute --file`. Also writes a report: rows kept, GTINs with ≥2 distinct normalized sizes, and a cross-check of the 35 curated entries (found / size agrees / disagrees). Re-run on each FDC release (April/October).

### 6.5 Push

APNs token-based auth: ES256 JWT signed with the `.p8` key via WebCrypto, cached 50 minutes. **Week-1 spike:** confirm Workers' outbound `fetch` reaches `api.push.apple.com` (HTTP/2). If not, use Firebase Cloud Messaging HTTP v1 (free; delivers to iOS via APNs) behind the same `PushSender` interface.

<TODO: fill after deploy — run the spike (`backend/spikes/apns-probe.ts`) and append one line here: `APNs spike result (YYYY-MM-DD): direct APNs from Workers returns 200 — Phase 4 ships `PUSH_PROVIDER="apns"`.` (or, if it failed, `direct APNs from Workers failed (<the error>) — Phase 4 ships `PUSH_PROVIDER="fcm"` behind the same `PushSender` interface.`). Whichever line goes here must match `PUSH_PROVIDER` in `backend/wrangler.toml`. See `docs/RELEASE_CHECKLIST.md` Step 8.>

### 6.6 Kroger client

Client-credentials token (`scope=product.compact`, 30-minute TTL) cached in KV. Attribution string `"Prices from Kroger"` returned with every proxied response for the UI. Per-device rate limit (60 proxied calls/hour via KV counter) so one user cannot exhaust the 10k/day quota. Barcodes and search terms are not logged.

## 7. iOS changes

- **`ShrunkAPIClient`** (actor) replaces `OpenFoodFactsService` and `UPCItemDBService` in the scan path; both are deleted from the app. `TrendingFeedService` now reads `/v1/feed`.
- **`ShrinkDetector`** gains kind-aware selection (§5.1) and fills `priceThen/priceNow/costPerUnitThen/costPerUnitNow` from the two most recent price snapshots when present.
- **Store picker**: zip entry → list from `/v1/kroger/locations` → saved `locationId` in `@AppStorage` and synced to `/v1/devices`. Shown in onboarding and Settings.
- **Onboarding**: welcome → pick categories → set store (skippable) → paywall with trial. `OnboardingProfile` keeps `categories` and `shopFrequency`; household/spend fields and the analyzing/reveal screens are removed.
- **ResultView**: live-price panel (regular/promo, per-unit, stock, attribution); "Confirm with a label photo" card on live-size mismatch; history chart shows all observations for Pro, latest two for free.
- **Label capture** (`Features/Contribute`): camera → OCR → confirm sheet (editable quantity + unit) → POST → toast with status.
- **Alternatives**: `AlternativesEngine` rewritten over `/v1/kroger/search`; 3 rows free, unlimited Pro; without a store, falls back to curated same-category cases labelled "Verified cases in this category".
- **Watchlist**: `WatchlistService.refreshAll` becomes a sync to `/v1/devices`; `BGAppRefresh` remains for a device-side live-size check producing `.unconfirmed` alerts. Push payloads carry `gtin` + `kind`; tapping opens the product.
- **Alerts feed**: new kinds `sizeDrop`, `priceHike`, `verifiedCase`, `digest`.
- **Savings dashboard**: `SavingsLedger` computes from real observations and snapshots; `SavingsForecast` deleted.
- **StoreKitService**: subscription group with two products; entitlement from `Transaction.currentEntitlements`; `appAccountToken` set at purchase; JWS posted to `/v1/devices`. Paywall shows trial, monthly, yearly (yearly preselected, "save 58%").

## 8. Error handling

- Backend unreachable: app shows cached last result for known products, otherwise "Couldn't reach Shrunk — check connection." No fallback to OFF from the device.
- Kroger unreachable / key revoked: live panel shows "Store prices unavailable right now"; verdict and history still render; alternatives fall back to curated. The app never blocks on Kroger.
- Product unknown everywhere: "Not in our database yet — snap the label to add it" (contribution flow).
- OCR finds no net-content line: manual entry sheet with quantity + unit.
- Subscription verification failure on the Worker: device entitlement still governs the UI; Worker logs and retries on the next `/v1/devices` upsert.

## 9. Kroger terms and mitigations

Kroger's Acceptable Use and Terms prohibit "systematically gathering response data to create a database", caching beyond response headers, and cross-retailer comparison. The user has decided to persist snapshots while a written-permission request is pending, accepting revocation risk. Mitigations built in:

- All Kroger-derived data lives in `price_snapshots` and `observations.source='kroger'`; `POST /v1/admin/purge-kroger` removes it in one command, and `KROGER_PERSIST=off` stops new writes immediately.
- No cross-retailer comparison exists (Walmart dropped).
- Attribution shown wherever Kroger data appears.
- Every other feature works without Kroger; loss of the key degrades, never breaks, the app.
- Permission email draft: Appendix A. Send in week 1.
- Permission email: Appendix A. **Sent 2026-08-27** from stackcurious@gmail.com to APISupport@kroger.com (client id `shrunkshrinkflationscanner-bbchhd1m`); no reply as of 2026-08-27. Until it is answered, `KROGER_PERSIST` stays on and `POST /v1/admin/purge-kroger` is the one-command retraction. See `docs/RELEASE_CHECKLIST.md` Step 5.

## 10. Testing

- **Normalizer** (Swift + Python, shared fixture file `fixtures/package_weights.json`): both FDC formats, every GS1 code, kind mismatches, malformed segments, the known noise case `1.53 LBR / 1.53 LTR / 52 OZA`.
- **ShrinkDetector**: kind-aware selection, thresholds, price-per-unit math.
- **OCR parser**: ~30 real label strings including "NET WT 12 OZ (340g)", "e 500 g", "NET CONTENTS 28 FL OZ (828 mL)", "12 – 12 FL OZ CANS".
- **Gate**: each confidence component, boundary at 0.8.
- **Worker** (Vitest + Miniflare): every endpoint, cron batching, purge, JWS verification with an Apple sandbox transaction, per-device rate limit.
- **iOS integration**: `ShrunkAPIClient` against a stub Worker; StoreKit configuration file for trial/monthly/yearly.
- **Acceptance before submission**: scanning all 35 curated products yields a verdict for 35/35; a 30-item kitchen scan yields history for ≥60% of food items; a Kroger store set in Cincinnati shows live prices for ≥25 of those 30.

## 11. Sequencing

| Week | Deliverable |
|---|---|
| 1 | `scripts/fdc_import.py` + normalizer + D1 schema + `/v1/product` + `ShrunkAPIClient` wired into the scanner. Hit-rate report. APNs spike. Send Kroger email. |
| 2 | Label capture, OCR, `/v1/observations`, gate, admin review page. |
| 3 | Kroger client + proxy endpoints + persistence flag, store picker, live-price panel, alternatives rewrite. |
| 4 | Push sender, `/v1/devices`, watch sync, alert/sweep/digest crons, alerts feed kinds. |
| 5 | Subscriptions + paywall, onboarding trim, dashboard rebuild, history chart gating. |
| 6 | Privacy policy, ASC listing update, TestFlight, acceptance run, submit. |

Out of scope for v1: Walmart, non-Kroger store pricing, Android, watch-by-brand UI beyond what the watchlist already captures, admin polish beyond a single page.

## Appendix A — Kroger permission request (draft)

> Subject: Permission request — retaining historical product size and price data (Shrunk iOS app)
>
> Hello Kroger Developer Relations,
>
> I'm building Shrunk, a consumer iOS app that helps shoppers notice "shrinkflation" — when a product's package gets smaller while the price stays the same. Kroger's Products API is the only official retailer source that exposes both package size and store-level price, and I'd like to use it as intended and with your permission.
>
> The app displays live Kroger prices and sizes with "Prices from Kroger" attribution. To show shoppers how a product's size and cost-per-unit have changed over time, I'd like permission to retain historical `items[].size` and `items[].price` values for products that users have added to a watchlist, keyed by UPC and store. I'm not comparing Kroger with other retailers and do not store any customer search data. Kroger would be credited on every screen where this data appears, and I'd be glad to remove the retained data on request.
>
> Client ID: [your client id]. Happy to share a TestFlight build or answer any questions.
>
> Thank you,
> [name] — stackcurious.com/shrunk
