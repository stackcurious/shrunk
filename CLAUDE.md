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

- Spec: `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md`
- Phase plans (1 = week1-data-backbone, then phase2…phase6): `docs/superpowers/plans/`
- Execution ledgers from subagent-driven runs: `.superpowers/sdd/<plan-name>/progress.md` (git-ignored, scratch)
- Corrections worth not repeating: `tasks/lessons.md`
- Release runbook: `docs/RELEASE_CHECKLIST.md`; acceptance run: `scripts/acceptance.md`

## Gone, and mid-removal — check before trusting either

`OpenFoodFactsService` and `UPCItemDBService` are actually gone (Phase 3, commit `29f986a`). Do not reintroduce them.

The spec (§1, §3) also marks `SavingsForecast`, the 10-screen quiz onboarding and its "$/yr exposure" reveal, and the `com.shrunk.pro.lifetime` non-consumable **Removed** — but as of this writing they are still in the tree: `Shrunk/Services/SavingsForecast.swift`, `Shrunk/Features/Onboarding/{OnboardingContainerView,OnboardingViewModel}.swift`, and `com.shrunk.pro.lifetime` in both `Shrunk/Services/StoreKitService.swift` and `Shrunk/Resources/Shrunk.storekit` all still exist. Phase 5 (`docs/superpowers/plans/2026-08-26-shrunk-v2-phase5-subscription-onboarding-dashboard.md`) is what replaces them with `pro.monthly` / `pro.yearly` and the new onboarding. Grep `StoreKitService.swift` for `pro.lifetime` before assuming Phase 5 has landed, and don't describe these as removed — or write UI docs against the new onboarding — until it has.
