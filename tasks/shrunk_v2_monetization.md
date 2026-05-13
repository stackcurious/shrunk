# Shrunk v2 — Monetization + Onboarding

## Decisions locked
- **Pricing**: single non-consumable IAP, `com.shrunk.pro.lifetime`, **$9.99 USD**. No free trial. No subscription. "Pay once, yours forever."
- **Onboarding**: 10 screens, ~90s, Cal AI quiz arc adapted for shrinkflation.
- **Reveal**: personalized $/year exposure number computed from household × spend × category mix.
- **Free vs Pro split**: unchanged (free = scan + verdict + 3 alternatives; Pro = watchlist alerts + unlimited alternatives + savings dashboard).

## Onboarding sequence

| # | Screen | Purpose | Data captured |
|---|---|---|---|
| 1 | Hero | Demo + brand hook | — |
| 2 | Problem | Frame the enemy, build urgency | — |
| 3 | Q1 household | First commitment, cheap | `householdSize: 1/2/3-4/5+` |
| 4 | Q2 frequency | Continue commitment | `shopFrequency: weekly/biweekly/monthly` |
| 5 | Q3 categories | Tailors reveal copy | `categories: Set<BrowseCategory>` |
| 6 | Q4 spend | Anchor the math | `monthlySpend: Double` (slider $150–$1500) |
| 7 | Social proof | Authority, trust | — |
| 8 | Analyzing… | Labor illusion (3s) | — |
| 9 | Reveal | Personalized $/yr + per-cat breakdown | — |
| 10 | Paywall | $9.99 lifetime CTA | (purchase) |

Permissions (camera, notifications) are deferred to first-need contextual prompts — Cal AI does this, Yuka does this, and it's the modern best practice.

## Savings forecast math

```
annualSpend  = monthlySpend × 12
basketShare  = Σ categoryBasketShare for selected categories
exposurePct  = weighted average of categoryShrinkRate × categoryBasketShare
              ────────────────────────────────────────────────────────
              Σ categoryBasketShare

annualExposure = annualSpend × basketShare × exposurePct
```

Category constants (defensible defaults, sourced from curated catalog + USDA basket weights):

| Category | basketShare | shrinkRate |
|---|---|---|
| Snacks | 0.12 | 0.09 |
| Drinks | 0.15 | 0.12 |
| Dairy | 0.15 | 0.06 |
| Cleaning | 0.05 | 0.08 |
| Personal | 0.08 | 0.075 |
| Paper | 0.05 | 0.085 |

Worked example: $800/mo, all 6 categories selected →
- annualSpend = $9,600
- basketShare = 0.60
- weighted exposurePct = 0.087
- annualExposure ≈ **$501/yr**

For paywall: `daysToPayBack = 365 × 9.99 / annualExposure` → at $501/yr exposure, 7.3 days. We round-floor to "Pays for itself in 8 days."

## Files

### New
- `Shrunk/Models/OnboardingProfile.swift` — Codable, @AppStorage-persisted answers
- `Shrunk/Services/SavingsForecast.swift` — pure-function calculator
- `Shrunk/Resources/Shrunk.storekit` — StoreKit Test config

### Replace
- `Shrunk/Features/Onboarding/OnboardingViewModel.swift` — 10-step state, answer collection
- `Shrunk/Features/Onboarding/OnboardingContainerView.swift` — 10 screens + chrome
- `Shrunk/Services/StoreKitService.swift` — non-consumable, single product
- `Shrunk/Features/Settings/ProPaywallView.swift` — one-tier $9.99 + payback anchor

### Edit
- `Shrunk/Features/Watchlist/WatchlistView.swift` — CTA copy
- `Shrunk/Features/Alerts/AlertsFeedView.swift` — CTA copy
- `Shrunk/Features/Settings/SettingsView.swift` — CTA copy + account card subline
- `project.yml` — add `.storekit` to resources, wire scheme

## Verification
- xcodegen → xcodebuild succeeds (warnings-as-errors off, fine)
- Wipe simulator data → launch → walk 10 screens → reach paywall
- Tap "Unlock $9.99" → StoreKit Test purchase → returns to app with `isProUser = true`
- Verify Watchlist + Alerts no longer gate Pro
- Screenshots: each onboarding screen + reveal + paywall + post-purchase state
