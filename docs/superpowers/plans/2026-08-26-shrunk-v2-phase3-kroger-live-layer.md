# Shrunk v2 — Phase 3: Kroger Live Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put live Kroger store prices and sizes behind the Shrunk Worker, snapshot them into D1, and spend them in the app as a live-price panel on the result screen and a store-ranked alternatives list.

**Architecture:** A `KrogerClient` in the Worker holds a client-credentials token in KV (25 min) and fronts three proxied routes (`/v1/kroger/locations`, `/v1/kroger/product/:gtin`, `/v1/kroger/search`), each rate-limited per device, each returning `"attribution": "Prices from Kroger"` and forwarding Kroger's `Cache-Control`. When `KROGER_PERSIST=on`, a product lookup also writes a `price_snapshots` row and — only when the size actually moved — an `observations` row tagged `source='kroger'`; a six-hourly cron re-checks every known `(gtin, location_id)` pair in batches of 50 and files `alert_jobs` rows for size drops and ≥5% per-unit price rises. `POST /v1/admin/purge-kroger` erases all of it in one command. On iOS, a store picker persists a `locationId`, `ResultView` gains a live-price panel, and `AlternativesEngine` is rewritten over the store search; Open Food Facts leaves the app entirely.

**Tech Stack:** TypeScript, Hono 4, Wrangler 4, Cloudflare D1 + KV + Cron Triggers, Vitest with `@cloudflare/vitest-pool-workers` · Python 3 (stdlib) + pytest for the mirrored normalizer · Swift 5.9 / SwiftUI / XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` (§4 scan-flow steps 2 and 4, §5 `price_snapshots`, §5.2 `kroger` source, §6.1 the three `/v1/kroger/*` rows and `POST /v1/admin/purge-kroger`, §6.2 six-hourly sweep, §6.6 Kroger client, §7 store picker / ResultView live panel / alternatives, §8 Kroger-unreachable behaviour, §9 mitigations, §10 tests, §11 week 3).

**Assumes Phases 1–2 are complete:** the Hono Worker in `backend/` with `src/env.ts`, `src/db.ts`, `src/gtin.ts` (`normalizeGTIN`), `src/normalize.ts` (`parsePackageWeight`), `src/routes/product.ts` (`buildProductResponse`), Vitest wired to `env`/`fetchMock` from `cloudflare:test`; `Env.ADMIN_SECRET` plus bearer-auth admin routes under `/v1/admin/*`; iOS `Shrunk/Services/ShrunkAPIClient.swift` with `ProductDTO`/`PriceSnapshotDTO`, a kind-aware `ShrinkDetector`, and `ShrunkProduct.needsConfirmation: Bool`.

## Global Constraints

- Barcodes are stored and exchanged as **13-digit zero-padded GTINs** (spec §2). Kroger's `productId`/`upc` is a *different* 13-char form — always convert with `krogerProductId` / `gtinFromKroger` (Task 2), never by string equality.
- Quantities normalize to **grams (mass), millilitres (volume), or count**, `unit_kind ∈ {mass, volume, count}`; observations of different kinds are never compared (spec §5.1).
- Two observations within **1%** are the same size. Verdict thresholds unchanged: ≤ −10% significant, −10..−5 moderate, −5..−1 minor, ±1 unchanged, >1 grew.
- `kroger` observations: confidence **0.8**, status **accepted**, only for sizes that parse — `"each"` alone is discarded (spec §5.2).
- Every proxied response body includes `"attribution": "Prices from Kroger"`, and the route forwards Kroger's `Cache-Control` header verbatim (spec §6.6, §9).
- **Never log barcodes or search terms.** No `console.log` may receive a gtin, a Kroger productId, a `term`, or a full request path. Status codes and counts only.
- Per-device Kroger rate limit: **60 proxied calls/hour** via a KV counter (spec §6.6). Kroger's own ceilings: Products 10,000 calls/day, Locations 1,600/day.
- Kroger token: `POST https://api.kroger.com/v1/connect/oauth2/token`, `Authorization: Basic base64(client_id:client_secret)`, body `grant_type=client_credentials&scope=product.compact`; response `{access_token, expires_in: 1800, token_type: "bearer"}`. Cached in KV for **25 minutes**.
- Without `filter.locationId` Kroger returns no price and no inventory — every product/search call must carry one.
- Cloudflare **Workers Paid**. Kroger credentials are set with `wrangler secret put`, never committed. `KROGER_PERSIST` is a plain var (`"on"` | `"off"`) so persistence can be stopped without a code change.
- iOS 17+, Swift 5.9, `project.yml` is the source of truth — run `xcodegen generate` after adding or deleting any Swift file.
- Worker tests: `cd backend && npx vitest run`. iOS tests: `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'`.
- Commit after every task. Never commit `backend/node_modules`, `backend/.wrangler`, or `.dev.vars`.

## File Structure

```
fixtures/
  package_weights.json                 +3 cases: leading simple fractions
scripts/fdc/normalize.py               + leading-fraction pre-pass (mirror)
backend/
  wrangler.toml                        + KV binding, KROGER_PERSIST var, cron trigger, main = src/worker.ts
  vitest.config.ts                     + Kroger test bindings
  migrations/0003_alert_jobs.sql       alert_jobs (spec §5)
  src/env.ts                           + KV, KROGER_CLIENT_ID/SECRET, KROGER_PERSIST
  src/normalize.ts                     + leading-fraction pre-pass (mirror)
  src/worker.ts                        NEW — Workers entry: { fetch, scheduled }
  src/ratelimit.ts                     NEW — per-device hourly KV counter
  src/sweep.ts                         NEW — six-hourly Kroger sweep -> alert_jobs
  src/kroger/ids.ts                    NEW — krogerProductId / gtinFromKroger
  src/kroger/client.ts                 NEW — KV token cache + typed Kroger calls
  src/kroger/map.ts                    NEW — KrogerProduct -> LiveProduct wire shape
  src/kroger/persist.ts                NEW — snapshot + observation writes
  src/routes/kroger.ts                 NEW — the three proxy routes
  src/routes/admin-kroger.ts           NEW — POST /v1/admin/purge-kroger
  src/routes/product.ts                + needs_confirmation
  src/index.ts                         + mount kroger + admin-kroger routes
  test/kroger-ids.test.ts, kroger-client.test.ts, ratelimit.test.ts,
  test/kroger-routes.test.ts, kroger-persist.test.ts, purge.test.ts, sweep.test.ts
Shrunk/
  Models/ShrunkError.swift             MOVED out of OpenFoodFactsService.swift
  Models/StoreLocation.swift           NEW
  Models/LivePrice.swift               NEW — LivePrice, StoreSearchResult, StorePriced
  Models/Alternative.swift             rewritten — optional cost/savings, source, stock
  Models/ShrunkProduct.swift           + PricePoint, + priceHistory
  Services/KrogerDTO.swift             NEW — wire types for /v1/kroger/*
  Services/DataProviders.swift         NEW — StoreDataProviding, TrendingFeedProviding
  Services/ShrunkAPIClient.swift       + locations / liveProduct / search + deviceId
  Services/ShrinkDetector.swift        + price then/now from snapshots
  Services/AlternativesEngine.swift    rewritten over the store search
  Services/OpenFoodFactsService.swift  DELETED
  Features/Store/StorePickerView.swift, StorePickerViewModel.swift   NEW
  Features/Result/LivePricePanel.swift NEW
  Features/Result/ResultView.swift, ResultViewModel.swift            live panel + store id
  Features/Alternatives/*              AlternativesResult wiring, lock/blur removed
  Features/Onboarding/StoreStep.swift  NEW  (+ .store case in the container/VM)
  Features/Settings/SettingsView.swift + Store section
ShrunkTests/
  StubStoreData.swift                  NEW — shared stubs
  KrogerDTOTests.swift                 NEW
  AlternativesEngineTests.swift        NEW
  StorePickerViewModelTests.swift      NEW
  ShrinkDetectorTests.swift            + cost-per-unit then/now
  OpenFoodFactsServiceTests.swift      DELETED
```

---

### Task 1: Leading simple fractions in both normalizers

Kroger sizes include `"1/2 Gallon"`. Today the segment splitter breaks on `/` and yields "2 Gallon" — a 4× error. Both normalizers must expand a leading simple fraction *before* segment splitting, without breaking the real multipack format `"12/12 fl oz"`.

**Files:**
- Modify: `fixtures/package_weights.json`
- Modify: `scripts/fdc/normalize.py`
- Modify: `backend/src/normalize.ts`
- Test: `scripts/tests/test_normalize.py` (unchanged — it is fixture-driven), `backend/test/normalize.test.ts` (unchanged — fixture-driven)

**Interfaces:**
- Consumes: `parse_package_weight(raw) -> ParsedQuantity | None`, `parsePackageWeight(raw): ParsedQuantity | null` (Phase 1).
- Produces: both accept `"<num>/<den> <unit>"` when `den ∈ {2,3,4,8}` and `num < den`; everything else parses exactly as before.

- [ ] **Step 1: Add the fixture cases**

Append these three objects to the array in `fixtures/package_weights.json` (before the closing `]`, comma-separating from the current last entry):

```json
  { "input": "1/2 Gallon", "quantity": 1892.705, "unit_kind": "volume", "note": "leading simple fraction: half gallon" },
  { "input": "1/4 lb", "quantity": 113.398, "unit_kind": "mass", "note": "leading simple fraction: quarter pound" },
  { "input": "12/12 fl oz", "quantity": 354.882, "unit_kind": "volume", "note": "not a fraction: numerator equals denominator (12-pack of 12 fl oz)" }
```

- [ ] **Step 2: Run both suites to verify the new cases fail**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests/test_normalize.py -q
cd /Users/drao/Projects/shrunk/backend && npx vitest run test/normalize.test.ts
```
Expected: FAIL on "half gallon" (`7570.82 != 1892.705` — it parsed "2 Gallon") and on "quarter pound" (`1814.368 != 113.398` — it parsed "4 lb"). The "12/12 fl oz" case passes already; it is a regression guard.

- [ ] **Step 3: Implement the Python pre-pass**

In `scripts/fdc/normalize.py`, add below `_TOLERANCE = 0.02`:

```python
# "1/2 Gallon" is a fraction; "12/12 fl oz" is a 12-pack of 12 fl oz. Only a
# proper fraction with a household denominator is expanded, and only when it
# leads the string — everything else stays a "/"-separated segment list.
_LEADING_FRACTION = re.compile(r"^\s*(\d+)\s*/\s*(\d+)\s+([a-zA-Z].*)$")
_FRACTION_DENOMINATORS = {2, 3, 4, 8}


def _expand_leading_fraction(text: str) -> str:
    match = _LEADING_FRACTION.match(text)
    if not match:
        return text
    numerator, denominator = int(match.group(1)), int(match.group(2))
    if denominator not in _FRACTION_DENOMINATORS or numerator == 0 or numerator >= denominator:
        return text
    return f"{numerator / denominator} {match.group(3)}"
```

Then in `parse_package_weight`, insert one line immediately after the `if not text: return None` guard:

```python
    text = _expand_leading_fraction(text)
```

- [ ] **Step 4: Implement the TypeScript pre-pass**

In `backend/src/normalize.ts`, add below `const TOLERANCE = 0.02;`:

```ts
// "1/2 Gallon" is a fraction; "12/12 fl oz" is a 12-pack of 12 fl oz. Only a
// proper fraction with a household denominator is expanded, and only when it
// leads the string — everything else stays a "/"-separated segment list.
const LEADING_FRACTION = /^\s*(\d+)\s*\/\s*(\d+)\s+([a-zA-Z].*)$/;
const FRACTION_DENOMINATORS = new Set([2, 3, 4, 8]);

function expandLeadingFraction(text: string): string {
  const match = LEADING_FRACTION.exec(text);
  if (!match) return text;
  const numerator = parseInt(match[1], 10);
  const denominator = parseInt(match[2], 10);
  if (!FRACTION_DENOMINATORS.has(denominator) || numerator === 0 || numerator >= denominator) return text;
  return `${numerator / denominator} ${match[3]}`;
}
```

In `parsePackageWeight`, replace the two lines

```ts
  const text = raw.trim();
  if (!text) return null;
```

with

```ts
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const text = expandLeadingFraction(trimmed);
```

- [ ] **Step 5: Run both suites to verify they pass**

```bash
cd /Users/drao/Projects/shrunk/scripts && python3 -m pytest tests -q
cd /Users/drao/Projects/shrunk/backend && npx vitest run && npx tsc --noEmit
```
Expected: Python `43 passed` (31 normalize + 9 gtin + 3 importer); Vitest all green with 31 normalize cases.

- [ ] **Step 6: Commit**

```bash
cd /Users/drao/Projects/shrunk
git add fixtures/package_weights.json scripts/fdc/normalize.py backend/src/normalize.ts
git commit -m "feat(normalize): expand leading simple fractions (1/2 Gallon)"
```

---

### Task 2: Kroger productId ⇄ GTIN conversion

Kroger's `productId`/`upc` is our GTIN-13 with the leading `0` and the trailing check digit removed, left-padded back to 13. `0028400642255` (ours) ⇄ `0002840064225` (Kroger's).

**Files:**
- Create: `backend/src/kroger/ids.ts`
- Test: `backend/test/kroger-ids.test.ts`

**Interfaces:**
- Consumes: `normalizeGTIN(raw: string): string | null` from `src/gtin.ts`.
- Produces: `krogerProductId(gtin: string): string | null`, `gtinFromKroger(upc: string): string | null`, `upcCheckDigit(core11: string): string`.

- [ ] **Step 1: Write the failing test**

`backend/test/kroger-ids.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { gtinFromKroger, krogerProductId, upcCheckDigit } from "../src/kroger/ids";

const PAIRS: Array<[string, string]> = [
  ["0028400642255", "0002840064225"], // Gatorade
  ["0037000138372", "0003700013837"], // P&G
  ["0011110417008", "0001111041700"], // Kroger private label
];

describe("krogerProductId", () => {
  it.each(PAIRS)("%s -> %s", (gtin, productId) => {
    expect(krogerProductId(gtin)).toBe(productId);
  });

  it("normalizes a 12-digit UPC-A first", () => {
    expect(krogerProductId("028400642255")).toBe("0002840064225");
  });

  it("returns null for an unusable barcode", () => {
    expect(krogerProductId("12345")).toBeNull();
    expect(krogerProductId("")).toBeNull();
  });
});

describe("gtinFromKroger", () => {
  it.each(PAIRS)("%s <- %s", (gtin, productId) => {
    expect(gtinFromKroger(productId)).toBe(gtin);
  });

  it("round-trips both directions", () => {
    for (const [gtin, productId] of PAIRS) {
      expect(gtinFromKroger(krogerProductId(gtin)!)).toBe(gtin);
      expect(krogerProductId(gtinFromKroger(productId)!)).toBe(productId);
    }
  });

  it("returns null for junk", () => {
    expect(gtinFromKroger("")).toBeNull();
    expect(gtinFromKroger("00028400642255555")).toBeNull();
  });
});

describe("upcCheckDigit", () => {
  it("computes the UPC-A check digit over 11 data digits", () => {
    expect(upcCheckDigit("02840064225")).toBe("5");
    expect(upcCheckDigit("03700013837")).toBe("2");
    expect(upcCheckDigit("01111041700")).toBe("8");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/kroger-ids.test.ts`
Expected: FAIL — `Cannot find module '../src/kroger/ids'`.

- [ ] **Step 3: Implement**

`backend/src/kroger/ids.ts`:

```ts
import { normalizeGTIN } from "../gtin";

/**
 * Kroger identifies products by an 11-digit UPC-A core zero-padded to 13 —
 * our GTIN-13 with the leading zero and the check digit removed.
 *   ours 0028400642255 -> Kroger 0002840064225
 */
export function krogerProductId(gtin: string | null | undefined): string | null {
  const normalized = normalizeGTIN(gtin ?? "");
  if (!normalized) return null;
  return normalized.slice(1, -1).padStart(13, "0");
}

/** The reverse: recompute the UPC-A check digit and prefix the GTIN-13 zero. */
export function gtinFromKroger(upc: string | null | undefined): string | null {
  const digits = (upc ?? "").replace(/\D/g, "");
  if (digits.length === 0 || digits.length > 13) return null;
  const core = digits.padStart(13, "0").slice(-11);
  return `0${core}${upcCheckDigit(core)}`;
}

/** UPC-A check digit over the 11 data digits: 3x the odd positions, 1x the even. */
export function upcCheckDigit(core: string): string {
  let sum = 0;
  for (let i = 0; i < 11; i++) {
    const digit = core.charCodeAt(i) - 48;
    sum += i % 2 === 0 ? digit * 3 : digit;
  }
  return String((10 - (sum % 10)) % 10);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && npx vitest run test/kroger-ids.test.ts && npx tsc --noEmit`
Expected: `12 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/kroger/ids.ts backend/test/kroger-ids.test.ts
git commit -m "feat(kroger): GTIN <-> Kroger productId conversion"
```

---

### Task 3: Kroger bindings + KV-cached OAuth token

**Files:**
- Modify: `backend/src/env.ts`
- Modify: `backend/wrangler.toml`
- Modify: `backend/vitest.config.ts`
- Create: `backend/src/kroger/client.ts`
- Test: `backend/test/kroger-client.test.ts`

**Interfaces:**
- Produces: `Env` gains `KV: KVNamespace`, `KROGER_CLIENT_ID: string`, `KROGER_CLIENT_SECRET: string`, `KROGER_PERSIST: "on" | "off"`.
- Produces: `KROGER_ATTRIBUTION = "Prices from Kroger"`, `class KrogerError extends Error { status: number }`, `class KrogerClient { constructor(env: Env, fetchImpl?: typeof fetch); token(): Promise<string> }`.

- [ ] **Step 1: Add the bindings**

`backend/src/env.ts` — the full file after editing (keep whatever Phases 1–2 already put here; these five lines are the additions):

```ts
export interface Env {
  DB: D1Database;
  KV: KVNamespace;
  FDC_API_KEY: string;
  ADMIN_SECRET: string;
  KROGER_CLIENT_ID: string;
  KROGER_CLIENT_SECRET: string;
  KROGER_PERSIST: "on" | "off";
  ENV: string;
}
```

`backend/wrangler.toml` — add to `[vars]` and append the KV block (the real `id` is filled in by Task 11; the placeholder is fine for local dev and tests):

```toml
[vars]
ENV = "dev"
KROGER_PERSIST = "on"

[[kv_namespaces]]
binding = "KV"
id = "00000000000000000000000000000000"   # replaced in Task 11 after `wrangler kv namespace create`
```

`backend/vitest.config.ts` — extend the existing `miniflare.bindings` object:

```ts
          miniflare: {
            bindings: {
              TEST_MIGRATIONS: migrations,
              FDC_API_KEY: "test-key",
              ADMIN_SECRET: "test-admin-secret",
              KROGER_CLIENT_ID: "test-client",
              KROGER_CLIENT_SECRET: "test-secret",
              KROGER_PERSIST: "off",
            },
          },
```

(If Phase 2 already set `ADMIN_SECRET` here, leave its value alone and add only the three Kroger lines.)

- [ ] **Step 2: Write the failing test**

`backend/test/kroger-client.test.ts`:

```ts
import { env, fetchMock } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { KrogerClient, KrogerError } from "../src/kroger/client";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => {
  fetchMock.assertNoPendingInterceptors();
  fetchMock.deactivate();
});

describe("KrogerClient.token", () => {
  it("requests a client-credentials token and caches it in KV", async () => {
    fetchMock
      .get("https://api.kroger.com")
      .intercept({
        path: "/v1/connect/oauth2/token",
        method: "POST",
        body: "grant_type=client_credentials&scope=product.compact",
        headers: { authorization: `Basic ${btoa("test-client:test-secret")}` },
      })
      .reply(200, TOKEN_BODY);

    const client = new KrogerClient(env);
    expect(await client.token()).toBe("tok-123");
    expect(await env.KV.get("kroger:token")).toBe("tok-123");

    // Second call must be served from KV — a second HTTP call would fail
    // assertNoPendingInterceptors/disableNetConnect.
    expect(await client.token()).toBe("tok-123");
  });

  it("throws KrogerError with the upstream status when the token call fails", async () => {
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/connect/oauth2/token", method: "POST" })
      .reply(401, { error: "invalid_client" });

    await expect(new KrogerClient(env).token()).rejects.toMatchObject({ status: 401 });
    expect(await env.KV.get("kroger:token")).toBeNull();
  });

  it("exposes KrogerError for callers to branch on", () => {
    expect(new KrogerError(429).status).toBe(429);
    expect(new KrogerError(429)).toBeInstanceOf(Error);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/kroger-client.test.ts`
Expected: FAIL — `Cannot find module '../src/kroger/client'`.

- [ ] **Step 4: Implement the token half of the client**

`backend/src/kroger/client.ts`:

```ts
import type { Env } from "../env";

/** Shown wherever Kroger data appears (spec §6.6, §9). */
export const KROGER_ATTRIBUTION = "Prices from Kroger";

const TOKEN_KEY = "kroger:token";
const TOKEN_TTL_SECONDS = 1500; // 25 min; Kroger tokens live 1800s
const TOKEN_URL = "https://api.kroger.com/v1/connect/oauth2/token";
const API_BASE = "https://api.kroger.com/v1";

/** Carries the upstream status so routes can pass 401/429 through unchanged. */
export class KrogerError extends Error {
  constructor(public readonly status: number) {
    super(`kroger_${status}`);
    this.name = "KrogerError";
  }
}

export class KrogerClient {
  constructor(
    private readonly env: Env,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  /** Client-credentials token, cached in KV for 25 minutes. */
  async token(): Promise<string> {
    const cached = await this.env.KV.get(TOKEN_KEY);
    if (cached) return cached;

    const res = await this.fetchImpl(TOKEN_URL, {
      method: "POST",
      headers: {
        authorization: `Basic ${btoa(`${this.env.KROGER_CLIENT_ID}:${this.env.KROGER_CLIENT_SECRET}`)}`,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=client_credentials&scope=product.compact",
    });
    if (!res.ok) throw new KrogerError(res.status);

    const body = (await res.json()) as { access_token?: string };
    if (!body.access_token) throw new KrogerError(502);
    await this.env.KV.put(TOKEN_KEY, body.access_token, { expirationTtl: TOKEN_TTL_SECONDS });
    return body.access_token;
  }
}

export { API_BASE, TOKEN_KEY };
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd backend && npx vitest run test/kroger-client.test.ts && npx tsc --noEmit`
Expected: `3 passed`.

- [ ] **Step 6: Commit**

```bash
git add backend/src/env.ts backend/src/kroger/client.ts backend/wrangler.toml backend/vitest.config.ts backend/test/kroger-client.test.ts
git commit -m "feat(kroger): KV-cached client-credentials token"
```

---

### Task 4: Kroger locations, product, batch and search calls

**Files:**
- Modify: `backend/src/kroger/client.ts`
- Test: `backend/test/kroger-client.test.ts` (append)

**Interfaces:**
- Produces types `KrogerLocation`, `KrogerItem`, `KrogerProduct`, `KrogerResult<T> = { data: T; cacheControl: string | null }`.
- Produces methods on `KrogerClient`:
  - `locations(zip: string): Promise<KrogerResult<KrogerLocation[]>>`
  - `product(productId: string, locationId: string): Promise<KrogerResult<KrogerProduct | null>>`
  - `products(productIds: string[], locationId: string): Promise<KrogerResult<KrogerProduct[]>>` — comma-joined, ≤50
  - `search(term: string, locationId: string, limit?: number): Promise<KrogerResult<KrogerProduct[]>>`
- All throw `KrogerError(status)` on a non-2xx; a 401 also deletes the cached token so the next call re-authenticates.

- [ ] **Step 1: Write the failing tests**

Append to `backend/test/kroger-client.test.ts`:

```ts
function stubToken() {
  fetchMock
    .get("https://api.kroger.com")
    .intercept({ path: "/v1/connect/oauth2/token", method: "POST" })
    .reply(200, TOKEN_BODY);
}

const PRODUCT = {
  productId: "0002840064225",
  upc: "0002840064225",
  brand: "Gatorade",
  description: "Gatorade Thirst Quencher Lemon-Lime",
  categories: ["Beverages"],
  images: [{ perspective: "front", sizes: [{ size: "large", url: "https://img/large.jpg" }] }],
  items: [
    {
      itemId: "0001",
      size: "28 fl oz",
      soldBy: "UNIT",
      price: { regular: 1.89, promo: 1.5, regularPerUnitEstimate: 0.07, promoPerUnitEstimate: 0.05 },
      fulfillment: { instore: true, curbside: true, delivery: false, shiptohome: false },
      inventory: { stockLevel: "HIGH" },
    },
  ],
};

describe("KrogerClient calls", () => {
  it("fetches locations near a zip and forwards Cache-Control", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/locations?filter.zipCode.near=45044&filter.radiusInMiles=15&filter.limit=20" })
      .reply(
        200,
        { data: [{ locationId: "01400943", chain: "KROGER", name: "Hyde Park", address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" }, geolocation: { latitude: 39.14, longitude: -84.42 } }] },
        { headers: { "cache-control": "public, max-age=3600" } },
      );

    const result = await new KrogerClient(env).locations("45044");
    expect(result.data).toHaveLength(1);
    expect(result.data[0].locationId).toBe("01400943");
    expect(result.cacheControl).toBe("public, max-age=3600");
  });

  it("fetches one product at a location", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
      .reply(200, { data: PRODUCT }, { headers: { "cache-control": "private, max-age=1800" } });

    const result = await new KrogerClient(env).product("0002840064225", "01400943");
    expect(result.data?.items?.[0].price?.regular).toBe(1.89);
    expect(result.cacheControl).toBe("private, max-age=1800");
  });

  it("batches at most 50 product ids into one call", async () => {
    stubToken();
    const ids = Array.from({ length: 60 }, (_, i) => String(i).padStart(13, "0"));
    let requestedIds = "";
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: /^\/v1\/products\?filter\.productId=/ })
      .reply((options) => {
        requestedIds = decodeURIComponent(new URL(`https://api.kroger.com${options.path}`).searchParams.get("filter.productId")!);
        return { statusCode: 200, data: { data: [PRODUCT] } };
      });

    const result = await new KrogerClient(env).products(ids, "01400943");
    expect(requestedIds.split(",")).toHaveLength(50);
    expect(result.data).toHaveLength(1);
  });

  it("searches by term at a location", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products?filter.term=Beverages&filter.locationId=01400943&filter.limit=50" })
      .reply(200, { data: [PRODUCT] });

    const result = await new KrogerClient(env).search("Beverages", "01400943");
    expect(result.data[0].productId).toBe("0002840064225");
  });

  it("drops the cached token on 401 and surfaces the status", async () => {
    await env.KV.put("kroger:token", "stale-token");
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
      .reply(401, { error: "unauthorized" });

    await expect(new KrogerClient(env).product("0002840064225", "01400943")).rejects.toMatchObject({ status: 401 });
    expect(await env.KV.get("kroger:token")).toBeNull();
  });

  it("surfaces 429 so the route can pass it through", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products?filter.term=Snacks&filter.locationId=01400943&filter.limit=50" })
      .reply(429, { error: "quota" });

    await expect(new KrogerClient(env).search("Snacks", "01400943")).rejects.toMatchObject({ status: 429 });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/kroger-client.test.ts`
Expected: FAIL — `client.locations is not a function`.

- [ ] **Step 3: Implement the calls**

Add to `backend/src/kroger/client.ts`, above the `KrogerClient` class:

```ts
export interface KrogerAddress {
  addressLine1?: string;
  city?: string;
  state?: string;
  zipCode?: string;
}

export interface KrogerLocation {
  locationId: string;
  chain?: string;
  name?: string;
  address?: KrogerAddress;
  geolocation?: { latitude?: number; longitude?: number };
}

export interface KrogerItem {
  itemId?: string;
  size?: string;
  soldBy?: string;
  price?: { regular?: number; promo?: number; regularPerUnitEstimate?: number; promoPerUnitEstimate?: number };
  fulfillment?: { instore?: boolean; curbside?: boolean; delivery?: boolean; shiptohome?: boolean };
  inventory?: { stockLevel?: string };
}

export interface KrogerProduct {
  productId: string;
  upc?: string;
  brand?: string;
  description?: string;
  categories?: string[];
  images?: Array<{ perspective?: string; sizes?: Array<{ size?: string; url?: string }> }>;
  items?: KrogerItem[];
}

export interface KrogerResult<T> {
  data: T;
  cacheControl: string | null;
}

/** Kroger accepts at most 50 comma-separated productIds per call. */
export const KROGER_BATCH_LIMIT = 50;
```

and these methods inside the class, after `token()`:

```ts
  async locations(zip: string): Promise<KrogerResult<KrogerLocation[]>> {
    const result = await this.getData<KrogerLocation[]>(
      `/locations?filter.zipCode.near=${encodeURIComponent(zip)}&filter.radiusInMiles=15&filter.limit=20`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  async product(productId: string, locationId: string): Promise<KrogerResult<KrogerProduct | null>> {
    return this.getData<KrogerProduct>(
      `/products/${encodeURIComponent(productId)}?filter.locationId=${encodeURIComponent(locationId)}`,
    );
  }

  async products(productIds: string[], locationId: string): Promise<KrogerResult<KrogerProduct[]>> {
    const ids = productIds.slice(0, KROGER_BATCH_LIMIT).join(",");
    const result = await this.getData<KrogerProduct[]>(
      `/products?filter.productId=${encodeURIComponent(ids)}&filter.locationId=${encodeURIComponent(locationId)}`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  async search(term: string, locationId: string, limit = KROGER_BATCH_LIMIT): Promise<KrogerResult<KrogerProduct[]>> {
    const result = await this.getData<KrogerProduct[]>(
      `/products?filter.term=${encodeURIComponent(term)}&filter.locationId=${encodeURIComponent(locationId)}&filter.limit=${limit}`,
    );
    return { data: result.data ?? [], cacheControl: result.cacheControl };
  }

  /**
   * One authenticated GET. Never logs `path` — it carries barcodes and search
   * terms (spec §6.6).
   */
  private async getData<T>(path: string): Promise<{ data: T | null; cacheControl: string | null }> {
    const token = await this.token();
    const res = await this.fetchImpl(`${API_BASE}${path}`, {
      headers: { authorization: `Bearer ${token}`, accept: "application/json" },
    });
    if (res.status === 401) {
      // Revoked or rotated key: drop the cache so the next call re-authenticates.
      await this.env.KV.delete(TOKEN_KEY);
      throw new KrogerError(401);
    }
    if (!res.ok) throw new KrogerError(res.status);
    const body = (await res.json()) as { data?: T };
    return { data: body.data ?? null, cacheControl: res.headers.get("cache-control") };
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/kroger-client.test.ts && npx tsc --noEmit`
Expected: `9 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/kroger/client.ts backend/test/kroger-client.test.ts
git commit -m "feat(kroger): locations, product, batch and search calls"
```

---

### Task 5: Per-device hourly rate limit

**Files:**
- Create: `backend/src/ratelimit.ts`
- Test: `backend/test/ratelimit.test.ts`

**Interfaces:**
- Produces: `KROGER_HOURLY_LIMIT = 60`; `hitRateLimit(kv: KVNamespace, deviceId: string, limit?: number): Promise<{ allowed: boolean; count: number }>`; `deviceKey(req: Request): string`.

- [ ] **Step 1: Write the failing test**

`backend/test/ratelimit.test.ts`:

```ts
import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { deviceKey, hitRateLimit, KROGER_HOURLY_LIMIT } from "../src/ratelimit";

describe("hitRateLimit", () => {
  it("counts up to the limit then refuses", async () => {
    const device = `dev-${crypto.randomUUID()}`;
    for (let i = 1; i <= 3; i++) {
      expect(await hitRateLimit(env.KV, device, 3)).toEqual({ allowed: true, count: i });
    }
    expect(await hitRateLimit(env.KV, device, 3)).toEqual({ allowed: false, count: 3 });
  });

  it("counts each device separately", async () => {
    const a = `dev-${crypto.randomUUID()}`;
    const b = `dev-${crypto.randomUUID()}`;
    await hitRateLimit(env.KV, a, 1);
    expect(await hitRateLimit(env.KV, a, 1)).toMatchObject({ allowed: false });
    expect(await hitRateLimit(env.KV, b, 1)).toMatchObject({ allowed: true });
  });

  it("defaults to 60 calls per hour", () => {
    expect(KROGER_HOURLY_LIMIT).toBe(60);
  });
});

describe("deviceKey", () => {
  it("prefers X-Device-Id, then the connecting IP, then anonymous", () => {
    expect(deviceKey(new Request("https://x/", { headers: { "x-device-id": "abc" } }))).toBe("abc");
    expect(deviceKey(new Request("https://x/", { headers: { "cf-connecting-ip": "1.2.3.4" } }))).toBe("1.2.3.4");
    expect(deviceKey(new Request("https://x/"))).toBe("anonymous");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/ratelimit.test.ts`
Expected: FAIL — `Cannot find module '../src/ratelimit'`.

- [ ] **Step 3: Implement**

`backend/src/ratelimit.ts`:

```ts
/** Spec §6.6 — one device may not burn the shared 10k/day Kroger quota. */
export const KROGER_HOURLY_LIMIT = 60;

/**
 * Fixed-window counter in KV, one key per device per hour. The read-then-write
 * is not atomic: a device racing itself can slip a couple of calls over the
 * line. That is acceptable — the counter exists to stop runaway clients, not to
 * bill anyone.
 */
export async function hitRateLimit(
  kv: KVNamespace,
  deviceId: string,
  limit: number = KROGER_HOURLY_LIMIT,
): Promise<{ allowed: boolean; count: number }> {
  const bucket = Math.floor(Date.now() / 1000 / 3600);
  const key = `rl:kroger:${deviceId}:${bucket}`;
  const current = Number((await kv.get(key)) ?? "0");
  if (current >= limit) return { allowed: false, count: current };
  await kv.put(key, String(current + 1), { expirationTtl: 3600 });
  return { allowed: true, count: current + 1 };
}

/** Rate-limit identity. Contains no barcode and no search term. */
export function deviceKey(req: Request): string {
  return req.headers.get("x-device-id") ?? req.headers.get("cf-connecting-ip") ?? "anonymous";
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && npx vitest run test/ratelimit.test.ts && npx tsc --noEmit`
Expected: `4 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/ratelimit.ts backend/test/ratelimit.test.ts
git commit -m "feat(backend): per-device hourly rate limit for proxied Kroger calls"
```

---

### Task 6: Kroger response mapping + the three proxy routes

**Files:**
- Create: `backend/src/kroger/map.ts`, `backend/src/routes/kroger.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/kroger-routes.test.ts`

**Interfaces:**
- Produces (`map.ts`): `LiveProduct` — the wire shape both `/v1/kroger/product` and `/v1/kroger/search` return:

```ts
{ gtin: string | null; product_id: string; brand: string; description: string; category: string;
  image_url: string | null; size: string | null; quantity: number | null; unit_kind: string | null;
  regular: number | null; promo: number | null; per_unit_estimate: number | null;
  price_per_base_unit: number | null; stock_level: string | null }
```
  plus `toLiveProduct(p: KrogerProduct): LiveProduct`, `frontImage(p): string | null`, `effectivePrice(item): number | null`.
  `quantity`/`unit_kind` come from `parsePackageWeight(items[0].size)` and are `null` when the size does not parse (`"each"`). `per_unit_estimate` is Kroger's own estimate (display only, their unit); `price_per_base_unit` is ours — effective price ÷ quantity in g/mL/count — and is what ranking uses.
- Produces (`routes/kroger.ts`): `krogerRoute` — a `Hono<{ Bindings: Env }>` exporting
  - `GET /v1/kroger/locations?zip=` → `{ locations: [{ locationId, chain, name, address: { addressLine1, city, state, zipCode }, geolocation: { latitude, longitude } }], attribution }`
  - `GET /v1/kroger/product/:gtin?locationId=` → `LiveProduct & { gtin, location_id, attribution }`
  - `GET /v1/kroger/search?term=&locationId=` → `{ results: LiveProduct[], attribution }`, sorted by `price_per_base_unit` ascending (nulls last), **never persisted** (spec §6.1)
  - 400 `{error:"invalid_zip"|"invalid_gtin"|"missing_location"|"missing_term"}`, 404 `{error:"not_found"}`, 429 `{error:"rate_limited"}`, 401/429 upstream passthrough as `{error:"kroger_upstream",status}`, anything else 502.

Persistence is added in Task 7 — this task leaves a marked hook.

- [ ] **Step 1: Write the failing tests**

`backend/test/kroger-routes.test.ts`:

```ts
import { env, fetchMock } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };

const PRODUCT = {
  productId: "0002840064225",
  upc: "0002840064225",
  brand: "Gatorade",
  description: "Gatorade Thirst Quencher Lemon-Lime",
  categories: ["Beverages"],
  images: [{ perspective: "front", sizes: [{ size: "large", url: "https://img/large.jpg" }] }],
  items: [
    {
      itemId: "0001",
      size: "28 fl oz",
      price: { regular: 1.89, promo: 1.5, regularPerUnitEstimate: 0.07, promoPerUnitEstimate: 0.05 },
      inventory: { stockLevel: "HIGH" },
    },
  ],
};

/** A fresh device per test so the 60/hour counter never leaks across tests. */
function headers() {
  return { "X-Device-Id": `dev-${crypto.randomUUID()}` };
}

function stubToken() {
  fetchMock.get("https://api.kroger.com").intercept({ path: "/v1/connect/oauth2/token", method: "POST" }).reply(200, TOKEN_BODY);
}

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.deactivate());

describe("GET /v1/kroger/locations", () => {
  it("returns mapped locations with attribution and the upstream cache header", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/locations?filter.zipCode.near=45044&filter.radiusInMiles=15&filter.limit=20" })
      .reply(
        200,
        { data: [{ locationId: "01400943", chain: "KROGER", name: "Hyde Park", address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" }, geolocation: { latitude: 39.14, longitude: -84.42 } }] },
        { headers: { "cache-control": "public, max-age=3600" } },
      );

    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const body = await res.json<any>();
    expect(body.attribution).toBe("Prices from Kroger");
    expect(body.locations[0]).toEqual({
      locationId: "01400943",
      chain: "KROGER",
      name: "Hyde Park",
      address: { addressLine1: "3760 Paxton Ave", city: "Cincinnati", state: "OH", zipCode: "45209" },
      geolocation: { latitude: 39.14, longitude: -84.42 },
    });
  });

  it("rejects a malformed zip without calling Kroger", async () => {
    const res = await app.request("/v1/kroger/locations?zip=abc", { headers: headers() }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_zip" });
  });
});

describe("GET /v1/kroger/product/:gtin", () => {
  it("maps price, size, stock and image and echoes the gtin we were asked for", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
      .reply(200, { data: PRODUCT }, { headers: { "cache-control": "private, max-age=1800" } });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("private, max-age=1800");
    expect(await res.json<any>()).toMatchObject({
      gtin: "0028400642255",
      location_id: "01400943",
      product_id: "0002840064225",
      brand: "Gatorade",
      category: "Beverages",
      image_url: "https://img/large.jpg",
      size: "28 fl oz",
      quantity: 828.058,
      unit_kind: "volume",
      regular: 1.89,
      promo: 1.5,
      per_unit_estimate: 0.05,
      stock_level: "HIGH",
      attribution: "Prices from Kroger",
    });
  });

  it("400s without a locationId (Kroger returns no price without one)", async () => {
    const res = await app.request("/v1/kroger/product/0028400642255", { headers: headers() }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "missing_location" });
  });

  it("404s when Kroger does not carry the product", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
      .reply(404, { errors: { code: "PRODUCT-NOT-FOUND" } });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });

  it("passes a revoked key (401) through", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
      .reply(401, { error: "unauthorized" });

    const res = await app.request("/v1/kroger/product/0028400642255?locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "kroger_upstream", status: 401 });
  });
});

describe("GET /v1/kroger/search", () => {
  it("ranks by price per base unit, cheapest first", async () => {
    stubToken();
    const cheap = { ...PRODUCT, productId: "0002840064226", upc: "0002840064226", description: "Store Brand", items: [{ size: "32 fl oz", price: { regular: 1.0, promo: 0 }, inventory: { stockLevel: "HIGH" } }] };
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products?filter.term=Beverages&filter.locationId=01400943&filter.limit=50" })
      .reply(200, { data: [PRODUCT, cheap] }, { headers: { "cache-control": "private, max-age=1800" } });

    const res = await app.request("/v1/kroger/search?term=Beverages&locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("private, max-age=1800");
    const body = await res.json<any>();
    expect(body.attribution).toBe("Prices from Kroger");
    expect(body.results.map((r: any) => r.description)).toEqual(["Store Brand", "Gatorade Thirst Quencher Lemon-Lime"]);
    expect(body.results[0].price_per_base_unit).toBeCloseTo(1.0 / 946.353, 6);
  });

  it("passes a quota error (429) through", async () => {
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products?filter.term=Snacks&filter.locationId=01400943&filter.limit=50" })
      .reply(429, { error: "quota" });

    const res = await app.request("/v1/kroger/search?term=Snacks&locationId=01400943", { headers: headers() }, env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "kroger_upstream", status: 429 });
  });

  it("never persists search results", async () => {
    const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    stubToken();
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: "/v1/products?filter.term=Dairy&filter.locationId=01400943&filter.limit=50" })
      .reply(200, { data: [PRODUCT] });

    await app.request("/v1/kroger/search?term=Dairy&locationId=01400943", { headers: headers() }, { ...env, KROGER_PERSIST: "on" });
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    expect(after!.n).toBe(before!.n);
  });
});

describe("per-device rate limit", () => {
  it("429s once the device is over the hourly limit, without calling Kroger", async () => {
    const device = `dev-${crypto.randomUUID()}`;
    const bucket = Math.floor(Date.now() / 1000 / 3600);
    await env.KV.put(`rl:kroger:${device}:${bucket}`, "60", { expirationTtl: 3600 });

    const res = await app.request("/v1/kroger/locations?zip=45044", { headers: { "X-Device-Id": device } }, env);
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/kroger-routes.test.ts`
Expected: FAIL — every request 404s from Hono's default handler.

- [ ] **Step 3: Implement the mapper**

`backend/src/kroger/map.ts`:

```ts
import { parsePackageWeight } from "../normalize";
import type { KrogerItem, KrogerProduct } from "./client";
import { gtinFromKroger } from "./ids";

/** The shape both /v1/kroger/product and /v1/kroger/search return. */
export interface LiveProduct {
  gtin: string | null;
  product_id: string;
  brand: string;
  description: string;
  category: string;
  image_url: string | null;
  size: string | null;
  quantity: number | null;   // grams | millilitres | count
  unit_kind: string | null;  // mass | volume | count
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;   // Kroger's own estimate, in Kroger's unit — display only
  price_per_base_unit: number | null; // ours: effective price / quantity — ranking uses this
  stock_level: string | null;
}

export function frontImage(product: KrogerProduct): string | null {
  const front = product.images?.find((i) => i.perspective === "front") ?? product.images?.[0];
  const sizes = front?.sizes ?? [];
  const chosen = sizes.find((s) => s.size === "large") ?? sizes.find((s) => s.size === "medium") ?? sizes[0];
  return chosen?.url ?? null;
}

/** Promo when there is one, otherwise the regular shelf price. */
export function effectivePrice(item: KrogerItem | undefined): number | null {
  const promo = item?.price?.promo ?? 0;
  if (promo > 0) return promo;
  const regular = item?.price?.regular ?? 0;
  return regular > 0 ? regular : null;
}

function perUnitEstimate(item: KrogerItem | undefined): number | null {
  const promo = item?.price?.promoPerUnitEstimate ?? 0;
  if (promo > 0) return promo;
  const regular = item?.price?.regularPerUnitEstimate ?? 0;
  return regular > 0 ? regular : null;
}

export function toLiveProduct(product: KrogerProduct): LiveProduct {
  const item = product.items?.[0];
  const parsed = item?.size ? parsePackageWeight(item.size) : null;
  const price = effectivePrice(item);

  return {
    gtin: gtinFromKroger(product.upc ?? product.productId),
    product_id: product.productId,
    brand: (product.brand ?? "").trim(),
    description: (product.description ?? "").trim(),
    category: (product.categories?.[0] ?? "").trim(),
    image_url: frontImage(product),
    size: item?.size ?? null,
    quantity: parsed?.quantity ?? null,
    unit_kind: parsed?.unitKind ?? null,
    regular: item?.price?.regular ?? null,
    promo: item?.price?.promo ?? null,
    per_unit_estimate: perUnitEstimate(item),
    price_per_base_unit: price !== null && parsed && parsed.quantity > 0 ? price / parsed.quantity : null,
    stock_level: item?.inventory?.stockLevel ?? null,
  };
}
```

- [ ] **Step 4: Implement the routes**

`backend/src/routes/kroger.ts`:

```ts
import { Hono, type Context } from "hono";
import type { Env } from "../env";
import { normalizeGTIN } from "../gtin";
import { KROGER_ATTRIBUTION, KrogerClient, KrogerError } from "../kroger/client";
import { krogerProductId } from "../kroger/ids";
import { toLiveProduct } from "../kroger/map";
import { deviceKey, hitRateLimit } from "../ratelimit";

type Ctx = Context<{ Bindings: Env }>;

export const krogerRoute = new Hono<{ Bindings: Env }>();

// One shared quota protects the whole /v1/kroger/* surface (spec §6.6).
krogerRoute.use("/v1/kroger/*", async (c, next) => {
  const { allowed } = await hitRateLimit(c.env.KV, deviceKey(c.req.raw));
  if (!allowed) return c.json({ error: "rate_limited" }, 429);
  await next();
});

/**
 * 401 (key revoked) and 429 (quota) reach the app unchanged so it can show
 * "Store prices unavailable right now" (spec §8); everything else is a 502.
 */
function upstreamError(c: Ctx, err: unknown): Response {
  const status = err instanceof KrogerError ? err.status : 0;
  if (status === 401) return c.json({ error: "kroger_upstream", status: 401 }, 401);
  if (status === 429) return c.json({ error: "kroger_upstream", status: 429 }, 429);
  return c.json({ error: "kroger_upstream", status }, 502);
}

krogerRoute.get("/v1/kroger/locations", async (c) => {
  const zip = (c.req.query("zip") ?? "").replace(/\D/g, "");
  if (zip.length !== 5) return c.json({ error: "invalid_zip" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).locations(zip);
    c.header("Cache-Control", cacheControl ?? "public, max-age=3600");
    return c.json({
      locations: data.map((l) => ({
        locationId: l.locationId,
        chain: l.chain ?? "",
        name: l.name ?? "",
        address: {
          addressLine1: l.address?.addressLine1 ?? "",
          city: l.address?.city ?? "",
          state: l.address?.state ?? "",
          zipCode: l.address?.zipCode ?? "",
        },
        geolocation: { latitude: l.geolocation?.latitude ?? null, longitude: l.geolocation?.longitude ?? null },
      })),
      attribution: KROGER_ATTRIBUTION,
    });
  } catch (err) {
    return upstreamError(c, err);
  }
});

krogerRoute.get("/v1/kroger/product/:gtin", async (c) => {
  const gtin = normalizeGTIN(c.req.param("gtin"));
  if (!gtin) return c.json({ error: "invalid_gtin" }, 400);
  const locationId = c.req.query("locationId") ?? "";
  if (!locationId) return c.json({ error: "missing_location" }, 400);

  const productId = krogerProductId(gtin);
  if (!productId) return c.json({ error: "invalid_gtin" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).product(productId, locationId);
    if (!data) return c.json({ error: "not_found" }, 404);

    const live = toLiveProduct(data);
    // PERSISTENCE HOOK — Task 7 inserts the snapshot/observation write here.
    c.header("Cache-Control", cacheControl ?? "no-store");
    return c.json({ ...live, gtin, location_id: locationId, attribution: KROGER_ATTRIBUTION });
  } catch (err) {
    if (err instanceof KrogerError && err.status === 404) return c.json({ error: "not_found" }, 404);
    return upstreamError(c, err);
  }
});

krogerRoute.get("/v1/kroger/search", async (c) => {
  const term = (c.req.query("term") ?? "").trim();
  if (!term) return c.json({ error: "missing_term" }, 400);
  const locationId = c.req.query("locationId") ?? "";
  if (!locationId) return c.json({ error: "missing_location" }, 400);

  try {
    const { data, cacheControl } = await new KrogerClient(c.env).search(term, locationId);
    // Search results are proxied only — never written to D1 (spec §6.1).
    const results = data
      .map(toLiveProduct)
      .filter((p) => p.regular !== null || p.promo !== null)
      .sort((a, b) => (a.price_per_base_unit ?? Infinity) - (b.price_per_base_unit ?? Infinity));

    c.header("Cache-Control", cacheControl ?? "no-store");
    return c.json({ results, attribution: KROGER_ATTRIBUTION });
  } catch (err) {
    return upstreamError(c, err);
  }
});
```

`backend/src/index.ts` — mount it (keep the routes Phases 1–2 already mounted):

```ts
import { krogerRoute } from "./routes/kroger";
// ...
app.route("/", krogerRoute);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/kroger-routes.test.ts && npx tsc --noEmit`
Expected: `10 passed`.

- [ ] **Step 6: Commit**

```bash
git add backend/src/kroger/map.ts backend/src/routes/kroger.ts backend/src/index.ts backend/test/kroger-routes.test.ts
git commit -m "feat(backend): /v1/kroger locations, product and search proxy routes"
```

---

### Task 7: Persist snapshots and Kroger observations behind `KROGER_PERSIST`

**Files:**
- Create: `backend/src/kroger/persist.ts`
- Modify: `backend/src/routes/kroger.ts` (replace the persistence hook)
- Test: `backend/test/kroger-persist.test.ts`

**Interfaces:**
- Consumes: `insertProduct(db, row: ProductRow)` from `src/db.ts`; `LiveProduct` from `src/kroger/map.ts`; `parsePackageWeight`.
- Produces: `persistKrogerProduct(env: Env, gtin: string, locationId: string, live: LiveProduct, now?: number): Promise<void>` — always inserts a `price_snapshots` row; inserts an `observations` row (`source='kroger'`, confidence `0.8`, status `accepted`, `source_ref = locationId`) only when the parsed size differs by more than 1% from the newest accepted same-kind observation, or when there is no such observation yet.
- Produces: `snapshotPerUnit(row): number | null` — Kroger's `per_unit_estimate` when positive, else effective price ÷ parsed quantity, else `null`. Used by the sweep in Task 10.

- [ ] **Step 1: Write the failing tests**

`backend/test/kroger-persist.test.ts`:

```ts
import { env, fetchMock } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { snapshotPerUnit } from "../src/kroger/persist";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };
const GTIN = "0028400642255";

function product(size: string, regular = 1.89) {
  return {
    productId: "0002840064225",
    upc: "0002840064225",
    brand: "Gatorade",
    description: "Gatorade Thirst Quencher",
    categories: ["Beverages"],
    items: [{ size, price: { regular, promo: 0, regularPerUnitEstimate: 0.07 }, inventory: { stockLevel: "HIGH" } }],
  };
}

function stub(size: string, regular = 1.89) {
  fetchMock.get("https://api.kroger.com").intercept({ path: "/v1/connect/oauth2/token", method: "POST" }).reply(200, TOKEN_BODY);
  fetchMock
    .get("https://api.kroger.com")
    .intercept({ path: "/v1/products/0002840064225?filter.locationId=01400943" })
    .reply(200, { data: product(size, regular) });
}

const call = (persist: "on" | "off") =>
  app.request(
    `/v1/kroger/product/${GTIN}?locationId=01400943`,
    { headers: { "X-Device-Id": `dev-${crypto.randomUUID()}` } },
    { ...env, KROGER_PERSIST: persist },
  );

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  await env.DB.batch([
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.deactivate());

describe("KROGER_PERSIST", () => {
  it("writes nothing when off", async () => {
    stub("28 fl oz");
    expect((await call("off")).status).toBe(200);
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations").first<{ n: number }>();
    expect([snaps!.n, obs!.n]).toEqual([0, 0]);
  });

  it("writes a snapshot, the product row and a kroger observation when on", async () => {
    stub("28 fl oz");
    expect((await call("on")).status).toBe(200);

    const snap = await env.DB.prepare("SELECT * FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<any>();
    expect(snap).toMatchObject({ location_id: "01400943", regular: 1.89, promo: 0, per_unit_estimate: 0.07, size_raw: "28 fl oz", stock_level: "HIGH" });

    const obs = await env.DB.prepare("SELECT * FROM observations WHERE gtin = ?").bind(GTIN).first<any>();
    expect(obs).toMatchObject({ quantity: 828.058, unit_kind: "volume", raw_text: "28 fl oz", source: "kroger", source_ref: "01400943", confidence: 0.8, status: "accepted" });

    const row = await env.DB.prepare("SELECT name FROM products WHERE gtin = ?").bind(GTIN).first<{ name: string }>();
    expect(row?.name).toBe("Gatorade Thirst Quencher");
  });

  it("does not duplicate an observation when the size has not moved", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
    await env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN).run();

    stub("28 fl oz");
    await call("on");

    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(obs!.n).toBe(1);
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(snaps!.n).toBe(1); // the snapshot is always written
  });

  it("records an observation when the size moved more than 1%", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
    await env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1600000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN).run();

    stub("28 fl oz");
    await call("on");

    const rows = await env.DB.prepare("SELECT source, quantity FROM observations WHERE gtin = ? ORDER BY id").bind(GTIN).all<any>();
    expect(rows.results.map((r) => r.source)).toEqual(["fdc", "kroger"]);
    expect(rows.results[1].quantity).toBeCloseTo(828.058, 3);
  });

  it("writes a snapshot but no observation when the size is unparseable", async () => {
    stub("each");
    await call("on");
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    const obs = await env.DB.prepare("SELECT COUNT(*) AS n FROM observations WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect([snaps!.n, obs!.n]).toEqual([1, 0]);
  });
});

describe("snapshotPerUnit", () => {
  it("prefers Kroger's estimate", () => {
    expect(snapshotPerUnit({ regular: 1.89, promo: null, per_unit_estimate: 0.07, size_raw: "28 fl oz" })).toBe(0.07);
  });

  it("falls back to effective price over parsed quantity", () => {
    expect(snapshotPerUnit({ regular: 1.89, promo: 1.5, per_unit_estimate: null, size_raw: "28 fl oz" })).toBeCloseTo(1.5 / 828.058, 8);
  });

  it("is null without a usable price or size", () => {
    expect(snapshotPerUnit({ regular: null, promo: null, per_unit_estimate: null, size_raw: "28 fl oz" })).toBeNull();
    expect(snapshotPerUnit({ regular: 1.89, promo: null, per_unit_estimate: null, size_raw: "each" })).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/kroger-persist.test.ts`
Expected: FAIL — `Cannot find module '../src/kroger/persist'`.

- [ ] **Step 3: Implement**

`backend/src/kroger/persist.ts`:

```ts
import { insertProduct } from "../db";
import type { Env } from "../env";
import { parsePackageWeight } from "../normalize";
import type { LiveProduct } from "./map";

/** Spec §5.1 — two sizes within 1% are the same size. */
const SAME_SIZE_TOLERANCE = 0.01;

/**
 * Kroger-derived writes. Everything this function touches is removable by
 * `POST /v1/admin/purge-kroger`, and it is only ever called when
 * `KROGER_PERSIST === "on"` (spec §9).
 */
export async function persistKrogerProduct(
  env: Env,
  gtin: string,
  locationId: string,
  live: LiveProduct,
  now: number = Math.floor(Date.now() / 1000),
): Promise<void> {
  // observations.gtin references products.gtin — make sure the row exists.
  // INSERT OR IGNORE, so an FDC/curated row keeps its own name and category.
  await insertProduct(env.DB, {
    gtin,
    name: live.description,
    brand: live.brand,
    category: live.category,
    image_url: live.image_url,
    unit_kind: live.unit_kind,
  });

  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(gtin, locationId, live.regular, live.promo, live.per_unit_estimate, live.size, live.stock_level, now)
    .run();

  // "each" alone carries no quantity — no observation (spec §5.2).
  if (live.quantity === null || live.unit_kind === null) return;

  const latest = await env.DB.prepare(
    "SELECT quantity FROM observations WHERE gtin = ? AND status = 'accepted' AND unit_kind = ? ORDER BY observed_at DESC, id DESC LIMIT 1",
  )
    .bind(gtin, live.unit_kind)
    .first<{ quantity: number }>();

  if (latest && latest.quantity > 0 && Math.abs(live.quantity - latest.quantity) / latest.quantity <= SAME_SIZE_TOLERANCE) {
    return; // same size we already know — nothing new to record
  }

  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, ?, ?, 'kroger', ?, 0.8, 'accepted', ?)",
  )
    .bind(gtin, live.quantity, live.unit_kind, live.size, now, locationId, now)
    .run();
}

/** Comparable $/unit for one snapshot row, or null when we cannot derive one. */
export function snapshotPerUnit(row: {
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
}): number | null {
  if (row.per_unit_estimate !== null && row.per_unit_estimate > 0) return row.per_unit_estimate;
  const price = row.promo !== null && row.promo > 0 ? row.promo : row.regular;
  if (price === null || price <= 0) return null;
  const parsed = row.size_raw ? parsePackageWeight(row.size_raw) : null;
  if (!parsed || parsed.quantity <= 0) return null;
  return price / parsed.quantity;
}
```

In `backend/src/routes/kroger.ts`, add the import and replace the hook comment:

```ts
import { persistKrogerProduct } from "../kroger/persist";
```

```ts
    const live = toLiveProduct(data);
    if (c.env.KROGER_PERSIST === "on") {
      await persistKrogerProduct(c.env, gtin, locationId, live);
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: `kroger-persist.test.ts` `8 passed`, and every earlier suite still green.

- [ ] **Step 5: Commit**

```bash
git add backend/src/kroger/persist.ts backend/src/routes/kroger.ts backend/test/kroger-persist.test.ts
git commit -m "feat(backend): snapshot and observe Kroger lookups behind KROGER_PERSIST"
```

---

### Task 8: `needs_confirmation` on `/v1/product`

Spec §4 step 4: when the live Kroger size disagrees with what every other source says, the app offers "Confirm with a label photo". The Worker decides; the app only renders.

**Files:**
- Modify: `backend/src/routes/product.ts`
- Test: `backend/test/product.test.ts` (append)

**Interfaces:**
- Produces: `needsConfirmation(observations: ObservationRow[]): boolean` — `true` when the newest accepted `source='kroger'` observation and the newest accepted non-Kroger observation of the **same** `unit_kind` differ by more than 1%.
- Produces: `GET /v1/product/:gtin` response gains `"needs_confirmation": boolean` (always present).

- [ ] **Step 1: Write the failing tests**

Append inside the `describe("GET /v1/product/:gtin", ...)` block in `backend/test/product.test.ts`:

```ts
  async function seedObservation(gtin: string, quantity: number, source: string, observedAt: number, unitKind = "mass") {
    await env.DB.prepare(
      "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, '', ?, ?, 'ref', 0.8, 'accepted', 1)",
    ).bind(gtin, quantity, unitKind, observedAt, source).run();
  }

  it("flags needs_confirmation when the newest Kroger size disagrees with the newest other source", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 340.194, "fdc", 1600000000);
    await seedObservation("0028400642255", 311.844, "kroger", 1700000000);

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect((await res.json<any>()).needs_confirmation).toBe(true);
  });

  it("does not flag when the sizes agree within 1%", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 340.194, "fdc", 1600000000);
    await seedObservation("0028400642255", 340.5, "kroger", 1700000000);

    const res = await app.request("/v1/product/0028400642255", {}, env);
    expect((await res.json<any>()).needs_confirmation).toBe(false);
  });

  it("does not flag across unit kinds or without a Kroger observation", async () => {
    await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES ('0028400642255','G','G','Snacks',NULL,'mass',1,1)").run();
    await seedObservation("0028400642255", 12, "fdc", 1600000000, "count");
    await seedObservation("0028400642255", 311.844, "kroger", 1700000000, "mass");

    const mixed = await app.request("/v1/product/0028400642255", {}, env);
    expect((await mixed.json<any>()).needs_confirmation).toBe(false);

    await env.DB.prepare("DELETE FROM observations WHERE source = 'kroger'").run();
    const noKroger = await app.request("/v1/product/0028400642255", {}, env);
    expect((await noKroger.json<any>()).needs_confirmation).toBe(false);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && npx vitest run test/product.test.ts`
Expected: FAIL — `expected undefined to be true`.

- [ ] **Step 3: Implement**

In `backend/src/routes/product.ts`, extend the import from `../db` with `type ObservationRow`, then replace `buildProductResponse` and add the helper:

```ts
export async function buildProductResponse(db: D1Database, product: ProductRow, locationId: string | null) {
  const observations = await getAcceptedObservations(db, product.gtin);
  const price_snapshots = locationId ? await getRecentSnapshots(db, product.gtin, locationId) : [];
  return { ...product, observations, price_snapshots, needs_confirmation: needsConfirmation(observations) };
}

/**
 * Spec §4 step 4 — the live Kroger size disagrees with everything else we know,
 * so the app should ask for a label photo. Observations arrive oldest-first.
 */
export function needsConfirmation(observations: ObservationRow[]): boolean {
  const newest = (match: (o: ObservationRow) => boolean) => [...observations].reverse().find(match) ?? null;
  const kroger = newest((o) => o.source === "kroger");
  if (!kroger) return false;
  const other = newest((o) => o.source !== "kroger" && o.unit_kind === kroger.unit_kind);
  if (!other || other.quantity <= 0) return false;
  return Math.abs(kroger.quantity - other.quantity) / other.quantity > 0.01;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd backend && npx vitest run test/product.test.ts && npx tsc --noEmit`
Expected: all product tests pass, including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add backend/src/routes/product.ts backend/test/product.test.ts
git commit -m "feat(backend): needs_confirmation when Kroger and other sources disagree"
```

---

### Task 9: `POST /v1/admin/purge-kroger`

The one-command escape hatch spec §9 promises: every Kroger-derived row gone.

**Files:**
- Create: `backend/src/routes/admin-kroger.ts`
- Modify: `backend/src/index.ts`
- Test: `backend/test/purge.test.ts`

**Interfaces:**
- Produces: `adminKrogerRoute` — `POST /v1/admin/purge-kroger`, `Authorization: Bearer <ADMIN_SECRET>`, returns `{ deleted: { price_snapshots: number, observations: number } }`; 401 `{error:"unauthorized"}` without a valid bearer.
- The bearer check is deliberately local to this file: the purge must keep working regardless of what happens to the Phase 2 review page.

- [ ] **Step 1: Write the failing test**

`backend/test/purge.test.ts`:

```ts
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const GTIN = "0028400642255";

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  await env.DB.prepare("INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
  await env.DB.batch([
    env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, '01400943', 1.89, 0, 0.07, '28 fl oz', 'HIGH', 1700000000)").bind(GTIN),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1700000000, 'kroger', '01400943', 0.8, 'accepted', 1)").bind(GTIN),
    env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1600000000, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN),
  ]);
});

describe("POST /v1/admin/purge-kroger", () => {
  it("deletes every snapshot and every kroger observation, keeping the rest", async () => {
    const res = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer test-admin-secret" } }, env);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ deleted: { price_snapshots: 1, observations: 1 } });

    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    const rows = await env.DB.prepare("SELECT source FROM observations").all<{ source: string }>();
    expect(snaps!.n).toBe(0);
    expect(rows.results.map((r) => r.source)).toEqual(["fdc"]);
  });

  it("rejects a missing or wrong bearer", async () => {
    const anonymous = await app.request("/v1/admin/purge-kroger", { method: "POST" }, env);
    expect(anonymous.status).toBe(401);
    expect(await anonymous.json()).toEqual({ error: "unauthorized" });

    const wrong = await app.request("/v1/admin/purge-kroger", { method: "POST", headers: { authorization: "Bearer nope" } }, env);
    expect(wrong.status).toBe(401);

    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots").first<{ n: number }>();
    expect(snaps!.n).toBe(1);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/purge.test.ts`
Expected: FAIL — 404 from Hono's default handler.

- [ ] **Step 3: Implement**

`backend/src/routes/admin-kroger.ts`:

```ts
import { Hono } from "hono";
import type { Env } from "../env";

export const adminKrogerRoute = new Hono<{ Bindings: Env }>();

/**
 * Spec §9 — one command removes every Kroger-derived row. Kept independent of
 * the Phase 2 admin review page on purpose: this is the lever we pull if Kroger
 * ever objects, and it must not depend on anything else still working.
 */
adminKrogerRoute.post("/v1/admin/purge-kroger", async (c) => {
  const expected = `Bearer ${c.env.ADMIN_SECRET}`;
  if (!c.env.ADMIN_SECRET || c.req.header("authorization") !== expected) {
    return c.json({ error: "unauthorized" }, 401);
  }

  const snapshots = await c.env.DB.prepare("DELETE FROM price_snapshots").run();
  const observations = await c.env.DB.prepare("DELETE FROM observations WHERE source = 'kroger'").run();

  return c.json({
    deleted: {
      price_snapshots: snapshots.meta.changes ?? 0,
      observations: observations.meta.changes ?? 0,
    },
  });
});
```

`backend/src/index.ts`:

```ts
import { adminKrogerRoute } from "./routes/admin-kroger";
// ...
app.route("/", adminKrogerRoute);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && npx vitest run test/purge.test.ts && npx tsc --noEmit`
Expected: `2 passed`.

- [ ] **Step 5: Commit**

```bash
git add backend/src/routes/admin-kroger.ts backend/src/index.ts backend/test/purge.test.ts
git commit -m "feat(backend): POST /v1/admin/purge-kroger removes all Kroger-derived rows"
```

---

### Task 10: `alert_jobs` + the six-hourly Kroger sweep

**Files:**
- Create: `backend/migrations/0003_alert_jobs.sql`
- Create: `backend/src/sweep.ts`, `backend/src/worker.ts`
- Modify: `backend/wrangler.toml`
- Test: `backend/test/sweep.test.ts`

**Interfaces:**
- Consumes: `KrogerClient.products`, `krogerProductId`, `gtinFromKroger`, `toLiveProduct`, `persistKrogerProduct`, `snapshotPerUnit`, `parsePackageWeight`.
- Produces: `runKrogerSweep(env: Env, client?: KrogerClient): Promise<SweepResult>` with `SweepResult = { pairs: number; snapshots: number; sizeDrops: number; priceHikes: number }`.
- Produces: `backend/src/worker.ts` default export `{ fetch, scheduled }` — the new Workers entry (`wrangler.toml` `main`). `src/index.ts` keeps default-exporting the Hono `app`, so every existing test's `import app from "../src/index"` is untouched.
- Produces: table `alert_jobs(id, kind, gtin, brand, location_id, payload, created_at, sent_at)`; this phase writes `kind ∈ {size_drop, price_hike}`. Phase 4 drains it.
- **Scope note:** `watches` and `devices` do not exist until Phase 4, so this sweep iterates the distinct `(gtin, location_id)` pairs already present in `price_snapshots`. Phase 4 replaces that one query with `watches × devices`.

- [ ] **Step 1: Add the migration**

Confirm the next free number first: `ls backend/migrations` (Phase 1 wrote `0001_init.sql`, Phase 2 `0002_*`). Create `backend/migrations/0003_alert_jobs.sql` — if your listing shows a different next number, use it and adjust the filename below.

```sql
CREATE TABLE alert_jobs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  kind        TEXT NOT NULL,
  gtin        TEXT,
  brand       TEXT,
  location_id TEXT,
  payload     TEXT,
  created_at  INTEGER NOT NULL,
  sent_at     INTEGER
);
CREATE INDEX alert_jobs_unsent ON alert_jobs(sent_at, created_at);
```

- [ ] **Step 2: Write the failing test**

`backend/test/sweep.test.ts`:

```ts
import { env, fetchMock } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { runKrogerSweep } from "../src/sweep";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };
const GTIN = "0028400642255";
const LOCATION = "01400943";

function stubBatch(size: string, perUnit: number, regular = 4.0) {
  fetchMock.get("https://api.kroger.com").intercept({ path: "/v1/connect/oauth2/token", method: "POST" }).reply(200, TOKEN_BODY);
  fetchMock
    .get("https://api.kroger.com")
    .intercept({ path: /^\/v1\/products\?filter\.productId=/ })
    .reply(200, {
      data: [
        {
          productId: "0002840064225",
          upc: "0002840064225",
          brand: "Gatorade",
          description: "Gatorade Thirst Quencher",
          categories: ["Beverages"],
          items: [{ size, price: { regular, promo: 0, regularPerUnitEstimate: perUnit }, inventory: { stockLevel: "HIGH" } }],
        },
      ],
    });
}

/** Seed the previous snapshot the sweep will compare against. */
async function seedSnapshot(sizeRaw: string, perUnit: number) {
  await env.DB.prepare("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, ?, ?, 'HIGH', 1700000000)",
  ).bind(GTIN, LOCATION, perUnit, sizeRaw).run();
}

const on = () => ({ ...env, KROGER_PERSIST: "on" as const });

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.deactivate());

async function jobKinds(): Promise<string[]> {
  const rows = await env.DB.prepare("SELECT kind FROM alert_jobs ORDER BY id").all<{ kind: string }>();
  return rows.results.map((r) => r.kind);
}

describe("runKrogerSweep", () => {
  it("does nothing when persistence is off", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    expect(await runKrogerSweep(env)).toEqual({ pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0 });
    expect(await jobKinds()).toEqual([]);
  });

  it("files a size_drop when the package shrank", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("28 fl oz", 2.0);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ pairs: 1, snapshots: 1, sizeDrops: 1, priceHikes: 0 });
    expect(await jobKinds()).toEqual(["size_drop"]);

    const job = await env.DB.prepare("SELECT gtin, location_id, payload FROM alert_jobs").first<any>();
    expect(job.gtin).toBe(GTIN);
    expect(job.location_id).toBe(LOCATION);
    expect(JSON.parse(job.payload)).toEqual({ previous_size: "32 fl oz", size: "28 fl oz" });
  });

  it("ignores a +4.9% per-unit price move", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("32 fl oz", 2.098);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ sizeDrops: 0, priceHikes: 0 });
    expect(await jobKinds()).toEqual([]);
  });

  it("files a price_hike at exactly +5%", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("32 fl oz", 2.1);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ sizeDrops: 0, priceHikes: 1 });
    expect(await jobKinds()).toEqual(["price_hike"]);
    expect(JSON.parse((await env.DB.prepare("SELECT payload FROM alert_jobs").first<any>()).payload)).toEqual({
      previous_per_unit: 2.0,
      per_unit: 2.1,
    });
  });

  it("writes a fresh snapshot on every pass", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("32 fl oz", 2.0);

    await runKrogerSweep(on());
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(snaps!.n).toBe(2);
    expect(await jobKinds()).toEqual([]);
  });

  it("batches at most 50 productIds per Kroger call", async () => {
    for (let i = 0; i < 60; i++) {
      const gtin = `00284006422${String(i).padStart(2, "0")}`;
      await env.DB.prepare("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'x','x','x',NULL,'volume',1,1)").bind(gtin).run();
      await env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, 2.0, '32 fl oz', 'HIGH', 1700000000)").bind(gtin, LOCATION).run();
    }

    const batchSizes: number[] = [];
    fetchMock.get("https://api.kroger.com").intercept({ path: "/v1/connect/oauth2/token", method: "POST" }).reply(200, TOKEN_BODY);
    fetchMock
      .get("https://api.kroger.com")
      .intercept({ path: /^\/v1\/products\?filter\.productId=/ })
      .reply((options) => {
        const ids = decodeURIComponent(new URL(`https://api.kroger.com${options.path}`).searchParams.get("filter.productId")!);
        batchSizes.push(ids.split(",").length);
        return { statusCode: 200, data: { data: [] } };
      })
      .times(2);

    const result = await runKrogerSweep(on());
    expect(result.pairs).toBe(60);
    expect(batchSizes).toEqual([50, 10]);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd backend && npx vitest run test/sweep.test.ts`
Expected: FAIL — `Cannot find module '../src/sweep'` (and, once that resolves, `no such table: alert_jobs` if the migration was skipped).

- [ ] **Step 4: Implement the sweep**

`backend/src/sweep.ts`:

```ts
import type { Env } from "./env";
import { KROGER_BATCH_LIMIT, KrogerClient, type KrogerProduct } from "./kroger/client";
import { gtinFromKroger, krogerProductId } from "./kroger/ids";
import { toLiveProduct, type LiveProduct } from "./kroger/map";
import { persistKrogerProduct, snapshotPerUnit } from "./kroger/persist";
import { parsePackageWeight } from "./normalize";

/** Spec §3 — Pro alerts fire at a 5% per-unit price rise. Exactly +5% alerts. */
const PRICE_HIKE_THRESHOLD = 0.05;
/** Spec §5.1 — within 1% is the same size. */
const SIZE_DROP_TOLERANCE = 0.01;

export interface SweepResult {
  pairs: number;
  snapshots: number;
  sizeDrops: number;
  priceHikes: number;
}

interface SnapshotRow {
  regular: number | null;
  promo: number | null;
  per_unit_estimate: number | null;
  size_raw: string | null;
}

/**
 * Six-hourly Kroger sweep (spec §6.2). Phase 3 has no `watches`/`devices`
 * tables — they arrive in Phase 4 — so the sweep re-checks every
 * (gtin, location_id) pair we already hold a snapshot for. Phase 4 swaps that
 * single query for `watches x devices` and leaves the rest of this file alone.
 */
export async function runKrogerSweep(env: Env, client: KrogerClient = new KrogerClient(env)): Promise<SweepResult> {
  const result: SweepResult = { pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0 };
  if (env.KROGER_PERSIST !== "on") return result;

  const { results: pairs } = await env.DB.prepare("SELECT DISTINCT gtin, location_id FROM price_snapshots").all<{
    gtin: string;
    location_id: string;
  }>();
  result.pairs = pairs.length;
  if (pairs.length === 0) return result;

  const byLocation = new Map<string, string[]>();
  for (const pair of pairs) {
    const list = byLocation.get(pair.location_id) ?? [];
    list.push(pair.gtin);
    byLocation.set(pair.location_id, list);
  }

  const now = Math.floor(Date.now() / 1000);

  for (const [locationId, gtins] of byLocation) {
    for (let offset = 0; offset < gtins.length; offset += KROGER_BATCH_LIMIT) {
      const ids = gtins
        .slice(offset, offset + KROGER_BATCH_LIMIT)
        .map(krogerProductId)
        .filter((id): id is string => id !== null);
      if (ids.length === 0) continue;

      let products: KrogerProduct[];
      try {
        products = (await client.products(ids, locationId)).data;
      } catch {
        continue; // Kroger unreachable for this batch — try again in six hours
      }

      for (const raw of products) {
        const gtin = gtinFromKroger(raw.upc ?? raw.productId);
        if (!gtin) continue;
        const live = toLiveProduct(raw);

        const previous = await env.DB.prepare(
          "SELECT regular, promo, per_unit_estimate, size_raw FROM price_snapshots WHERE gtin = ? AND location_id = ? ORDER BY observed_at DESC, id DESC LIMIT 1",
        )
          .bind(gtin, locationId)
          .first<SnapshotRow>();

        await persistKrogerProduct(env, gtin, locationId, live, now);
        result.snapshots += 1;
        if (!previous) continue;

        if (isSizeDrop(previous.size_raw, live)) {
          await enqueue(env, "size_drop", gtin, live.brand, locationId, { previous_size: previous.size_raw, size: live.size }, now);
          result.sizeDrops += 1;
        }

        const before = snapshotPerUnit(previous);
        const after = snapshotPerUnit({
          regular: live.regular,
          promo: live.promo,
          per_unit_estimate: live.per_unit_estimate,
          size_raw: live.size,
        });
        if (before !== null && after !== null && before > 0 && (after - before) / before >= PRICE_HIKE_THRESHOLD) {
          await enqueue(env, "price_hike", gtin, live.brand, locationId, { previous_per_unit: before, per_unit: after }, now);
          result.priceHikes += 1;
        }
      }
    }
  }

  return result;
}

/** A real shrink: same unit kind, more than 1% smaller than last time. */
function isSizeDrop(previousSizeRaw: string | null, live: LiveProduct): boolean {
  if (live.quantity === null || live.unit_kind === null || !previousSizeRaw) return false;
  const before = parsePackageWeight(previousSizeRaw);
  if (!before || before.unitKind !== live.unit_kind || before.quantity <= 0) return false;
  return (before.quantity - live.quantity) / before.quantity > SIZE_DROP_TOLERANCE;
}

async function enqueue(
  env: Env,
  kind: "size_drop" | "price_hike",
  gtin: string,
  brand: string,
  locationId: string,
  payload: unknown,
  now: number,
): Promise<void> {
  await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
  )
    .bind(kind, gtin, brand, locationId, JSON.stringify(payload), now)
    .run();
}
```

- [ ] **Step 5: Add the Workers entry and the cron trigger**

`backend/src/worker.ts`:

```ts
import type { Env } from "./env";
import app from "./index";
import { runKrogerSweep } from "./sweep";

/**
 * Workers entry point. `src/index.ts` stays the Hono app so tests can keep
 * calling `app.request(...)`; this module only adds the cron surface.
 */
export default {
  fetch: app.fetch,
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    if (controller.cron === "0 */6 * * *") {
      ctx.waitUntil(runKrogerSweep(env)); // spec §6.2 — Kroger sweep
    }
  },
} satisfies ExportedHandler<Env>;
```

`backend/wrangler.toml` — point `main` at the new entry and register the trigger:

```toml
main = "src/worker.ts"

[triggers]
crons = ["0 */6 * * *"]
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd backend && npx vitest run && npx tsc --noEmit`
Expected: `sweep.test.ts` `6 passed`; every other suite still green.

- [ ] **Step 7: Commit**

```bash
git add backend/migrations/0003_alert_jobs.sql backend/src/sweep.ts backend/src/worker.ts backend/wrangler.toml backend/test/sweep.test.ts
git commit -m "feat(backend): six-hourly Kroger sweep files size_drop and price_hike alert jobs"
```

---

### Task 11: Provision KV, set the Kroger secrets, deploy and verify

Interactive: needs the Kroger Client ID/Secret from the developer account created in Phase 1 Task 15.

**Files:**
- Modify: `backend/wrangler.toml` (real KV id)
- Modify: `backend/README.md` (new endpoints and the purge command)

- [ ] **Step 1: Create the KV namespace**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler kv namespace create KROGER
```
Copy the printed `id` into the `[[kv_namespaces]]` block in `wrangler.toml`, replacing the 32-zero placeholder. Keep `binding = "KV"`.

- [ ] **Step 2: Set the Kroger credentials as secrets**

```bash
cd /Users/drao/Projects/shrunk/backend
npx wrangler secret put KROGER_CLIENT_ID
npx wrangler secret put KROGER_CLIENT_SECRET
```
For local dev add the same two lines to `backend/.dev.vars` (git-ignored):

```
KROGER_CLIENT_ID=<client id>
KROGER_CLIENT_SECRET=<client secret>
```

- [ ] **Step 3: Migrate and deploy**

```bash
cd /Users/drao/Projects/shrunk/backend
npm run migrate:remote && npm run deploy
```
Expected: wrangler prints the Worker URL and confirms the `0 */6 * * *` trigger.

- [ ] **Step 4: Verify live against a real Cincinnati store**

```bash
API=https://shrunk-api.<account>.workers.dev
curl -s "$API/v1/kroger/locations?zip=45044" | head -c 400
# pick a locationId from the output, then:
curl -si "$API/v1/kroger/product/0028400642255?locationId=<locationId>" | head -20
curl -s "$API/v1/kroger/search?term=Beverages&locationId=<locationId>" | head -c 400
```
Expected: `"attribution":"Prices from Kroger"` in every body, a `Cache-Control` header forwarded from Kroger on the product call, and a `regular` price present. If the product call returns `{"error":"kroger_upstream","status":401}`, the secrets are wrong — re-run Step 2.

Confirm persistence landed:

```bash
npx wrangler d1 execute shrunk --remote --command "SELECT gtin, location_id, regular, size_raw FROM price_snapshots ORDER BY observed_at DESC LIMIT 5;"
```

- [ ] **Step 5: Verify the purge lever works, then re-seed**

```bash
curl -s -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer <ADMIN_SECRET>"
npx wrangler d1 execute shrunk --remote --command "SELECT COUNT(*) AS n FROM price_snapshots;"
```
Expected: `{"deleted":{...}}` then `n = 0`. Re-run the Step 4 product curl so there is live data to look at on device.

- [ ] **Step 6: Update the README and commit**

Append to `backend/README.md`:

```markdown
## Kroger

`GET /v1/kroger/locations?zip=`, `GET /v1/kroger/product/:gtin?locationId=`, `GET /v1/kroger/search?term=&locationId=`.
Every response carries `"attribution": "Prices from Kroger"` and forwards Kroger's `Cache-Control`.
Secrets: `KROGER_CLIENT_ID`, `KROGER_CLIENT_SECRET` (`wrangler secret put`). Persistence is the
`KROGER_PERSIST` var in `wrangler.toml` — set it to `"off"` and redeploy to stop all Kroger writes.

Cron `0 */6 * * *` re-checks every `(gtin, location_id)` in `price_snapshots` and files `alert_jobs`.

Remove every Kroger-derived row:

    curl -X POST "$API/v1/admin/purge-kroger" -H "Authorization: Bearer $ADMIN_SECRET"
```

```bash
cd /Users/drao/Projects/shrunk
git add backend/wrangler.toml backend/README.md
git commit -m "chore(backend): KV namespace binding, Kroger secrets and deploy notes"
```

---

### Task 12: iOS store models, Kroger DTOs and `ShrunkAPIClient` methods

**Files:**
- Create: `Shrunk/Models/StoreLocation.swift`, `Shrunk/Models/LivePrice.swift`, `Shrunk/Services/KrogerDTO.swift`, `Shrunk/Services/DataProviders.swift`
- Modify: `Shrunk/Services/ShrunkAPIClient.swift`
- Test: `ShrunkTests/KrogerDTOTests.swift`

**Interfaces:**
- Produces: `StoreLocation(id:chain:name:addressLine1:city:state:zipCode:)` with `displayName`, `addressLine`.
- Produces: `protocol StorePriced` (`regular`, `promo`, `stockLevel`) with `effectivePrice`, `inStock`, `stockLabel`; `LivePrice` (with `static let attribution = "Prices from Kroger"`) and `StoreSearchResult`, both conforming.
- Produces: `ShrunkAPIClient.locations(zip:) -> [StoreLocation]`, `.liveProduct(barcode:locationId:) -> LivePrice`, `.search(term:locationId:) -> [StoreSearchResult]`, plus `static let deviceId: String` (persistent UUID sent as `X-Device-Id`; Phase 4 reuses it for `/v1/devices`).
- Produces: `protocol StoreDataProviding` (those three methods) with `extension ShrunkAPIClient: StoreDataProviding {}`, and `protocol TrendingFeedProviding { func fetch() async -> TrendingFeed }` with `extension TrendingFeedService: TrendingFeedProviding {}`.

iOS test command used throughout (substitute the simulator from `xcrun simctl list devices available`):

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```

- [ ] **Step 1: Write the failing test**

`ShrunkTests/KrogerDTOTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class KrogerDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_locationsResponse_decodesAndMaps() throws {
        let json = """
        {"locations":[{"locationId":"01400943","chain":"KROGER","name":"Hyde Park",
          "address":{"addressLine1":"3760 Paxton Ave","city":"Cincinnati","state":"OH","zipCode":"45209"},
          "geolocation":{"latitude":39.14,"longitude":-84.42}}],
         "attribution":"Prices from Kroger"}
        """
        let dto = try decoder.decode(LocationsResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.attribution, "Prices from Kroger")

        let store = dto.locations[0].toModel()
        XCTAssertEqual(store.id, "01400943")
        XCTAssertEqual(store.displayName, "Kroger Hyde Park")
        XCTAssertEqual(store.addressLine, "3760 Paxton Ave · Cincinnati, OH")
        XCTAssertEqual(store.zipCode, "45209")
    }

    func test_liveProduct_decodesAndMaps() throws {
        let json = """
        {"gtin":"0028400642255","location_id":"01400943","product_id":"0002840064225",
         "brand":"Gatorade","description":"Gatorade Thirst Quencher","category":"Beverages",
         "image_url":"https://img/large.jpg","size":"28 fl oz","quantity":828.058,"unit_kind":"volume",
         "regular":1.89,"promo":1.5,"per_unit_estimate":0.05,"price_per_base_unit":0.00181,
         "stock_level":"HIGH","attribution":"Prices from Kroger"}
        """
        let live = try decoder.decode(LiveProductDTO.self, from: Data(json.utf8)).toModel()
        XCTAssertEqual(live.gtin, "0028400642255")
        XCTAssertEqual(live.locationId, "01400943")
        XCTAssertEqual(live.size, "28 fl oz")
        XCTAssertEqual(live.quantity ?? 0, 828.058, accuracy: 0.001)
        XCTAssertEqual(live.unitKind, "volume")
        XCTAssertEqual(live.effectivePrice, 1.5)          // promo wins
        XCTAssertTrue(live.isOnPromo)
        XCTAssertTrue(live.inStock)
        XCTAssertEqual(live.stockLabel, "In stock")
        XCTAssertEqual(LivePrice.attribution, "Prices from Kroger")
    }

    func test_liveProduct_outOfStockAndNoPromo() throws {
        let json = """
        {"gtin":"0028400642255","location_id":"01400943","product_id":"0002840064225",
         "brand":"","description":"X","category":"","image_url":null,"size":"each",
         "quantity":null,"unit_kind":null,"regular":3.49,"promo":0,"per_unit_estimate":null,
         "price_per_base_unit":null,"stock_level":"TEMPORARILY_OUT_OF_STOCK","attribution":"Prices from Kroger"}
        """
        let live = try decoder.decode(LiveProductDTO.self, from: Data(json.utf8)).toModel()
        XCTAssertEqual(live.effectivePrice, 3.49)
        XCTAssertFalse(live.isOnPromo)
        XCTAssertFalse(live.inStock)
        XCTAssertEqual(live.stockLabel, "Out of stock")
        XCTAssertNil(live.quantity)
    }

    func test_searchResponse_decodesAndMaps() throws {
        let json = """
        {"results":[{"gtin":"0002840064226","product_id":"0002840064226","brand":"Store",
          "description":"Store Brand","category":"Beverages","image_url":null,"size":"32 fl oz",
          "quantity":946.353,"unit_kind":"volume","regular":1.0,"promo":0,
          "per_unit_estimate":0.03,"price_per_base_unit":0.00106,"stock_level":"LOW"}],
         "attribution":"Prices from Kroger"}
        """
        let dto = try decoder.decode(SearchResponseDTO.self, from: Data(json.utf8))
        let result = dto.results[0].toModel()
        XCTAssertEqual(result.gtin, "0002840064226")
        XCTAssertEqual(result.description, "Store Brand")
        XCTAssertEqual(result.effectivePrice, 1.0)
        XCTAssertEqual(result.stockLabel, "Low stock")
        XCTAssertTrue(result.inStock)
        XCTAssertEqual(result.quantity ?? 0, 946.353, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the iOS test command above with `-only-testing:ShrunkTests/KrogerDTOTests`.
Expected: compile error `cannot find 'LocationsResponseDTO' in scope`.

- [ ] **Step 3: Write the models**

`Shrunk/Models/StoreLocation.swift`:

```swift
import Foundation

/// A Kroger store the user pins prices to. `id` is Kroger's 8-character locationId.
struct StoreLocation: Identifiable, Hashable, Codable {
    let id: String
    let chain: String
    let name: String
    let addressLine1: String
    let city: String
    let state: String
    let zipCode: String

    /// "Kroger Hyde Park" — what Settings shows and what we persist.
    var displayName: String {
        let chainName = chain.isEmpty ? "" : chain.capitalized
        if name.isEmpty { return chainName.isEmpty ? id : chainName }
        return chainName.isEmpty ? name : "\(chainName) \(name)"
    }

    /// "3760 Paxton Ave · Cincinnati, OH"
    var addressLine: String {
        let cityState = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        return [addressLine1, cityState].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
```

`Shrunk/Models/LivePrice.swift`:

```swift
import Foundation

/// Shared price/stock behaviour for anything priced at a store.
protocol StorePriced {
    var regular: Double? { get }
    var promo: Double? { get }
    var stockLevel: String? { get }
}

extension StorePriced {
    /// Promo when there is one, otherwise the regular shelf price.
    var effectivePrice: Double? {
        if let promo, promo > 0 { return promo }
        if let regular, regular > 0 { return regular }
        return nil
    }

    var isOnPromo: Bool {
        guard let promo, promo > 0, let regular else { return false }
        return regular > promo
    }

    var inStock: Bool { (stockLevel ?? "").uppercased() != "TEMPORARILY_OUT_OF_STOCK" }

    var stockLabel: String {
        switch (stockLevel ?? "").uppercased() {
        case "HIGH":                     return "In stock"
        case "LOW":                      return "Low stock"
        case "TEMPORARILY_OUT_OF_STOCK": return "Out of stock"
        default:                         return "Stock unknown"
        }
    }
}

/// Live price for the scanned product at the user's store. Every surface that
/// shows one must also show `LivePrice.attribution` (Kroger terms, spec §9).
struct LivePrice: Hashable, StorePriced {
    static let attribution = "Prices from Kroger"

    let gtin: String
    let locationId: String
    let brand: String
    let description: String
    let size: String?
    let quantity: Double?       // grams | millilitres | count
    let unitKind: String?       // mass | volume | count
    let regular: Double?
    let promo: Double?
    let perUnitEstimate: Double?
    let stockLevel: String?
}

/// One candidate in the store-backed alternatives list.
struct StoreSearchResult: Hashable, StorePriced {
    let gtin: String?
    let productId: String
    let brand: String
    let description: String
    let category: String
    let imageURL: URL?
    let size: String?
    let quantity: Double?
    let unitKind: String?
    let regular: Double?
    let promo: Double?
    let stockLevel: String?
}
```

- [ ] **Step 4: Write the wire types**

`Shrunk/Services/KrogerDTO.swift`:

```swift
import Foundation

// Wire formats for the Worker's /v1/kroger/* routes. Field names match the
// Worker exactly (snake_case for our fields, camelCase where we pass Kroger's
// location shape straight through), so the plain JSONDecoder needs no strategy.

struct LocationsResponseDTO: Decodable {
    let locations: [StoreLocationDTO]
    let attribution: String
}

struct StoreLocationDTO: Decodable {
    struct AddressDTO: Decodable {
        let addressLine1: String
        let city: String
        let state: String
        let zipCode: String
    }

    let locationId: String
    let chain: String
    let name: String
    let address: AddressDTO

    func toModel() -> StoreLocation {
        StoreLocation(
            id: locationId,
            chain: chain,
            name: name,
            addressLine1: address.addressLine1,
            city: address.city,
            state: address.state,
            zipCode: address.zipCode
        )
    }
}

struct LiveProductDTO: Decodable {
    let gtin: String
    let location_id: String
    let product_id: String
    let brand: String
    let description: String
    let category: String
    let image_url: String?
    let size: String?
    let quantity: Double?
    let unit_kind: String?
    let regular: Double?
    let promo: Double?
    let per_unit_estimate: Double?
    let price_per_base_unit: Double?
    let stock_level: String?
    let attribution: String

    func toModel() -> LivePrice {
        LivePrice(
            gtin: gtin,
            locationId: location_id,
            brand: brand,
            description: description,
            size: size,
            quantity: quantity,
            unitKind: unit_kind,
            regular: regular,
            promo: promo,
            perUnitEstimate: per_unit_estimate,
            stockLevel: stock_level
        )
    }
}

struct SearchResponseDTO: Decodable {
    let results: [SearchResultDTO]
    let attribution: String
}

struct SearchResultDTO: Decodable {
    let gtin: String?
    let product_id: String
    let brand: String
    let description: String
    let category: String
    let image_url: String?
    let size: String?
    let quantity: Double?
    let unit_kind: String?
    let regular: Double?
    let promo: Double?
    let price_per_base_unit: Double?
    let stock_level: String?

    func toModel() -> StoreSearchResult {
        StoreSearchResult(
            gtin: gtin,
            productId: product_id,
            brand: brand,
            description: description,
            category: category,
            imageURL: image_url.flatMap(URL.init),
            size: size,
            quantity: quantity,
            unitKind: unit_kind,
            regular: regular,
            promo: promo,
            stockLevel: stock_level
        )
    }
}
```

- [ ] **Step 5: Add the client methods and the seams**

In `Shrunk/Services/ShrunkAPIClient.swift`, add the device id and the shared GET, and route `fetchProduct` through it. Replace the whole `fetchProduct(barcode:locationId:)` method with the version below and add the members that follow it (`locations`, `liveProduct`, `search`, `get`, `deviceId`):

```swift
    func fetchProduct(barcode: String, locationId: String?) async throws -> ShrunkProduct {
        var components = URLComponents(url: baseURL.appending(path: "v1/product/\(barcode)"), resolvingAgainstBaseURL: false)!
        if let locationId {
            components.queryItems = [URLQueryItem(name: "locationId", value: locationId)]
        }
        let dto: ProductDTO = try await get(components.url!)
        return dto.toProduct()
    }

    /// Live Kroger stores near a zip (spec §6.1).
    func locations(zip: String) async throws -> [StoreLocation] {
        var components = URLComponents(url: baseURL.appending(path: "v1/kroger/locations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "zip", value: zip)]
        let dto: LocationsResponseDTO = try await get(components.url!)
        return dto.locations.map { $0.toModel() }
    }

    /// Live price/size/stock for one product at the user's store.
    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice {
        var components = URLComponents(url: baseURL.appending(path: "v1/kroger/product/\(barcode)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "locationId", value: locationId)]
        let dto: LiveProductDTO = try await get(components.url!)
        return dto.toModel()
    }

    /// Same-category candidates at the user's store, cheapest per unit first.
    func search(term: String, locationId: String) async throws -> [StoreSearchResult] {
        var components = URLComponents(url: baseURL.appending(path: "v1/kroger/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "locationId", value: locationId)
        ]
        let dto: SearchResponseDTO = try await get(components.url!)
        return dto.results.map { $0.toModel() }
    }

    /// One GET, one status mapping, one decode — every endpoint goes through here.
    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(Self.deviceId, forHTTPHeaderField: "X-Device-Id")

        let data: Data
        do {
            let (received, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: data = received
            case 404: throw ShrunkError.productNotFound
            default:  throw ShrunkError.invalidResponse
            }
        } catch let error as ShrunkError {
            throw error
        } catch {
            throw ShrunkError.network(error)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ShrunkError.decoding(error)
        }
    }

    /// Stable per-install id, tied to no account. The Worker uses it only for
    /// the per-device Kroger rate limit (spec §6.6); Phase 4 reuses it for
    /// `/v1/devices`.
    static let deviceId: String = {
        let key = "shrunk.device_id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
```

`Shrunk/Services/DataProviders.swift`:

```swift
import Foundation

/// The store-data seam. `ShrunkAPIClient` is the production implementation;
/// tests inject a stub so view models and the alternatives engine never touch
/// the network.
protocol StoreDataProviding: Sendable {
    func locations(zip: String) async throws -> [StoreLocation]
    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice
    func search(term: String, locationId: String) async throws -> [StoreSearchResult]
}

extension ShrunkAPIClient: StoreDataProviding {}

/// The curated-feed seam, used by the alternatives fallback.
protocol TrendingFeedProviding: Sendable {
    func fetch() async -> TrendingFeed
}

extension TrendingFeedService: TrendingFeedProviding {}
```

- [ ] **Step 6: Run the test to verify it passes**

Run the iOS test command with `-only-testing:ShrunkTests/KrogerDTOTests`.
Expected: `Test Suite 'KrogerDTOTests' passed`, 4 tests. If the build fails with "cannot find type 'TrendingFeed'", confirm `xcodegen generate` ran after the new files were created.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Models/StoreLocation.swift Shrunk/Models/LivePrice.swift Shrunk/Services/KrogerDTO.swift Shrunk/Services/DataProviders.swift Shrunk/Services/ShrunkAPIClient.swift ShrunkTests/KrogerDTOTests.swift
git commit -m "feat(ios): store models, Kroger DTOs and ShrunkAPIClient live endpoints"
```

---

### Task 13: Store picker + Settings entry point

**Files:**
- Create: `Shrunk/Features/Store/StorePickerViewModel.swift`, `Shrunk/Features/Store/StorePickerView.swift`
- Create: `ShrunkTests/StubStoreData.swift`, `ShrunkTests/StorePickerViewModelTests.swift`
- Modify: `Shrunk/Features/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `StoreDataProviding`, `StoreLocation` (Task 12).
- Produces: `StorePickerViewModel` — `@Published var zip`, `@Published private(set) var state: State { idle, loading, loaded([StoreLocation]), empty, failed(String) }`, `@Published private(set) var selectedId: String?`, `canSearch`, `func search() async`, `func select(_:)`, `func clear()`, and the two `@AppStorage` keys `StorePickerViewModel.locationIdKey == "storeLocationId"` / `.storeNameKey == "storeName"`.
- Produces: `StorePickerView` — presented as a sheet; writes both defaults keys on selection.
- Produces: `StubStoreData` (test target) implementing `StoreDataProviding` with settable results and a recorded `searchTerms` / `zips`.

- [ ] **Step 1: Write the shared stub**

`ShrunkTests/StubStoreData.swift`:

```swift
import Foundation
@testable import Shrunk

/// Shared stub for `StoreDataProviding`. `@unchecked Sendable` because the
/// tests drive it from a single task and only read the recordings afterwards.
final class StubStoreData: StoreDataProviding, @unchecked Sendable {
    var locationsResult: Result<[StoreLocation], Error> = .success([])
    var liveProductResult: Result<LivePrice, Error> = .failure(ShrunkError.productNotFound)
    var searchResult: Result<[StoreSearchResult], Error> = .success([])

    private(set) var zips: [String] = []
    private(set) var searchTerms: [String] = []
    private(set) var searchLocationIds: [String] = []

    func locations(zip: String) async throws -> [StoreLocation] {
        zips.append(zip)
        return try locationsResult.get()
    }

    func liveProduct(barcode: String, locationId: String) async throws -> LivePrice {
        try liveProductResult.get()
    }

    func search(term: String, locationId: String) async throws -> [StoreSearchResult] {
        searchTerms.append(term)
        searchLocationIds.append(locationId)
        return try searchResult.get()
    }
}

/// Stub for the curated feed used by the alternatives fallback.
final class StubTrendingFeed: TrendingFeedProviding, @unchecked Sendable {
    var feed: TrendingFeed = .empty
    func fetch() async -> TrendingFeed { feed }
}

extension StoreLocation {
    static func fixture(id: String = "01400943", name: String = "Hyde Park") -> StoreLocation {
        StoreLocation(id: id, chain: "KROGER", name: name, addressLine1: "3760 Paxton Ave",
                      city: "Cincinnati", state: "OH", zipCode: "45209")
    }
}
```

- [ ] **Step 2: Write the failing view-model test**

`ShrunkTests/StorePickerViewModelTests.swift`:

```swift
import XCTest
@testable import Shrunk

@MainActor
final class StorePickerViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "store-picker-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_canSearch_requiresFiveDigits() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.zip = "450"
        XCTAssertFalse(vm.canSearch)
        vm.zip = "45044"
        XCTAssertTrue(vm.canSearch)
    }

    func test_search_loadsLocations() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([.fixture(), .fixture(id: "01400944", name: "Oakley")])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "45044"

        await vm.search()

        XCTAssertEqual(stub.zips, ["45044"])
        guard case .loaded(let stores) = vm.state else { return XCTFail("expected .loaded, got \(vm.state)") }
        XCTAssertEqual(stores.map(\.id), ["01400943", "01400944"])
    }

    func test_search_emptyResult() async {
        let stub = StubStoreData()
        stub.locationsResult = .success([])
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "99999"

        await vm.search()

        XCTAssertEqual(vm.state, .empty)
    }

    func test_search_failureShowsTheKrogerDownCopy() async {
        let stub = StubStoreData()
        stub.locationsResult = .failure(ShrunkError.invalidResponse)
        let vm = StorePickerViewModel(store: stub, defaults: defaults)
        vm.zip = "45044"

        await vm.search()

        XCTAssertEqual(vm.state, .failed("Store prices unavailable right now"))
    }

    func test_select_persistsIdAndName() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.select(.fixture())

        XCTAssertEqual(defaults.string(forKey: "storeLocationId"), "01400943")
        XCTAssertEqual(defaults.string(forKey: "storeName"), "Kroger Hyde Park")
        XCTAssertEqual(vm.selectedId, "01400943")
    }

    func test_clear_removesBothKeys() {
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        vm.select(.fixture())
        vm.clear()

        XCTAssertNil(defaults.string(forKey: "storeLocationId"))
        XCTAssertNil(defaults.string(forKey: "storeName"))
        XCTAssertNil(vm.selectedId)
    }

    func test_init_readsTheSavedStore() {
        defaults.set("01400943", forKey: "storeLocationId")
        let vm = StorePickerViewModel(store: StubStoreData(), defaults: defaults)
        XCTAssertEqual(vm.selectedId, "01400943")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run the iOS test command with `-only-testing:ShrunkTests/StorePickerViewModelTests`.
Expected: compile error `cannot find 'StorePickerViewModel' in scope`.

- [ ] **Step 4: Implement the view model**

`Shrunk/Features/Store/StorePickerViewModel.swift`:

```swift
import Foundation

@MainActor
final class StorePickerViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([StoreLocation])
        case empty
        case failed(String)
    }

    /// The two keys the rest of the app reads with @AppStorage.
    static let locationIdKey = "storeLocationId"
    static let storeNameKey = "storeName"

    @Published var zip: String = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var selectedId: String?

    private let store: any StoreDataProviding
    private let defaults: UserDefaults

    init(store: any StoreDataProviding = ShrunkAPIClient.shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.selectedId = defaults.string(forKey: Self.locationIdKey)
    }

    var canSearch: Bool { zip.filter(\.isNumber).count == 5 }

    func search() async {
        guard canSearch else { return }
        state = .loading
        do {
            let stores = try await store.locations(zip: zip.filter(\.isNumber))
            state = stores.isEmpty ? .empty : .loaded(stores)
        } catch {
            // Kroger down or key revoked — never a blocking error (spec §8).
            state = .failed("Store prices unavailable right now")
        }
    }

    func select(_ location: StoreLocation) {
        defaults.set(location.id, forKey: Self.locationIdKey)
        defaults.set(location.displayName, forKey: Self.storeNameKey)
        selectedId = location.id
    }

    func clear() {
        defaults.removeObject(forKey: Self.locationIdKey)
        defaults.removeObject(forKey: Self.storeNameKey)
        selectedId = nil
    }
}
```

- [ ] **Step 5: Implement the view**

`Shrunk/Features/Store/StorePickerView.swift`:

```swift
import SwiftUI

struct StorePickerView: View {
    @StateObject private var vm = StorePickerViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Onboarding embeds the picker without navigation chrome.
    let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            picker
        } else {
            NavigationStack {
                picker
                    .navigationTitle("Your store")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                                .foregroundStyle(Color.shrunkRed)
                                .fontWeight(.semibold)
                        }
                    }
            }
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
                zipField
                results
                Text(LivePrice.attribution)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.smoke)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, ShrunkTheme.Spacing.sm)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.vertical, ShrunkTheme.Spacing.md)
        }
        .background(Color.paper.ignoresSafeArea())
    }

    private var zipField: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            Text("ZIP CODE").shrunkSectionLabel()
            HStack(spacing: ShrunkTheme.Spacing.sm) {
                TextField("45044", text: $vm.zip)
                    .keyboardType(.numberPad)
                    .font(.shrunkMonoBig)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
                    .padding(.vertical, 12)
                    .background(Color.mist)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
                Button("Find") { Task { await vm.search() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(vm.canSearch ? Color.shrunkRed : Color.smokeSoft)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
                    .disabled(!vm.canSearch)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch vm.state {
        case .idle:
            Text("Pick a Kroger store to see live prices and cost per ounce on every scan.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
        case .loading:
            ProgressView().tint(Color.shrunkRed).frame(maxWidth: .infinity).padding(.vertical, ShrunkTheme.Spacing.lg)
        case .empty:
            Text("No Kroger stores within 15 miles of that ZIP.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
        case .failed(let message):
            Text(message)
                .font(.shrunkBody)
                .foregroundStyle(Color.shrunkRedDark)
        case .loaded(let stores):
            VStack(spacing: 0) {
                ForEach(stores) { store in
                    Button { vm.select(store) } label: { row(store) }
                        .buttonStyle(.plain)
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(Color.borderSoft, lineWidth: 0.5)
            )
        }
    }

    private func row(_ store: StoreLocation) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(store.addressLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: vm.selectedId == store.id ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(vm.selectedId == store.id ? Color.shrunkRed : Color.smokeSoft)
        }
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().fill(Color.borderSoft).frame(height: 0.5), alignment: .bottom)
    }
}
```

- [ ] **Step 6: Add the Settings entry point**

In `Shrunk/Features/Settings/SettingsView.swift`, add two properties next to the other `@State`s:

```swift
    @State private var showStorePicker: Bool = false
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""
```

Insert this section immediately above the `sectionGroup(title: "Alerts & notifications", ...)` call:

```swift
                    sectionGroup(title: "Store", subtitle: "Live prices and store alternatives come from the Kroger store you pick. Prices from Kroger.") {
                        SettingsRow(icon: "cart.fill", iconTint: .shrunkRed,
                                    label: storeName.isEmpty ? "Choose your store" : storeName) {
                            showStorePicker = true
                        }
                    }
```

and add the sheet next to the others:

```swift
        .sheet(isPresented: $showStorePicker) {
            StorePickerView()
        }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the iOS test command with `-only-testing:ShrunkTests/StorePickerViewModelTests`.
Expected: `Test Suite 'StorePickerViewModelTests' passed`, 7 tests.

- [ ] **Step 8: Commit**

```bash
git add Shrunk/Features/Store Shrunk/Features/Settings/SettingsView.swift ShrunkTests/StubStoreData.swift ShrunkTests/StorePickerViewModelTests.swift
git commit -m "feat(ios): store picker with zip search, persisted store, Settings entry"
```

---

### Task 14: Store step in onboarding

Phase 5 trims onboarding down to welcome → categories → store → paywall. This task only inserts the store step so a new user can set a store before their first scan.

**Files:**
- Create: `Shrunk/Features/Onboarding/StoreStep.swift`
- Modify: `Shrunk/Features/Onboarding/OnboardingViewModel.swift`
- Modify: `Shrunk/Features/Onboarding/OnboardingContainerView.swift`

**Interfaces:**
- Consumes: `StorePickerView(embedded: true)` from Task 13.
- Produces: `OnboardingViewModel.Step.store`, ordered immediately after `.categories`. Skippable — `canAdvance` is always `true` for it. `Step` raw values after `.categories` shift by one; nothing persists a raw value, so no migration is needed.

- [ ] **Step 1: Add the step to the view model**

In `Shrunk/Features/Onboarding/OnboardingViewModel.swift`, insert the case into `Step` between `.categories` and `.spend`:

```swift
        case categories     // Q3 multi-select
        case store          // pick a Kroger store (skippable)
        case spend          // Q4 slider
```

and add it to `canAdvance`'s always-true list:

```swift
        case .hero, .problem, .socialProof, .reveal, .paywall, .store:
            return true
```

- [ ] **Step 2: Write the step view**

`Shrunk/Features/Onboarding/StoreStep.swift`:

```swift
import SwiftUI

/// Onboarding step 4: pick a Kroger store so scans show live prices. Skippable —
/// the CTA reads "Skip for now" until a store is chosen (spec §7).
struct StoreStep: View {
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where do you shop?")
                    .font(.shrunkLargeTitle)
                    .foregroundStyle(Color.ink)
                Text("Pick your Kroger and every scan shows the shelf price and the real cost per ounce. You can change it any time in Settings.")
                    .font(.shrunkBody)
                    .foregroundStyle(Color.smoke)
                    .lineSpacing(3)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)

            if !storeName.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.verdictGoodDeep)
                    Text(storeName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .padding(.horizontal, ShrunkTheme.Spacing.lg)
            }

            StorePickerView(embedded: true)
        }
    }
}
```

- [ ] **Step 3: Wire it into the container**

In `Shrunk/Features/Onboarding/OnboardingContainerView.swift`, add one line to `pageContent` after the `.categories` case:

```swift
        case .store:        StoreStep()
```

and one line to `ctaTitle` after the `.categories` case:

```swift
        case .store:       return storeName.isEmpty ? "Skip for now" : "Continue"
```

with the backing property next to the view's other storage:

```swift
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""
```

- [ ] **Step 4: Build and run the whole suite**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds and every existing suite passes. A `switch must be exhaustive` error means one of the two container switches is missing the `.store` case.

- [ ] **Step 5: Smoke-test onboarding on the simulator**

Delete the app from the simulator (so onboarding runs), launch, and step to the store screen. Enter `45044`, tap **Find**, pick a store. Expected: the checkmark moves to that row, the header shows the store name, and the CTA changes from "Skip for now" to "Continue".

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Features/Onboarding
git commit -m "feat(ios): store step in onboarding"
```

---

### Task 15: Price history on `ShrunkProduct`, then/now cost-per-unit in `ShrinkDetector`

**Files:**
- Modify: `Shrunk/Models/ShrunkProduct.swift`
- Modify: `Shrunk/Services/ShrinkDetector.swift`
- Modify: `Shrunk/Services/ShrunkAPIClient.swift` (`ProductDTO.toProduct`)
- Test: `ShrunkTests/ShrinkDetectorTests.swift` (append)

**Interfaces:**
- Produces: `struct PricePoint: Codable, Hashable { let date: Date; let price: Double; let perUnitEstimate: Double? }` and `ShrunkProduct.priceHistory: [PricePoint]` (defaults to `[]`, declared **last** so every existing `ShrunkProduct(...)` call site still compiles).
- Produces: `ShrinkDetector.analyze` fills `priceNow` from the newest price point (falling back to `currentPrice`), `priceThen` from the second-newest, `costPerUnitNow = priceNow / normalized(current size)`, `costPerUnitThen = priceThen / normalized(previous size)` — both in the oz-equivalent space `ShrinkDetector.normalize` produces.
- Produces: `ProductDTO` gains `needs_confirmation: Bool?`, and `toProduct()` fills `priceHistory` from `price_snapshots` (promo when > 0, else regular; snapshots with no usable price are dropped).

`ShrunkProduct` is only ever encoded, never decoded (verify with `grep -rn "ShrunkProduct.self" Shrunk ShrunkTests` → no hits), so a new property with a default is safe.

- [ ] **Step 1: Write the failing tests**

Append inside the class in `ShrunkTests/ShrinkDetectorTests.swift`, after the existing cost-per-unit tests:

```swift
    // MARK: - Price history

    private func makePriced(sizes: [(Double, String)], prices: [(TimeInterval, Double)]) -> ShrunkProduct {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let history = sizes.enumerated().map { idx, s in
            SizeRecord(date: base.addingTimeInterval(TimeInterval(idx) * 86_400),
                       quantity: s.0, unit: s.1, source: "test")
        }
        let points = prices.map { PricePoint(date: base.addingTimeInterval($0.0), price: $0.1, perUnitEstimate: nil) }
        return ShrunkProduct(
            id: "test", name: "Test", brand: "Brand", category: "Beverages",
            imageURL: nil, sizeHistory: history, currentPrice: points.last?.price, currency: "USD",
            needsConfirmation: false, priceHistory: points
        )
    }

    func test_priceHistory_fillsThenAndNow() {
        // 32oz at $1.79 became 28oz at $1.89.
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(0, 1.79), (86_400, 1.89)])
        let record = detector.analyze(product: product)

        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitThen ?? 0, 1.79 / 32, accuracy: 0.0001)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_priceHistory_singleSnapshotHasNoThen() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(86_400, 1.89)])
        let record = detector.analyze(product: product)

        XCTAssertNil(record.priceThen)
        XCTAssertNil(record.costPerUnitThen)
        XCTAssertEqual(record.costPerUnitNow ?? 0, 1.89 / 28, accuracy: 0.0001)
    }

    func test_priceHistory_isSortedByDate() {
        let product = makePriced(sizes: [(32, "oz"), (28, "oz")], prices: [(86_400, 1.89), (0, 1.79)])
        let record = detector.analyze(product: product)
        XCTAssertEqual(record.priceNow ?? 0, 1.89, accuracy: 0.0001)
        XCTAssertEqual(record.priceThen ?? 0, 1.79, accuracy: 0.0001)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the iOS test command with `-only-testing:ShrunkTests/ShrinkDetectorTests`.
Expected: compile error `cannot find 'PricePoint' in scope`.

- [ ] **Step 3: Add `PricePoint` and `priceHistory`**

In `Shrunk/Models/ShrunkProduct.swift`, append `priceHistory` as the **last** stored property of `ShrunkProduct` (keep `needsConfirmation` exactly where Phase 2 put it) and add the new struct below:

```swift
struct ShrunkProduct: Identifiable, Codable, Hashable {
    let id: String              // barcode (13-digit GTIN)
    let name: String
    let brand: String
    let category: String
    let imageURL: URL?
    let sizeHistory: [SizeRecord]
    let currentPrice: Double?
    let currency: String
    let needsConfirmation: Bool        // Phase 2 — leave in place
    /// Store price snapshots, oldest first. Empty unless a store is set.
    var priceHistory: [PricePoint] = []
}

/// One observed shelf price at the user's store.
struct PricePoint: Codable, Hashable {
    let date: Date
    let price: Double            // promo when there was one, else regular
    let perUnitEstimate: Double? // Kroger's own $/unit estimate — display only
}
```

- [ ] **Step 4: Fill the prices in `ShrinkDetector.analyze`**

In `Shrunk/Services/ShrinkDetector.swift`, replace the whole `analyze(product:)` function with:

```swift
    func analyze(product: ShrunkProduct) -> ShrinkRecord {
        let sorted = product.sizeHistory.sorted { $0.date < $1.date }

        // Only compare records of the same kind as the most recent one —
        // grams vs fluid ounces must never produce a verdict.
        let sameKind: [SizeRecord] = {
            guard let latestKind = sorted.last?.unitKind else { return [] }
            return sorted.filter { $0.unitKind == latestKind }
        }()

        // The two most recent store snapshots, oldest first.
        let prices = product.priceHistory.sorted { $0.date < $1.date }
        let priceNow = prices.last?.price ?? product.currentPrice
        let priceThen = prices.count >= 2 ? prices[prices.count - 2].price : nil

        guard sameKind.count >= 2 else {
            return ShrinkRecord(
                product: product,
                previousSize: sorted.last,
                currentSize: sorted.last,
                shrinkPercent: 0,
                priceThen: nil,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: nil,
                verdict: .insufficientData
            )
        }

        let normalized = sameKind.map(Self.normalize)
        let current  = normalized.last!
        let previous = normalized.dropLast().last!

        // Guard against zero-quantity records that would explode the percentage math.
        guard previous.quantity > 0 else {
            return ShrinkRecord(
                product: product,
                previousSize: sameKind[sameKind.count - 2],
                currentSize: sameKind.last!,
                shrinkPercent: 0,
                priceThen: priceThen,
                priceNow: priceNow,
                costPerUnitThen: nil,
                costPerUnitNow: priceNow.map { $0 / max(current.quantity, 0.0001) },
                verdict: .insufficientData
            )
        }

        let percentChange = ((current.quantity - previous.quantity) / previous.quantity) * 100

        // "Now" is today's price over today's size; "then" is the older snapshot
        // over the older size — the cost this shopper used to pay.
        let costPerUnitNow: Double? = priceNow.map { $0 / current.quantity }
        let costPerUnitThen: Double? = priceThen.map { $0 / previous.quantity }

        let verdict: ShrinkRecord.ShrinkVerdict = {
            switch percentChange {
            case ..<(-10):    return .significantShrink
            case -10 ..< -5:  return .moderateShrink
            case -5  ..< -1:  return .minorShrink
            case -1 ..< 1:    return .unchanged
            default:          return .grew
            }
        }()

        return ShrinkRecord(
            product: product,
            previousSize: sameKind[sameKind.count - 2],
            currentSize: sameKind.last!,
            shrinkPercent: percentChange,
            priceThen: priceThen,
            priceNow: priceNow,
            costPerUnitThen: costPerUnitThen,
            costPerUnitNow: costPerUnitNow,
            verdict: verdict
        )
    }
```

Leave `normalize(_:)` untouched.

- [ ] **Step 5: Map the snapshots in `ProductDTO`**

In `Shrunk/Services/ShrunkAPIClient.swift`, add `needs_confirmation` to `ProductDTO` (after `unit_kind`):

```swift
    let needs_confirmation: Bool?
```

and replace `toProduct()` with:

```swift
    func toProduct() -> ShrunkProduct {
        let history = observations.map {
            SizeRecord(
                date: Date(timeIntervalSince1970: TimeInterval($0.observed_at)),
                quantity: $0.quantity,
                unit: Self.unit(forKind: $0.unit_kind),
                source: $0.source
            )
        }

        // Snapshots arrive newest-first; PricePoint keeps them oldest-first.
        let prices: [PricePoint] = price_snapshots
            .sorted { $0.observed_at < $1.observed_at }
            .compactMap { snap in
                let price: Double? = (snap.promo ?? 0) > 0 ? snap.promo : snap.regular
                guard let price, price > 0 else { return nil }
                return PricePoint(
                    date: Date(timeIntervalSince1970: TimeInterval(snap.observed_at)),
                    price: price,
                    perUnitEstimate: snap.per_unit_estimate
                )
            }

        return ShrunkProduct(
            id: gtin,
            name: name,
            brand: brand,
            category: category.isEmpty ? "Uncategorized" : category,
            imageURL: image_url.flatMap(URL.init),
            sizeHistory: history,
            currentPrice: prices.last?.price,
            currency: "USD",
            needsConfirmation: needs_confirmation ?? false,
            priceHistory: prices
        )
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the iOS test command with `-only-testing:ShrunkTests/ShrinkDetectorTests -only-testing:ShrunkTests/ShrunkAPIClientTests`.
Expected: both suites pass, including the three new price tests. If `ShrunkAPIClientTests` fails to decode, its fixture JSON predates `needs_confirmation` — that is why the field is optional; check for a typo rather than making the fixture change.

- [ ] **Step 7: Commit**

```bash
git add Shrunk/Models/ShrunkProduct.swift Shrunk/Services/ShrinkDetector.swift Shrunk/Services/ShrunkAPIClient.swift ShrunkTests/ShrinkDetectorTests.swift
git commit -m "feat(ios): cost per unit then/now from store price snapshots"
```

---

### Task 16: Rewrite `AlternativesEngine` over the store search

**Files:**
- Modify: `Shrunk/Models/Alternative.swift`
- Modify: `Shrunk/Services/AlternativesEngine.swift` (full rewrite)
- Modify: `Shrunk/Features/Alternatives/AlternativesViewModel.swift`, `AlternativesView.swift`, `AlternativeRow.swift`
- Test: `ShrunkTests/AlternativesEngineTests.swift`

**Interfaces:**
- Consumes: `StoreDataProviding`, `TrendingFeedProviding` (Task 12); `StubStoreData`, `StubTrendingFeed`, `StoreLocation.fixture` (Task 13).
- Produces: `Alternative` — `id`, `name`, `brand`, `size`, `costPerUnit: Double?` ($/oz-equivalent), `savingsPercent: Double?`, `imageURL`, `verdict`, `source: Alternative.Source { store, curated }`, `price: Double?`, `stockLabel: String?`. `hasShrunkBefore` is **removed** — a store search cannot know it, and the row must not claim it.
- Produces: `AlternativesResult { alternatives: [Alternative]; hiddenCount: Int; isCurated: Bool }`, `static let empty`.
- Produces: `AlternativesEngine(store:feed:)` with `findAlternatives(for:shrinkRecord:locationId:isPro:) async -> AlternativesResult` — store rows are same-category, in stock, same unit kind, scanned GTIN excluded, cheapest $/oz first; free callers get 3 with `hiddenCount` set, Pro gets everything; no store or an unreachable Kroger falls back to curated cases with `isCurated == true`.

- [ ] **Step 1: Write the failing test**

`ShrunkTests/AlternativesEngineTests.swift`:

```swift
import XCTest
@testable import Shrunk

final class AlternativesEngineTests: XCTestCase {
    private let detector = ShrinkDetector()

    private func scanned(category: String = "Beverages", price: Double? = 1.89) -> ShrunkProduct {
        ShrunkProduct(
            id: "0028400642255", name: "Gatorade", brand: "Gatorade", category: category,
            imageURL: nil,
            sizeHistory: [
                SizeRecord(date: Date(timeIntervalSince1970: 1_600_000_000), quantity: 946.353, unit: "ml", source: "fdc"),
                SizeRecord(date: Date(timeIntervalSince1970: 1_700_000_000), quantity: 828.058, unit: "ml", source: "fdc")
            ],
            currentPrice: price, currency: "USD", needsConfirmation: false,
            priceHistory: price.map { [PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000), price: $0, perUnitEstimate: nil)] } ?? []
        )
    }

    private func candidate(_ id: String, price: Double, ml: Double, stock: String = "HIGH") -> StoreSearchResult {
        StoreSearchResult(
            gtin: id, productId: "k-\(id)", brand: "Brand", description: "Candidate \(id)",
            category: "Beverages", imageURL: nil, size: "\(Int(ml)) ml", quantity: ml,
            unitKind: "volume", regular: price, promo: 0, stockLevel: stock
        )
    }

    private func engine(_ store: StubStoreData, _ feed: StubTrendingFeed = StubTrendingFeed()) -> AlternativesEngine {
        AlternativesEngine(store: store, feed: feed)
    }

    func test_ranksCheapestPerOunceFirstAndExcludesTheScannedProduct() async {
        let store = StubStoreData()
        store.searchResult = .success([
            candidate("0000000000011", price: 3.00, ml: 1000),   // 0.0030 /ml
            candidate("0028400642255", price: 0.10, ml: 1000),   // the scanned product — excluded
            candidate("0000000000022", price: 1.00, ml: 1000)    // 0.0010 /ml — cheapest
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertEqual(store.searchTerms, ["Beverages"])
        XCTAssertEqual(store.searchLocationIds, ["01400943"])
        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000022", "0000000000011"])
        XCTAssertFalse(result.isCurated)
        XCTAssertEqual(result.hiddenCount, 0)
        XCTAssertEqual(result.alternatives[0].source, .store)
    }

    func test_dropsOutOfStockAndOtherUnitKinds() async {
        let store = StubStoreData()
        var countPack = candidate("0000000000033", price: 1.00, ml: 1000)
        countPack = StoreSearchResult(
            gtin: countPack.gtin, productId: countPack.productId, brand: countPack.brand,
            description: countPack.description, category: countPack.category, imageURL: nil,
            size: "12 ct", quantity: 12, unitKind: "count", regular: 1.0, promo: 0, stockLevel: "HIGH"
        )
        store.searchResult = .success([
            candidate("0000000000011", price: 1.00, ml: 1000, stock: "TEMPORARILY_OUT_OF_STOCK"),
            countPack,
            candidate("0000000000044", price: 2.00, ml: 1000)
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000044"])
    }

    func test_freeUsersGetThreeRowsAndAHiddenCount() async {
        let store = StubStoreData()
        store.searchResult = .success((1...5).map { candidate("000000000\($0)0\($0)", price: Double($0), ml: 1000) })
        let product = scanned()
        let record = detector.analyze(product: product)

        let free = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: false)
        XCTAssertEqual(free.alternatives.count, 3)
        XCTAssertEqual(free.hiddenCount, 2)

        let pro = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)
        XCTAssertEqual(pro.alternatives.count, 5)
        XCTAssertEqual(pro.hiddenCount, 0)
    }

    func test_savingsIsComputedAgainstTheScannedCostPerOunce() async {
        let store = StubStoreData()
        // Scanned: $1.89 / 828.058 ml -> normalize() gives oz-equivalents.
        store.searchResult = .success([candidate("0000000000011", price: 1.00, ml: 828.058)])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await engine(store).findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        let savings = try! XCTUnwrap(result.alternatives[0].savingsPercent)
        XCTAssertEqual(savings, ((1.89 - 1.00) / 1.89) * 100, accuracy: 0.01)
        XCTAssertTrue(result.alternatives[0].verdict.contains("cheaper per oz"))
    }

    func test_noStoreFallsBackToCuratedCasesInTheSameCategory() async {
        let feed = StubTrendingFeed()
        feed.feed = TrendingFeed(version: 1, updated: Date(), trending: [
            TrendingEntry(barcode: "0000000000011", name: "Verified Case", brand: "Brand", category: "Beverages",
                          imageUrl: nil,
                          history: [TrendingEntry.HistoryPoint(date: Date(timeIntervalSince1970: 1_600_000_000), quantity: 32, unit: "fl oz")],
                          currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date()),
            TrendingEntry(barcode: "0000000000022", name: "Other Category", brand: "Brand", category: "Snacks",
                          imageUrl: nil, history: [], currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date())
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await AlternativesEngine(store: StubStoreData(), feed: feed)
            .findAlternatives(for: product, shrinkRecord: record, locationId: nil, isPro: true)

        XCTAssertTrue(result.isCurated)
        XCTAssertEqual(result.alternatives.map(\.id), ["0000000000011"])
        XCTAssertEqual(result.alternatives[0].source, .curated)
        XCTAssertNil(result.alternatives[0].costPerUnit)
    }

    func test_krogerFailureFallsBackToCurated() async {
        let store = StubStoreData()
        store.searchResult = .failure(ShrunkError.invalidResponse)
        let feed = StubTrendingFeed()
        feed.feed = TrendingFeed(version: 1, updated: Date(), trending: [
            TrendingEntry(barcode: "0000000000011", name: "Verified Case", brand: "Brand", category: "Beverages",
                          imageUrl: nil, history: [], currentPrice: nil, currency: "USD", evidenceUrl: nil, addedAt: Date())
        ])
        let product = scanned()
        let record = detector.analyze(product: product)

        let result = await AlternativesEngine(store: store, feed: feed)
            .findAlternatives(for: product, shrinkRecord: record, locationId: "01400943", isPro: true)

        XCTAssertTrue(result.isCurated)
        XCTAssertEqual(result.alternatives.count, 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the iOS test command with `-only-testing:ShrunkTests/AlternativesEngineTests`.
Expected: compile errors — `AlternativesEngine` has no `init(store:feed:)` and `AlternativesResult` does not exist.

- [ ] **Step 3: Rewrite the model**

`Shrunk/Models/Alternative.swift` (whole file):

```swift
import Foundation

struct Alternative: Identifiable, Hashable {
    enum Source: String, Hashable {
        case store      // live from the user's Kroger
        case curated    // verified case from the trending feed
    }

    let id: String              // 13-digit GTIN
    let name: String
    let brand: String
    let size: String            // human-readable: "32 fl oz"
    let costPerUnit: Double?    // $/oz-equivalent — nil for curated rows
    let savingsPercent: Double? // vs the scanned product; nil when we can't compare
    let imageURL: URL?
    let verdict: String
    let source: Source
    let price: Double?          // shelf price at the store
    let stockLabel: String?     // "In stock" / "Low stock"
}

/// What the alternatives sheet renders: the rows the caller may see, how many
/// were withheld behind Pro, and whether these are store prices or curated cases.
struct AlternativesResult: Hashable {
    let alternatives: [Alternative]
    let hiddenCount: Int
    let isCurated: Bool

    static let empty = AlternativesResult(alternatives: [], hiddenCount: 0, isCurated: false)
}
```

- [ ] **Step 4: Rewrite the engine**

`Shrunk/Services/AlternativesEngine.swift` (whole file):

```swift
import Foundation

/// Ranks in-stock products in the same category at the user's store by cost per
/// ounce, cheapest first. Without a store — or when Kroger is unreachable — it
/// falls back to curated verified cases in the same category (spec §7, §8).
struct AlternativesEngine {
    /// Spec §3 — free sees 3 alternatives, Pro sees all of them.
    private let freeLimit = 3

    private let store: any StoreDataProviding
    private let feed: any TrendingFeedProviding

    init(store: any StoreDataProviding = ShrunkAPIClient.shared,
         feed: any TrendingFeedProviding = TrendingFeedService.shared) {
        self.store = store
        self.feed = feed
    }

    func findAlternatives(
        for product: ShrunkProduct,
        shrinkRecord: ShrinkRecord,
        locationId: String?,
        isPro: Bool
    ) async -> AlternativesResult {
        guard !product.category.isEmpty else { return .empty }

        if let locationId {
            let rows = await storeAlternatives(for: product, record: shrinkRecord, locationId: locationId)
            if !rows.isEmpty { return cap(rows, isPro: isPro, isCurated: false) }
        }
        return cap(await curatedAlternatives(for: product), isPro: isPro, isCurated: true)
    }

    // MARK: - Store search

    private func storeAlternatives(
        for product: ShrunkProduct,
        record: ShrinkRecord,
        locationId: String
    ) async -> [Alternative] {
        let results: [StoreSearchResult]
        do {
            results = try await store.search(term: product.category, locationId: locationId)
        } catch {
            return []   // Kroger never blocks the screen (spec §8)
        }

        // Only compare like with like: an "unknown" kind means no filter.
        let scannedKind: String? = record.currentSize
            .map(\.unitKind)
            .flatMap { $0 == "unknown" ? nil : $0 }
        let scannedCostPerOz = record.costPerUnitNow

        return results
            .filter { $0.gtin != product.id }
            .filter { $0.inStock }
            .filter { scannedKind == nil || $0.unitKind == scannedKind }
            .compactMap { result -> (StoreSearchResult, Double)? in
                guard let cost = Self.costPerOunce(result) else { return nil }
                return (result, cost)
            }
            .sorted { $0.1 < $1.1 }
            .map { makeAlternative(from: $0.0, costPerOz: $0.1, scannedCostPerOz: scannedCostPerOz) }
    }

    /// The candidate's price in the same oz-equivalent space `ShrinkDetector`
    /// uses, so it is directly comparable with `record.costPerUnitNow`.
    static func costPerOunce(_ result: StoreSearchResult) -> Double? {
        guard let price = result.effectivePrice,
              let quantity = result.quantity, quantity > 0,
              let kind = result.unitKind else { return nil }
        let unit: String
        switch kind {
        case "mass":   unit = "g"
        case "volume": unit = "ml"
        default:       unit = "count"
        }
        let normalized = ShrinkDetector.normalize(
            SizeRecord(date: Date(), quantity: quantity, unit: unit, source: "kroger")
        ).quantity
        guard normalized > 0 else { return nil }
        return price / normalized
    }

    private func makeAlternative(
        from result: StoreSearchResult,
        costPerOz: Double,
        scannedCostPerOz: Double?
    ) -> Alternative {
        let savings: Double? = scannedCostPerOz.flatMap { scanned in
            scanned > 0 ? ((scanned - costPerOz) / scanned) * 100 : nil
        }

        let verdict: String
        if let savings, savings > 0 {
            verdict = "\(Int(savings.rounded()))% cheaper per oz at your store."
        } else if let price = result.effectivePrice {
            verdict = "\(price.formattedPrice()) · \(costPerOz.formattedCostPerUnit()) per oz at your store."
        } else {
            verdict = "In stock at your store."
        }

        return Alternative(
            id: result.gtin ?? result.productId,
            name: result.description,
            brand: result.brand,
            size: result.size ?? "",
            costPerUnit: costPerOz,
            savingsPercent: savings,
            imageURL: result.imageURL,
            verdict: verdict,
            source: .store,
            price: result.effectivePrice,
            stockLabel: result.stockLabel
        )
    }

    // MARK: - Curated fallback

    private func curatedAlternatives(for product: ShrunkProduct) async -> [Alternative] {
        let category = product.category.lowercased()
        return await feed.fetch().trending
            .filter { $0.barcode != product.id }
            .filter { $0.category.lowercased() == category }
            .map { entry in
                Alternative(
                    id: entry.barcode,
                    name: entry.name,
                    brand: entry.brand,
                    size: entry.history.last.map { $0.quantity.formattedQuantity(unit: $0.unit) } ?? "",
                    costPerUnit: nil,
                    savingsPercent: nil,
                    imageURL: entry.imageUrl,
                    verdict: "Verified shrink on record — tap for the evidence.",
                    source: .curated,
                    price: nil,
                    stockLabel: nil
                )
            }
    }

    // MARK: - Pro gating

    private func cap(_ rows: [Alternative], isPro: Bool, isCurated: Bool) -> AlternativesResult {
        guard !isPro, rows.count > freeLimit else {
            return AlternativesResult(alternatives: rows, hiddenCount: 0, isCurated: isCurated)
        }
        return AlternativesResult(
            alternatives: Array(rows.prefix(freeLimit)),
            hiddenCount: rows.count - freeLimit,
            isCurated: isCurated
        )
    }
}
```

- [ ] **Step 5: Update the alternatives screen**

`Shrunk/Features/Alternatives/AlternativesViewModel.swift` (whole file):

```swift
import Foundation

@MainActor
final class AlternativesViewModel: ObservableObject {
    @Published var presentedBarcode: String?
    @Published var showPaywall: Bool = false

    let sourceProduct: ShrunkProduct
    let sourceRecord: ShrinkRecord
    let result: AlternativesResult

    init(product: ShrunkProduct, record: ShrinkRecord, result: AlternativesResult) {
        self.sourceProduct = product
        self.sourceRecord = record
        self.result = result
    }

    var alternatives: [Alternative] { result.alternatives }
    var hiddenCount: Int { result.hiddenCount }
    var isCurated: Bool { result.isCurated }

    /// Curated rows are verified cases, not recommendations — say so.
    var title: String { isCurated ? "Verified cases in this category" : "Cheaper at your store" }

    func present(_ alternative: Alternative) {
        presentedBarcode = alternative.id
    }

    func headerCostPerUnitText() -> String {
        guard let curr = sourceRecord.costPerUnitNow else { return sourceProduct.name }
        let sizeStr: String
        if let currentSize = sourceRecord.currentSize {
            sizeStr = currentSize.quantity.formattedQuantity(unit: currentSize.unit)
        } else {
            sizeStr = ""
        }
        return "vs. \(sourceProduct.name) \(sizeStr) · \(curr.formattedCostPerUnit(currency: sourceProduct.currency))"
    }
}
```

In `Shrunk/Features/Alternatives/AlternativesView.swift`: change the initialiser, the empty state, the row loop, and the unlock CTA.

```swift
    init(product: ShrunkProduct, record: ShrinkRecord, result: AlternativesResult) {
        _vm = StateObject(wrappedValue: AlternativesViewModel(product: product, record: record, result: result))
    }
```

```swift
                    if vm.alternatives.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Nothing to compare yet",
                            message: "Set your store in Settings to see in-stock alternatives ranked by cost per ounce."
                        )
                    } else {
                        if vm.isCurated {
                            Text("Verified cases in this category")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.smoke)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        }
                        VStack(spacing: ShrunkTheme.Spacing.md) {
                            ForEach(Array(vm.alternatives.enumerated()), id: \.element.id) { idx, alt in
                                AlternativeRow(
                                    alternative: alt,
                                    isBestPick: idx == 0 && !vm.isCurated,
                                    onTap: { vm.present(alt) }
                                )
                            }
                        }
                        .padding(.horizontal, ShrunkTheme.Spacing.lg)

                        if !storeKit.isProUser, vm.hiddenCount > 0 {
                            unlockMoreCTA
                                .padding(.horizontal, ShrunkTheme.Spacing.lg)
                        }
                    }
```

and in `unlockMoreCTA` replace the count line:

```swift
                Text("\(vm.hiddenCount) more alternatives")
```

Add the attribution under the list, just above the closing `.padding(.bottom, ...)` of the outer `VStack`:

```swift
                    if !vm.isCurated {
                        Text(LivePrice.attribution)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.smoke)
                            .frame(maxWidth: .infinity)
                            .padding(.top, ShrunkTheme.Spacing.sm)
                    }
```

In `Shrunk/Features/Alternatives/AlternativeRow.swift`: drop `isLocked` and `blurOverlay`, and stop claiming shrink history we do not have.

```swift
struct AlternativeRow: View {
    let alternative: Alternative
    let isBestPick: Bool
    let onTap: () -> Void
```

Remove the `.overlay(isLocked ? AnyView(blurOverlay) : AnyView(EmptyView()))` modifier and the whole `blurOverlay` property, and change the lock glyph to a plain chevron:

```swift
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Color.smokeSoft)
```

Replace `savingsBadge` and `statRow`:

```swift
    private var savingsBadge: some View {
        ZStack {
            Circle()
                .fill(alternative.savingsPercent.map { $0 > 0 } == true ? Color.verdictGoodTint : Color.mist)
                .frame(width: 56, height: 56)
            VStack(spacing: -1) {
                Text(badgeTop)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(alternative.savingsPercent.map { $0 > 0 } == true ? Color.verdictGoodDeep : Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(badgeBottom)
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.smoke)
            }
            .padding(.horizontal, 4)
        }
    }

    private var badgeTop: String {
        if let savings = alternative.savingsPercent, savings > 0 { return "-\(Int(savings.rounded()))%" }
        if let cost = alternative.costPerUnit { return cost.formattedCostPerUnit() }
        return "✓"
    }

    private var badgeBottom: String {
        if alternative.savingsPercent.map({ $0 > 0 }) == true { return "¢/oz" }
        return alternative.source == .curated ? "verified" : "per oz"
    }

    private var statRow: some View {
        HStack(spacing: 8) {
            if let cost = alternative.costPerUnit {
                miniStat(label: "Cost / oz", value: cost.formattedCostPerUnit())
            }
            if let price = alternative.price {
                miniStat(label: "Price", value: price.formattedPrice())
            }
            if let stock = alternative.stockLabel {
                miniStat(label: "Stock", value: stock, tone: stock == "Out of stock" ? .alert : .good)
            }
        }
    }
```

- [ ] **Step 6: Point `ResultViewModel` at the new signature**

In `Shrunk/Features/Result/ResultViewModel.swift`, rename the published property and pass the store + Pro state (the store id and `isPro` wiring is finished in Task 17):

```swift
    @Published var alternativesResult: AlternativesResult = .empty
```

```swift
    private func loadAlternatives(for product: ShrunkProduct, record: ShrinkRecord) async {
        isLoadingAlternatives = true
        alternativesResult = await engine.findAlternatives(
            for: product,
            shrinkRecord: record,
            locationId: locationId,
            isPro: isPro
        )
        isLoadingAlternatives = false
    }
```

and replace every `alternatives = []` with `alternativesResult = .empty`. Add the two inputs the call needs (both are finished in Task 17; declare them now so this task builds):

```swift
    /// The store the user picked, if any (spec §7).
    private var locationId: String? {
        let saved = defaults.string(forKey: StorePickerViewModel.locationIdKey)
        return (saved?.isEmpty ?? true) ? nil : saved
    }

    /// Set by the view from `StoreKitService.isProUser` before loading.
    var isPro: Bool = false
```

with `private let defaults: UserDefaults` added to the stored properties and `defaults: UserDefaults = .standard` added as the last initialiser parameter.

In `Shrunk/Features/Result/ResultView.swift`, update the sheet:

```swift
        .sheet(isPresented: $showAlternatives) {
            AlternativesView(product: product, record: record, result: vm.alternativesResult)
        }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the iOS test command with `-only-testing:ShrunkTests/AlternativesEngineTests`, then the whole suite.
Expected: `AlternativesEngineTests` 6 tests pass and the app still builds.

- [ ] **Step 8: Commit**

```bash
git add Shrunk/Models/Alternative.swift Shrunk/Services/AlternativesEngine.swift Shrunk/Features/Alternatives Shrunk/Features/Result ShrunkTests/AlternativesEngineTests.swift
git commit -m "feat(ios): alternatives ranked by cost per ounce at the user's store"
```

---

### Task 17: Live-price panel on the result screen

**Files:**
- Create: `Shrunk/Features/Result/LivePricePanel.swift`
- Modify: `Shrunk/Features/Result/ResultViewModel.swift`, `Shrunk/Features/Result/ResultView.swift`

**Interfaces:**
- Consumes: `ShrunkAPIClient.liveProduct(barcode:locationId:)`, `LivePrice`, `StorePickerViewModel.locationIdKey`/`.storeNameKey`.
- Produces: `enum LivePriceState { hidden, loading, loaded(LivePrice), unavailable }` — declared at file scope in `ResultViewModel.swift`, not nested, so the view can name it without touching the `@MainActor` class — on `@Published var livePrice`; `load(barcode:)` now passes the saved `locationId` to `/v1/product` and then fetches the live price when a store is set.
- Produces: `LivePricePanel(state:storeName:)` — regular/promo, cost per ounce, stock, `"Prices from Kroger"`, and the `"Store prices unavailable right now"` fallback (spec §7, §8).
- Note: Phase 2's "Confirm with a label photo" card is gated on `ShrunkProduct.needsConfirmation`; Task 8 makes the Worker set that flag from the Kroger comparison, so the card now lights up on its own. Nothing to change here.

- [ ] **Step 1: Add the live-price state to the view model**

In `Shrunk/Features/Result/ResultViewModel.swift`, add the state type at **file scope** (above the class — `LivePricePanel` names it directly) and the property inside the class:

```swift
/// What the result screen shows for the user's store.
enum LivePriceState: Equatable {
    case hidden          // no store set — the panel is not shown at all
    case loading
    case loaded(LivePrice)
    case unavailable     // Kroger down, key revoked, or not carried here
}
```

```swift
    @Published var livePrice: LivePriceState = .hidden
```

Replace `load(barcode:)` and add the fetch below it:

```swift
    func load(barcode: String) async {
        if case .loaded = state { return }   // already prebaked — don't clobber
        state = .loading
        alternativesResult = .empty
        livePrice = locationId == nil ? .hidden : .loading

        do {
            let product = try await api.fetchProduct(barcode: barcode, locationId: locationId)
            let record = detector.analyze(product: product)
            state = .loaded(product, record)
            await loadLivePrice(barcode: barcode)
            await loadAlternatives(for: product, record: record)
        } catch ShrunkError.productNotFound {
            state = .notFound(barcode: barcode)
            livePrice = .hidden
        } catch let error as ShrunkError {
            state = .error(error.errorDescription ?? "Something went wrong.")
            livePrice = .hidden
        } catch {
            state = .error(error.localizedDescription)
            livePrice = .hidden
        }
    }

    /// Live price is strictly additive — a Kroger failure never changes `state`
    /// (spec §8).
    private func loadLivePrice(barcode: String) async {
        guard let locationId else {
            livePrice = .hidden
            return
        }
        livePrice = .loading
        do {
            livePrice = .loaded(try await api.liveProduct(barcode: barcode, locationId: locationId))
        } catch {
            livePrice = .unavailable
        }
    }
```

`prebake(product:record:)` also gains the live fetch so curated Browse cards show a price:

```swift
    func prebake(product: ShrunkProduct, record: ShrinkRecord) {
        state = .loaded(product, record)
        alternativesResult = .empty
        Task {
            await loadLivePrice(barcode: product.id)
            await loadAlternatives(for: product, record: record)
        }
    }
```

- [ ] **Step 2: Write the panel**

`Shrunk/Features/Result/LivePricePanel.swift`:

```swift
import SwiftUI

/// Live shelf price at the user's store. Kroger's terms require the
/// attribution wherever their data appears (spec §9).
struct LivePricePanel: View {
    let state: LivePriceState
    let storeName: String

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            card {
                HStack(spacing: ShrunkTheme.Spacing.sm) {
                    ProgressView().controlSize(.small).tint(Color.shrunkRed)
                    Text("Checking \(storeName.isEmpty ? "your store" : storeName)…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.smoke)
                }
            }
        case .unavailable:
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Store prices unavailable right now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("The verdict and size history above don't need them.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.smoke)
                }
            }
        case .loaded(let live):
            card { loaded(live) }
        }
    }

    @ViewBuilder
    private func loaded(_ live: LivePrice) -> some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let price = live.effectivePrice {
                    Text(price.formattedPrice())
                        .font(.shrunkMonoBig)
                        .foregroundStyle(Color.ink)
                } else {
                    Text("—").font(.shrunkMonoBig).foregroundStyle(Color.smoke)
                }
                if live.isOnPromo, let regular = live.regular {
                    Text(regular.formattedPrice())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.smoke)
                        .strikethrough()
                    Text("PROMO")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.shrunkRed)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(live.stockLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(live.inStock ? Color.verdictGoodDeep : Color.shrunkRedDark)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(live.inStock ? Color.verdictGoodTint : Color.shrunkRedLight)
                    .clipShape(Capsule())
            }

            HStack(spacing: ShrunkTheme.Spacing.md) {
                if let size = live.size, !size.isEmpty {
                    detail(label: "Size", value: size)
                }
                if let perOz = costPerOunce(live) {
                    detail(label: "Cost / oz", value: perOz.formattedCostPerUnit())
                }
            }
        }
    }

    /// Same oz-equivalent space the verdict uses, so the two numbers agree.
    private func costPerOunce(_ live: LivePrice) -> Double? {
        guard let price = live.effectivePrice, let quantity = live.quantity, quantity > 0, let kind = live.unitKind else { return nil }
        let unit: String
        switch kind {
        case "mass":   unit = "g"
        case "volume": unit = "ml"
        default:       unit = "count"
        }
        let normalized = ShrinkDetector.normalize(
            SizeRecord(date: Date(), quantity: quantity, unit: unit, source: "kroger")
        ).quantity
        guard normalized > 0 else { return nil }
        return price / normalized
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Color.smoke)
            Text(value)
                .font(.shrunkMonoSmall)
                .foregroundStyle(Color.ink)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack {
                Text(storeName.isEmpty ? "AT YOUR STORE" : storeName.uppercased()).shrunkSectionLabel()
                Spacer()
                Text(LivePrice.attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.smoke)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shrunkCard(radius: ShrunkTheme.Radius.lg, padding: ShrunkTheme.Spacing.md)
        .padding(.horizontal, ShrunkTheme.Spacing.lg)
    }
}
```

- [ ] **Step 3: Mount it in `ResultView`**

In `Shrunk/Features/Result/ResultView.swift`, add the store name and pass Pro state through:

```swift
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""
```

```swift
        .task(id: barcode) {
            vm.isPro = storeKit.isProUser
            if let prebake { vm.prebake(product: prebake.product, record: prebake.record) }
            await vm.load(barcode: barcode)
        }
```

and insert the panel in `loadedView`, immediately after `costPerOzSection(record: record)`:

```swift
                LivePricePanel(state: vm.livePrice, storeName: storeName)
```

- [ ] **Step 4: Build and run the whole suite**

```bash
xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds, all suites pass.

- [ ] **Step 5: Smoke-test against the deployed Worker**

Set a Cincinnati store in Settings (ZIP `45044`), then scan or key in `0028400642255`. Expected: the result screen shows the verdict, then a panel headed with the store name showing a price, cost per ounce, stock and "Prices from Kroger". Turn on Airplane Mode for the Kroger leg by setting the store to a location with no coverage — or temporarily deploy with a bad `KROGER_CLIENT_SECRET` — and confirm the panel reads "Store prices unavailable right now" while the verdict still renders.

- [ ] **Step 6: Commit**

```bash
git add Shrunk/Features/Result
git commit -m "feat(ios): live store price panel on the result screen"
```

---

### Task 18: Retire Open Food Facts from the app

`AlternativesEngine` was the last consumer (Task 16). `ShrunkError` lives inside `OpenFoodFactsService.swift` and everything uses it, so it moves out first.

**Files:**
- Create: `Shrunk/Models/ShrunkError.swift`
- Delete: `Shrunk/Services/OpenFoodFactsService.swift`, `ShrunkTests/OpenFoodFactsServiceTests.swift`
- Modify: `ShrunkTests/ShrunkTests.swift` (stale comment)

**Interfaces:**
- Produces: `enum ShrunkError: LocalizedError { case productNotFound, invalidResponse, network(Error), decoding(Error) }` at its new home — identical cases and messages, so no call site changes.
- Removes: `OpenFoodFactsService`, `OFFResponse`, `OFFProduct`, `parseQuantity`, `buildHistory`, `mapToProduct`.

- [ ] **Step 1: Move `ShrunkError` to its own file**

`Shrunk/Models/ShrunkError.swift`:

```swift
import Foundation

/// Every failure the app surfaces from the Shrunk API. The copy is user-facing.
enum ShrunkError: LocalizedError {
    case productNotFound
    case invalidResponse
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .productNotFound:    return "Not in our database yet."
        case .invalidResponse:    return "We couldn't read the response from the data source."
        case .network(let e):     return e.localizedDescription
        case .decoding(let e):    return "Couldn't read product data. (\(e.localizedDescription))"
        }
    }
}
```

- [ ] **Step 2: Check nothing else still needs the OFF service**

```bash
cd /Users/drao/Projects/shrunk
grep -rn "OpenFoodFactsService\|OFFProduct\|OFFResponse" --include="*.swift" Shrunk ShrunkTests \
  | grep -v "Shrunk/Services/OpenFoodFactsService.swift" \
  | grep -v "ShrunkTests/OpenFoodFactsServiceTests.swift" \
  || echo "no remaining references"
```
Expected: `no remaining references`. Anything listed here must be migrated before Step 3 — the only legitimate hits are the two files being deleted.

- [ ] **Step 3: Delete the service and its tests**

```bash
cd /Users/drao/Projects/shrunk
git rm -q Shrunk/Services/OpenFoodFactsService.swift ShrunkTests/OpenFoodFactsServiceTests.swift
xcodegen generate >/dev/null
```

In `ShrunkTests/ShrunkTests.swift`, update the stale comment that names the deleted suite:

```swift
// ShrinkDetectorTests, ShrunkAPIClientTests, KrogerDTOTests, AlternativesEngineTests
// and StorePickerViewModelTests carry the actual coverage.
```

The Settings "Data" section still links to Open Food Facts as an attribution/contribution link — that is a credit for the name/image fallback the *Worker* still uses, and it stays.

- [ ] **Step 4: Run the whole suite**

```bash
cd /Users/drao/Projects/shrunk && xcodegen generate >/dev/null && \
  xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet 2>&1 | tail -30
```
Expected: build succeeds; `ShrinkDetectorTests`, `ShrunkAPIClientTests`, `KrogerDTOTests`, `AlternativesEngineTests`, `StorePickerViewModelTests` all pass. A `cannot find 'ShrunkError'` error means `xcodegen generate` did not pick up the new file — re-run it.

- [ ] **Step 5: Commit**

```bash
git add -A Shrunk ShrunkTests Shrunk.xcodeproj
git commit -m "refactor(ios): move ShrunkError to Models and delete OpenFoodFactsService"
```

---

## Phase 3 exit criteria

- `cd backend && npx vitest run && npx tsc --noEmit` — all green, including `kroger-ids`, `kroger-client`, `ratelimit`, `kroger-routes`, `kroger-persist`, `purge`, `sweep`.
- `cd scripts && python3 -m pytest tests -q` — all green (both normalizers still agree on `fixtures/package_weights.json`).
- `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'` — all green; no Swift file references Open Food Facts.
- Deployed Worker answers all three `/v1/kroger/*` routes with `"attribution":"Prices from Kroger"` and a forwarded `Cache-Control`; `wrangler deploy` reports the `0 */6 * * *` trigger.
- `SELECT COUNT(*) FROM price_snapshots` is non-zero after a live product lookup, and `POST /v1/admin/purge-kroger` returns it to zero.
- On device with a Cincinnati store set: scanning a carried product shows the live-price panel with cost per ounce and stock, and the alternatives sheet lists in-stock same-category products cheapest per ounce first — 3 rows free, all rows on Pro.
- With the store cleared, alternatives fall back to "Verified cases in this category" and nothing else on the screen changes.

Phase 4 (push sender, `/v1/devices`, watch sync, alert/digest crons) starts from here and replaces the sweep's `SELECT DISTINCT gtin, location_id FROM price_snapshots` with `watches × devices`.
