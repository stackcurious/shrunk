# Shrunk — where we stopped (2026-08-28)

Read this first in a new session. Memory/ledgers may lag; this file and `git log` are the truth.

## Headline

**Shrunk 2.0.0 (build 4) is submitted to App Review** — review submission `bdce0306-43d6-4ee5-a243-ef81193a575d` (submitted 2026-08-28 14:42 UTC), containing the app version, the "Shrunk Pro" subscription group and both subscriptions (`com.shrunk.pro.yearly` $14.99 w/ 7-day trial, `com.shrunk.pro.monthly` $2.99). All four items `WAITING_FOR_REVIEW`. Release type: automatic after approval.

The same build (2.0.0 / 4, ASC build id `c12af38f-24e2-4360-9124-494f00e8125c`) is on TestFlight for the internal group "Shrunk Internal" (tester: oakley801@gmail.com — the only tester Apple ID; do not add others).

## What shipped since the first TestFlight build (2.0.0 / 2)

Spec for all of it: `docs/superpowers/specs/2026-08-27-scan-value-and-native-ui.md` (binding; §2 has the Result-screen state table, §3 the native-UI rules, and the rulings).

| Area | Change | Evidence |
|---|---|---|
| Result screen | Watch no longer a silent no-op; `WatchOutcome` (`needsLabel` → `paywall` → `watch` → `alreadyWatched`), toast+haptic on every branch; single-snapshot and no-size states are first-class; live Kroger size **and** price adopted when we have none (attribution follows) | `.wave1-report.md`, `.wave1-review.md`, `.wave1-rereview.md` |
| UI | Full native-HIG restyle (system type + Dynamic Type, semantic colours, inset-grouped lists, large titles, native buttons/sheets); custom `ShrunkTheme` reduced to brand/verdict tokens; dark mode + AX5 verified; share card/chart dark bugs fixed | `.restyle-a-report.md`, `.restyle-b-report.md`, `.whole-app-review.md`, `.ui-fix-round.md`, `.ui-fix-rereview.md` |
| Detector | Verdict compares the last two **size runs** (consecutive within-tolerance observations collapsed), not the last two observations — a confirming second source no longer flattens a shrink. Digest/sweep deliberately still use raw events (spec §5.1) | `.detector-runs-report.md` |
| Backend | On-miss lookup keeps FDC `packageWeight`/OFF `quantity` as an observation; zero-observation products backfilled (1 h guard); FDC `gtinUpc` query fixed (was ~90 % dead); feed clamp against implausible cross-source pairs; migration `0007` (adds `source='off'`) | `.backend-lookup-report.md`, `.backend-deploy-report.md` |
| Normalizer | Comma is an equivalence separator, mixed numbers parse, decimal pack counts rejected — all three implementations + `fixtures/package_weights.json`; 25 corrupted production rows corrected | `.normalizer-report.md` |
| Curated catalogue | **Was fabricated** (never-issued barcodes, 404 evidence URLs). Re-verified from real sources → **25 cases**, each with a loading source stating both sizes; hit-rate `found=25/25 with_history=25/25 shrink_detected=25/25`; production re-seeded; orphaned fabricated rows deleted (user-approved) | `.curated-audit-report.md`, `.curated-verify-report.md` |
| Screenshots | `ShrunkUITests` target + `-ui-testing` overrides (`Shrunk/Support/UITestingOverrides.swift`) drive six 1320×2868 shots (`marketing/screenshots/v2/`, dark set in `v2-dark/`); uploaded to ASC (set `f6a5cec3…`, all COMPLETE); paywall shot on both subscriptions | `.screenshots-report.md`, `.screens-asc-report.md` |
| ASC metadata | Version 2.0.0, subtitle, promo, keywords, description + subscription disclosure, support/marketing URLs, review contact + notes, categories Shopping / Food & Drink, age rating 4+, privacy published | `docs/ASC_SETUP.md`, `.submission-report.md` |
| Legal | Governing law is **Florida** (decided 2026-08-28) in `docs/TERMS.md` and the site | commit `b61eb0f` |

Tests at HEAD: 305 iOS unit + 6 UI (StoreKit daemon tests skipped — machine bug FB22237318), 387 Worker, 93 Python.

Worker: `https://shrunk-api.stackcurious.workers.dev` (last deploy `c03ffc3f-7780-40b2-8dae-1ea1436a8af3`). Secrets/keys: `~/.config/shrunk/`, `~/.appstoreconnect/private_keys/AuthKey_Q32YKM5PDY.p8`.

## Marketing site (separate repo `~/Projects/stackcurious`, Next.js on Vercel)

Rebuilt `/shrunk` as a conversion page + `/shrunk/shrinkflation` index + one page per verified case (25), Smart App Banner, JSON-LD, OG image, sitemap; privacy/terms/support match `docs/`. Commits `f887e45`, `6bd1fe3`, `e116224`, `a71bf63`, `72af365` on `main` — **NOT pushed**: another session has unpushed shiftcheck commits on the same branch and Vercel deploys on push. Push when that work is ready. App Store link used: `https://apps.apple.com/us/app/shrunk-shrinkflation-scanner/id6805856154` (404 until approved).

## Open items

User-only:
1. `privacy@stackcurious.com` must exist (published contact in privacy policy, terms, and ASC).
2. Rotate the Kroger client secret (it was pasted in chat) → `cd backend && npx wrangler secret put KROGER_CLIENT_SECRET`.
3. Push `stackcurious/main` (see above).
4. On-device acceptance run per `scripts/acceptance.md` (scans, first production push, sandbox purchase of yearly w/ trial) — not done; App Review may surface what it would have.
5. Kroger written-permission reply (Gmail thread `1a043dfa17862f3c`, sent 2026-08-27) — none yet; `KROGER_PERSIST=on` until then, `POST /v1/admin/purge-kroger` is the retraction.

Engineering, next:
- If App Review rejects: read the resolution-center message, fix, bump build, and resubmit **with the subscriptions in the same submission** (see lesson below).
- A build 5 would need: `CURRENT_PROJECT_VERSION` bump in `project.yml`, archive from a clean worktree (`.build3-report.md` has the exact xcodebuild/export commands), attach via `PATCH /v1/appStoreVersions/5f72dc64-…/relationships/build`.
- Optional value work: import archived FDC releases (2019–2025) for more "before" points; the digest/sweep run-collapse question in spec §5.1.
- Hygiene: `ProductThumb.swift`/`StatBox` were deleted; the `.claude/worktrees/agent-a13336e8bb2ff43b9` worktree is merged and harness-locked — safe to remove.

## Lessons that changed how we work (full list in `tasks/lessons.md`)

- Walk the *common* path (a random real barcode) before a TestFlight build; every button gives feedback.
- Never trust "verified" data you didn't verify — check barcodes against FDC/OFF/Kroger and load every source URL.
- ASC review submissions: add the first subscription group in the web UI **before** the version item, then submit; the API has no subscription item type and won't auto-bundle.
- Keep the controller (Fable) to supervision; Opus/Sonnet do the chores; no sub-agent fan-out; checkpoint long jobs.
- Commit by pathspec; never `git stash/checkout/reset` in a shared worktree; one xcodebuild at a time on this Mac.

## Useful ids

ASC app `6805856154` · version `5f72dc64-9424-49a8-80b9-b18eeca085ba` · en-US version localization `2f58cae6-32c0-4487-90d4-dff0ef374cd1` · app-info localization `e64717f5-ba99-4120-a020-5c1eabbeff84` · group `22339113` · yearly `6805856675` · monthly `6805858544` · internal beta group `6bd85663-ca17-4504-8f35-853ba5ddd10a` · team `X4VJ56X38V` · API key `Q32YKM5PDY` / issuer `83c8bc1a-4c4e-4dc4-b5a8-aeb2563a316c` · Kroger client id `shrunkshrinkflationscanner-bbchhd1m` · Cincinnati Kroger Hyde Park locationId `01400355`.
