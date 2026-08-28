# Shrunk — value on every scan, and a native iOS look

**Date:** 2026-08-27 · **Status:** binding for the fix waves that follow TestFlight build 2.0.0 (2) · **Parent spec:** `2026-08-26-shrunk-v2-design.md` (still authoritative for data, pricing, entitlements; this spec narrows the Result screen and the visual layer).

## 0. Why

TestFlight feedback on build 2: scanning a Gatorade bottle produced a product with **no size, no verdict and nothing to do**; "Watch this product" did **nothing** on the free trial; the UI "doesn't feel like an Apple app".

Measured on the production D1 (2026-08-27): 371,400 products, **5,601 (1.5 %) with a recorded size change**, 6 with no observation at all. Products found through the on-miss lookup (`GET /v1/product/{gtin}` → FDC API → Open Food Facts) get a name only — `packageWeight` / `quantity` are discarded (`backend/src/lookup/{fdc,off}.ts`). So the common case is *one* snapshot, and for a fresh on-miss product *zero*. The Result screen was designed for the 1.5 % case.

Root cause of the Watch bug: `ResultView.addToWatchlist` and `WatchlistService.add` both `guard record.currentSize != nil else { return }` — silent no-op with no feedback.

## 1. Product rules (binding)

1. **A scan never dead-ends.** Every loaded Result shows at least one concrete fact and one next action.
2. **The single-snapshot Result is a first-class screen**, not a degraded shrink screen. Its promise is *"here is what you're paying per ounce today, and we'll tell you the moment it shrinks."*
3. **Watching needs one observation, not two.** The observation becomes the baseline for `size_drop` alerts. Watching with zero observations is impossible → the button becomes the label-capture CTA.
4. **Every tap gives feedback** — success toast + `.success` haptic; failure toast + `.error` haptic; paywall when not Pro. No silent `return`s on user actions.
5. **Adopt the live size.** When the product has no observation and the live Kroger product parses a size, the app treats that size as the current size (labelled "at Kroger today", attribution kept). The Worker already persists it as an `observations` row (`source='kroger'`) when `KROGER_PERSIST=on`, so the next load is consistent.
6. **On-miss lookups keep the size.** FDC `packageWeight` (e.g. `"28 fl oz"`, `"12 oz"`, `"6 x 12 fl oz"`) and OFF `quantity` go through `backend/src/normalize.ts`; when they parse, the Worker writes an accepted `observations` row (`source='fdc'` or `'off'`, `observed_at` = FDC `publishedDate`/`modifiedDate` or OFF `last_modified_t`, else now). Unparseable → product row only (today's behaviour).

## 2. Result screen states

| State | Headline (system font, `.largeTitle`-class) | Body | Primary action | Secondary |
|---|---|---|---|---|
| Shrink (≥2 same-kind obs, −1 % or worse) | "Shrunk 12 %" | Then→Now, cost/oz then→now, live price, history chart | See alternatives | Watch · Share |
| Unchanged / grew | "Same size since 2021" / "Grew 6 %" | Now size, live price + cost/oz, chart | Watch (baseline) | Alternatives · Share |
| **Single snapshot** (1 obs, or 0 obs + live Kroger size) | "No shrink on record" | "‹size›, first seen ‹Mon YYYY›" (or "‹size› at Kroger today"); live price + **cost per oz**; alternatives ranked by cost/oz with "cheapest per oz at your store" callout | **Watch — we'll alert you if it shrinks** | Alternatives · Snap the label to confirm |
| **No size at all** | "We don't know this size yet" | name/brand; live price if any (no per-oz) | **Snap the label to start tracking** (opens `LabelCaptureView`) | Alternatives (category search) |
| Not found | "Not in our database yet" (existing) | — | Snap the label | — |

Since size runs landed (`ShrinkDetector` compares the last two *runs*, not the last two observations), the "Unchanged" half of row 2 is unreachable — a size that held collapses into one run and reports the single-snapshot state instead; the branch is kept in `ResultView.bannerSubline` for switch exhaustiveness and because the alert models still carry `.unchanged`. Share is gated by `ShareCardRenderer.canShare(record:)`, the same predicate `comparisonRow` uses, so the shared PNG can never draw a Then→Now the screen refused to.

Watch button semantics (`ResultViewModel.watchOutcome(record:isPro:) -> WatchOutcome` — pure, unit-tested):
- `.needsLabel` when there is no current size (button title "Snap the label to start tracking") — checked **before** the paywall: label capture is free and is the only action that can unblock watching, so a size-less product must never paywall (ruling 2026-08-27, wave 1)
- `.paywall` when `!isPro`
- `.watch` otherwise → `WatchlistService.add` (which now accepts a single observation) → toast "Watching ‹name› — we'll alert you if it shrinks or its price per oz jumps"; button becomes "On your watchlist" (disabled), as today.
- `.alreadyWatched` when `WatchlistService.fetch(barcode:)` returns a row → button starts in the watched state (today it forgets on re-open).

## 3. Native iOS visual layer (HIG)

Replace the custom "brutalist" theme with native SwiftUI idioms. Keep **brand red `#E24B4A` as the app tint** and the verdict colour semantics (red = shrink, amber = minor, green = unchanged/grew). Concretely:

- **Type:** system text styles only (`.largeTitle`, `.title2`, `.headline`, `.body`, `.subheadline`, `.caption`) with Dynamic Type; numerals use `.monospacedDigit()`, not a monospaced face. No `.tracking`, no all-caps section labels — use `Section` headers / `.headline`.
- **Colour:** semantic system colours (`Color(.systemBackground)`, `.secondarySystemGroupedBackground`, `.secondary`, `.tertiary`). Delete `paper/ink/mist/smoke`. Full dark-mode support falls out of this.
- **Structure:** `NavigationStack` with large titles on Browse, Watchlist, Alerts, Settings; `List` with `.insetGrouped` for settings/lists; `Form` for preferences; cards are `GroupBox`-style rounded rects on grouped background, not hand-drawn capsules.
- **Controls:** `.buttonStyle(.borderedProminent)` for the primary action, `.bordered` for secondary; `.controlSize(.large)`; toolbar buttons are plain SF Symbols (`xmark.circle.fill` for sheet close); toggles are `Toggle`.
- **Presentation:** Result stays a sheet with `.presentationDetents([.large])` + drag indicator; paywall is a sheet with `.medium/.large` detents; store picker is a `.searchable` list.
- **Tab bar:** standard `TabView` with SF Symbols; Scanner is the default tab; camera view keeps its dark chrome but the reticle/status text use system materials (`.ultraThinMaterial`) and `.headline` type.
- **Motion:** system transitions; haptics through `sensoryFeedback` (iOS 17+) where a `UINotificationFeedbackGenerator` exists today.
- **Paywall copy/prices unchanged** (Apple requires the disclosure block to stay).

Delete `Shrunk/Core/Theme/ShrunkTheme.swift` fonts/colours that are no longer referenced; `ShrunkButton`, `StatBox`, `ShrunkPageHeader`, `Toast` are re-implemented on native styles or removed.

## 4. Tests (prove-it)

- `ShrunkTests/ResultWatchOutcomeTests.swift`: `.needsLabel` for a record with no `currentSize` and Pro on; `.paywall` when not Pro; `.watch` for a single-observation record; `.alreadyWatched` when the barcode is on the watchlist.
- `ShrunkTests/WatchlistServiceTests.swift`: `add` succeeds with a single-observation record (`previousSize == nil`), storing that size as `lastKnownSize`.
- `ShrunkTests/ShrinkDetectorTests` (extend): a product with one observation yields `.insufficientData` **with** `currentSize` set; a product with no observation but a live size supplied yields `currentSize` from the live size.
- `backend/test/lookup.test.ts` (new): on-miss FDC with `packageWeight: "28 fl oz"` → an accepted observation of 828.06 ml volume; OFF `quantity: "500 g"` → 500 g mass; unparseable → no observation, product still created.

## 5. Out of scope

Importing archived FDC releases (2019–2025) for more "before" points; Kroger persistence policy; the onboarding quiz (removed). Screenshots and TestFlight build 3 follow once §2–§3 land.
