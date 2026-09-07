# Shrunk — working notes for future sessions

Read `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` first. It is the binding design; the phase plans in `docs/superpowers/plans/` argue from it and record how each slice was built.

## Commands

| What | Command |
|---|---|
| iOS build | `xcodegen generate && xcodebuild build -scheme Shrunk -destination 'generic/platform=iOS Simulator' -quiet` |
| iOS tests | `xcodegen generate && xcodebuild test -scheme Shrunk -destination 'platform=iOS Simulator,name=BabSnap iPhone 17' -quiet` |
| Worker tests | `cd backend && npx vitest run` |
| Worker typecheck | `cd backend && npx tsc --noEmit` |
| Python tests | `cd scripts && python3 -m pytest tests -q` |
| Repo data check | `python3 scripts/check_repo_data.py` |
| Worker deploy | `cd backend && npx wrangler d1 migrations apply shrunk --remote && npx wrangler deploy` |

`BabSnap iPhone 17` is this machine's simulator; CI discovers one with `xcrun simctl list devices available`. Substitute whatever you have.

## Conventions

- **XcodeGen is the source of truth.** Edit `project.yml`, never `Shrunk.xcodeproj` (it is git-ignored). Run `xcodegen generate` after adding, removing or renaming any Swift file or target setting; a `cannot find 'X' in scope` error is almost always a missed regenerate.
- **Commit by pathspec.** `git add <explicit paths>` then `git commit -m "…" -- <the same paths>`. Never `git add -A`, never a bare `git commit` — concurrent agents share one index and a bare commit sweeps someone else's staged work (see `tasks/lessons.md`).
- **Never `git stash`, `checkout` or `reset`** in a shared worktree.
- **Worker tests stub `fetch` with `vi.stubGlobal("fetch", vi.fn(...))` plus `afterEach(() => vi.unstubAllGlobals())`.** `fetchMock` from `cloudflare:test` does not exist in this toolchain. D1 and KV bindings are real in tests; cron handlers are tested by calling `runAlertDrain` / `runWeeklyDigest` / `runKrogerSweep` directly with `env`.
- **One normalizer, three implementations.** `scripts/fdc/normalize.py`, `backend/src/normalize.ts` and `Shrunk/Features/Contribute/NetContentParser.swift` must agree on `fixtures/package_weights.json`. Add a case there first, then make all three pass it.
- **GTINs are 13-digit zero-padded** everywhere — storage, API, app.
- **Quantities are normalized** to grams / millilitres / count with `unit_kind ∈ {mass, volume, count}`. Never compare across kinds.
- **No secrets in the repo.** `wrangler secret put` for the Worker, `backend/.dev.vars` (git-ignored) for local dev, `~/keys/` for `.p8` files.
- **Curated catalogue lives in three places** — `data/trending.json` (canonical), `Shrunk/Resources/trending.json` (app offline fallback), `backend/src/data/trending.json` (bundled into `/v1/feed`). CI fails when they drift; re-sync with `cp` and `cd backend && npm run sync:trending`.

## Where things live

- **Where we stopped / handoff: `docs/STATUS.md`** (read first in a new session)
- Spec: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`; post-TestFlight fixes + native UI: `docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md`
- Phase plans (1 = week1-data-backbone, then phase2…phase6): `docs/superpowers/plans/`
- Execution ledgers from subagent-driven runs: `.superpowers/sdd/<plan-name>/progress.md` (git-ignored, scratch)
- Corrections worth not repeating: `tasks/lessons.md`
- Release runbook: `docs/RELEASE_CHECKLIST.md`; acceptance run: `scripts/acceptance.md`

## Gone, and mid-removal — check before trusting either

`OpenFoodFactsService` and `UPCItemDBService` are actually gone (Phase 3, commit `29f986a`). Do not reintroduce them.

The spec (§1, §3) also marks `SavingsForecast`, the 10-screen quiz onboarding and its "$/yr exposure" reveal, and the `com.shrunk.pro.lifetime` non-consumable **Removed**. `SavingsForecast` and the quiz onboarding are gone as of Task 9 — `Shrunk/Services/SavingsForecast.swift` is deleted and `Shrunk/Features/Onboarding/{OnboardingContainerView,OnboardingViewModel}.swift` now implement the four-step welcome/categories/store/paywall flow — and `com.shrunk.pro.lifetime` is gone from both `Shrunk/Services/StoreKitService.swift` (replaced by `ShrunkProProduct.monthly`/`.yearly`) and `Shrunk/Resources/Shrunk.storekit` as of Task 7. Phase 5 (`docs/superpowers/plans/2026-08-26-shrunk-v2-phase5-subscription-onboarding-dashboard.md`) is what replaces them with `pro.monthly` / `pro.yearly` and the new onboarding.

## Site

The marketing mini-site lives in `site/` — its own Next.js app and its own
Vercel project (`shrunk`, production domain `https://shrunk-alpha.vercel.app`).
It was moved out of the shared hub `~/Projects/stackcurious/app/shrunk/`.

- Build: `cd site && npm run build`
- Deploy: `cd site && npm run deploy`

Public URLs are unchanged: the pages are served at
`https://stackcurious.com/shrunk` and `/shrunk/*` through multi-zone rewrites in
`~/Projects/stackcurious/next.config.ts`, which forward the whole prefix — pages,
static chunks and the OG image — to the deployment above. Never link to the
`*.vercel.app` domain in the app, App Store Connect or docs.

`next.config.ts` sets `basePath: "/shrunk"`, which is what makes the two halves
line up. Consequences when editing pages:

- `next/link` hrefs are auto-prefixed → write them basePath-relative (`/privacy`,
  `/shrinkflation/<slug>`).
- `next/image` `src` and `metadata.icons` are **not** prefixed → write those out
  as `/shrunk/...` with the file at `site/public/<name>`.
- Plain `<a href>` is never prefixed, so a link leaving the zone (the "Stack
  Curious, LLC" attribution) is written absolute.
- `metadataBase` is `https://stackcurious.com/shrunk`, basePath included: Next
  joins that pathname onto relative metadata URLs, so an OG image override is
  written `/opengraph-image`, not `/shrunk/opengraph-image`.

`site/app/_lib/cases.ts` still carries the copy of `data/trending.json` — the
same "curated catalogue lives in three places" sync rule applies, by hand.
