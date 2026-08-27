# Shrunk — App Store Listing Copy (v2.0.0)

Copy-paste ready. Character counts are noted where Apple enforces a limit. Every price and feature line here must match `docs/superpowers/specs/2026-08-26-shrunk-v2-design.md` §2 and §3 — if they diverge, the spec wins.

---

## App Name (≤30 chars)

```
Shrunk: Shrinkflation Scanner
```
(29 chars)

## Subtitle (≤30 chars)

```
Catch shrinking groceries
```
(25 chars)

## Promotional Text (≤170 chars — editable any time without review)

```
Same price, less product? Scan any grocery barcode and Shrunk shows the real size history, today's shelf price, and what to buy instead. No brand pays us.
```
(154 chars)

## Keyword Field (≤100 chars, comma-separated, no spaces after commas)

```
shrinkflation,grocery savings,barcode scanner,price tracker,unit price,inflation,groceries,deals
```
(96 chars)

> Do not repeat words already in the App Name or Subtitle ("Shrunk", "scanner") — Apple indexes those automatically.

## Categories

**Shopping** (primary) · **Food & Drink** (secondary)

The job-to-be-done is a purchase decision at the shelf — comparison, alternatives, savings tracking — which is Shopping behaviour. Food & Drink is the natural secondary: the catalogue is grocery, and USDA FoodData Central is a food dataset.

---

## Full Description

```
They shrunk it. We caught them.

Shrinkflation is when a brand quietly shrinks the package — fewer chips, less coffee, a smaller bottle — while the price stays exactly the same. Shrunk shows you the receipt.

Point your camera at any grocery barcode. In seconds you get:

• Whether the package shrank, and by how much
• The size history behind that verdict, with dates
• Today's price and cost per ounce at your Kroger store
• Better value alternatives on the same shelf

WHERE THE DATA COMES FROM
Shrunk is built on the USDA's public FoodData Central dataset, which records package sizes for hundreds of thousands of US grocery products going back years — that's the "before". Live prices and current sizes come from Kroger's official Products API for the store you choose. Verified shrinkflation cases are curated by hand with a published source for every one. And shoppers add what no database has: snap a label, and Shrunk reads the net weight on your phone.

FREE, FOREVER
• Unlimited barcode scans
• Shrink verdict and size history
• Current price and cost per unit at your store
• The browse feed of verified cases
• Contribute label photos
• 3 alternatives per scan

SHRUNK PRO
• Watchlist alerts — a push the moment something you watch gets smaller, or its price per unit jumps 5%
• Weekly "what shrank this week" digest for your categories
• Unlimited ranked alternatives at your store, cheapest per unit first
• Full price and size history charts
• Savings dashboard built from what you actually scan — no invented numbers

$2.99/month or $14.99/year. New subscribers get a 7-day free trial on the yearly plan.

INDEPENDENT BY DESIGN
No brand pays us. No sponsors. No ads. No account, no login, no tracking. Our only job is to be on your side at the shelf.

Prices from Kroger. Size data from USDA FoodData Central. Product names and images from Open Food Facts (ODbL). Shrunk is not affiliated with any brand or retailer.

Stop paying more for less.
```

## Subscription disclosure (required by Apple for auto-renewables)

Apple requires the length, price and renewal terms, plus functional links to the terms and privacy policy, to be visible **in the app's description and on the paywall itself**. Paste this at the end of the App Store description, below the marketing copy:

```
Shrunk Pro is an auto-renewable subscription.

• Shrunk Pro Yearly — $14.99 per year, with a 7-day free trial for new subscribers
• Shrunk Pro Monthly — $2.99 per month

Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the current period ends. Any unused portion of a free trial is forfeited when you purchase a subscription. Manage your subscription or turn off auto-renew in iOS Settings → your name → Subscriptions after purchase.

Privacy Policy: https://stackcurious.com/shrunk/privacy
Terms of Service: https://stackcurious.com/shrunk/terms
```

The in-app paywall already shows plan length, price and both links (Phase 5, Task 8) — confirm on the device build before submitting, because a paywall missing them is a routine rejection.

---

## What's New (v2.0.0)

```
Shrunk v2 — every verdict now comes from real, dated observations.

• Real size history: hundreds of thousands of US products from the USDA's public FoodData Central dataset, plus verified cases and shopper contributions
• Live prices: pick your Kroger store and see today's price, cost per unit, and stock, right on the result screen
• Snap a label: Shrunk reads the net weight on your phone and adds it to a product's history
• Alternatives that are actually on the shelf at your store, ranked by price per unit
• Shrunk Pro is now a subscription — $2.99/month or $14.99/year with a 7-day free trial — and every Pro feature is backed by observed data: watchlist alerts, the weekly digest, unlimited alternatives, full history charts, and a savings dashboard computed from what you scan

The onboarding quiz and its guessed "yearly exposure" number are gone. We would rather show you one real number than five invented ones.
```

---

## URLs

- **Support URL:** https://stackcurious.com/shrunk/support
- **Marketing URL:** https://stackcurious.com/shrunk
- **Privacy Policy:** https://stackcurious.com/shrunk/privacy
- **Terms of Service (EULA field):** https://stackcurious.com/shrunk/terms

All four must resolve before submission — a 404 on the privacy URL is an automatic rejection.

---

## Screenshots

Required: 6.9" (1320×2868). The four files in `marketing/screenshots/` are **v1 and must not be reused** — they show the lifetime IAP, the removed quiz onboarding, and a Browse tab without live prices.

Capture six on a physical device running the 2.0.0 build, signed into a StoreKit sandbox account with Pro active, with a Cincinnati Kroger store selected:

| # | File | Screen | Why |
|---|---|---|---|
| 1 | `01_result_shrunk.png` | Result view for a curated product with a clear shrink verdict, size history chart and the live-price panel showing "Prices from Kroger" | The core promise, in one shot |
| 2 | `02_scan.png` | Scanner with the reticle over a real package | Shows the interaction |
| 3 | `03_live_price.png` | Result view scrolled to the live-price panel: regular/promo, cost per unit, stock, attribution | The v2 differentiator |
| 4 | `04_contribute.png` | Label capture confirm sheet with a parsed net weight | The growth loop, and it is free |
| 5 | `05_alerts.png` | Alerts feed with a `sizeDrop` and a `priceHike` entry | What Pro delivers |
| 6 | `06_paywall.png` | Paywall with yearly preselected, "Save 58%", the 7-day trial, and the terms/privacy links | Also the screenshot ASC asks for when reviewing the subscription |

Delete `01_browse.png`, `02_watchlist.png`, `03_settings.png` and `04_alerts.png` once the replacements exist, so nobody uploads the v1 set by mistake.
