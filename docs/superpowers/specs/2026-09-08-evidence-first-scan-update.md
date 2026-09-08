# Evidence-first scan update

## Product goal

Shrunk should answer three separate questions after a scan: whether the package became smaller, what evidence supports that statement, and what the shopper can do next. The interface must remain useful when only one dated size is known.

## Result states

- **Documented downsizing:** show the percentage and dated before/after sizes, name the evidence source, report unit-price movement only when a historical price belongs to the earlier-size date, and lead to alternative comparison.
- **Baseline established:** explain that one dated size is on record and lead to Watch.
- **No documented change / package grew:** state that result plainly and lead to Watch.
- **No size evidence:** ask for a label photo; keep the observation pending for human label review.

The live store price is authoritative for current unit price. Historical price is eligible only when its observation is within seven days of the earlier size record. Mass uses cost per ounce, volume uses cost per fluid ounce, and count uses cost per item.

## Flow decisions

- Scanner offers camera and manual entry at the same level. Both paths canonicalize supported UPC/EAN forms and validate the GS1 check digit.
- Onboarding is Welcome → Categories → Store → Scan. Purchase follows demonstrated value.
- A Watch tap by a free user opens Pro and resumes the Watch action after purchase.
- Notification permission is contextual: ask after the first successful Watch action, never merely for opening Watchlist.
- Result keeps one context-specific primary action pinned above the home indicator.

## Evidence integrity

Plausibility scoring alone cannot publish a crowd claim. Plausibility scores sort the review queue but never publish a crowd claim. Every crowd submission remains pending until a human verifies its stored label photo; no pending row can emit an alert.

## Validation

- Generic iOS Simulator build
- Focused detector, Result, Browse, Scanner, onboarding, Watch, and notification tests
- Result and Scanner UI screenshot tests on the 6.9-inch simulator
- Worker TypeScript validation and full Worker suite

## Identity

The Scanned Delta mark uses scan corners around descending barcode bars. The App Store icon is a flat coral-and-warm-white master with no baked mask. The static launch screen uses the same centered mark on the coral field, with no text or animation.
