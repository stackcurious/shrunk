# Shrunk

Scan a grocery barcode; Shrunk tells you whether the package shrank while the price held — from observed size and price data, not vibes.

- **Free** — unlimited scans → verdict, size history, current price and cost-per-unit at your Kroger store; the browse feed; contributing label photos; 3 alternatives per scan.
- **Pro** — $2.99/month or $14.99/year with a 7-day free trial: watchlist alerts, the weekly "what shrank this week" digest, unlimited ranked alternatives, full price + size history charts, and a savings dashboard computed from real observations.

## Layout

| Path | What it is |
|---|---|
| `Shrunk/` | The iOS app — SwiftUI, iOS 17+, SwiftData, StoreKit 2, Vision OCR. |
| `ShrunkTests/` | XCTest unit tests for the app. |
| `backend/` | `shrunk-api` — the Cloudflare Worker (Hono 4) over D1 + R2 + KV. Every endpoint the app calls. |
| `scripts/` | Python 3.12+ tooling: the USDA FoodData Central importer, the curated seeder, the hit-rate report, repo-data checks. |
| `fixtures/` | `package_weights.json` — the one normalizer fixture file shared by Python, TypeScript and Swift. |
| `data/` | `trending.json` — the curated, human-verified shrinkflation catalogue. See [data/README.md](./data/README.md). |
| `docs/` | The v2 spec and phase plans (`docs/superpowers/`), App Store paperwork, privacy policy, terms. |
| `marketing/` | App Store screenshots. |
| `tasks/` | Session notes and `lessons.md`. |

`project.yml` is the source of truth for the Xcode project. `Shrunk.xcodeproj` is generated and **not** committed.

## Run it

### iOS app

```bash
brew install xcodegen
xcodegen generate
open Shrunk.xcodeproj          # or: xcodebuild build -scheme Shrunk -destination 'generic/platform=iOS Simulator'
```

Tests (substitute a simulator from `xcrun simctl list devices available`):

```bash
xcodegen generate && xcodebuild test -scheme Shrunk \
  -destination 'platform=iOS Simulator,name=BabSnap iPhone 17'
```

The app's base URL is `ShrunkAPIClient.defaultBaseURL` in `Shrunk/Services/ShrunkAPIClient.swift`: in DEBUG builds, set `UserDefaults.standard.bool(forKey: "useLocalAPI")` to `true` to point it at `http://localhost:8787` and run against a local Worker (`NSAllowsLocalNetworking` is already set in `Info.plist`); otherwise it targets the deployed Worker URL.

### Worker

```bash
cd backend
npm ci
npm run dev            # http://localhost:8787, needs backend/.dev.vars
npm test               # Vitest 4 in the Workers runtime, migrations applied
npm run typecheck
```

See [backend/README.md](./backend/README.md) for the endpoint table, bindings, secrets and cron schedule.

### Python tooling

```bash
cd scripts
python3 -m pytest tests -q

# Reload USDA FoodData Central (twice a year, on each release):
python3 fdc_import.py --zip /tmp/fdc_branded.zip --out out/fdc.sql \
  --report out/report.json --curated ../data/trending.json

# Seed the curated catalogue as source='curated' observations:
python3 seed_curated.py --curated ../data/trending.json --out out/curated.sql

# Coverage of the deployed API over the curated 35:
python3 hit_rate.py --api https://shrunk-api.<account>.workers.dev
```

## How the data flows

```
data/trending.json ──cp──────────────▶ Shrunk/Resources/trending.json   (app offline fallback)
        │
        ├──npm run sync:trending─────▶ backend/src/data/trending.json ──▶ GET /v1/feed
        │
        └──scripts/seed_curated.py───▶ SQL ──wrangler d1 execute──▶ D1 observations (source='curated', 1.0)

USDA FDC release zip ──scripts/fdc_import.py──▶ SQL ──wrangler d1 execute──▶ D1 products + observations (source='fdc', 0.9)

label photo ──Vision OCR on device──▶ POST /v1/observations ──▶ D1 (source='crowd') + R2 photo while pending review

Kroger Products API ──Worker proxy──▶ live size/price ──(KROGER_PERSIST=on)──▶ price_snapshots + observations (source='kroger', 0.8)

iOS app ──GET /v1/product/{gtin}?locationId=──▶ merged accepted observations + last 12 snapshots
        └──ShrinkDetector──▶ verdict, size history, cost-per-unit then/now
```

Quantities are normalized to grams, millilitres or count before storage; observations of different kinds are never compared.

## Deploy

```bash
cd backend
npx wrangler d1 migrations apply shrunk --remote
npx wrangler deploy
```

Full first-time setup — Cloudflare account, D1, KV, R2, every secret, the Kroger and Apple accounts — is in [docs/RELEASE_CHECKLIST.md](./docs/RELEASE_CHECKLIST.md).

## CI

`.github/workflows/ci.yml` runs on every push — including every push to an open PR's branch, so there is no separate `pull_request` trigger to double it up:

| Job | Runner | What it proves |
|---|---|---|
| `backend` | ubuntu | `npm ci`, `tsc --noEmit`, `vitest run` |
| `scripts` | ubuntu | `pytest` over the importer, normalizers and tooling |
| `fixtures` | ubuntu | `scripts/check_repo_data.py` — fixtures parse, every `trending.json` copy is in sync |
| `ios` | macOS | `xcodegen generate`, `xcodebuild build`, `xcodebuild test` on a discovered simulator |

## Docs

- Design spec: [`docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`](./docs/superpowers/specs/2026-08-26-shrunk-v2-design.md)
- Phase plans: [`docs/superpowers/plans/`](./docs/superpowers/plans/)
- Release runbook: [`docs/RELEASE_CHECKLIST.md`](./docs/RELEASE_CHECKLIST.md) · Acceptance run: [`scripts/acceptance.md`](./scripts/acceptance.md)
- App Store: [`docs/APP_STORE_LISTING.md`](./docs/APP_STORE_LISTING.md) · [`docs/ASC_SETUP.md`](./docs/ASC_SETUP.md)
- Legal: [`docs/PRIVACY_POLICY.md`](./docs/PRIVACY_POLICY.md) · [`docs/TERMS.md`](./docs/TERMS.md)

## Data sources and attribution

- **USDA FoodData Central**, Branded Foods — public domain. The size-history backbone.
- **Kroger Products API** — live store prices and sizes, shown with "Prices from Kroger".
- **Open Food Facts** — product name and image fallback, licensed ODbL.
- **Shoppers** — label photos contributed through the app.

## License

Code: all rights reserved (for now).
`data/trending.json`: CC-BY-4.0 — facts are facts; attribute the curation if you reuse it.
