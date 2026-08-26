# Shrunk — App Store Listing Copy

All fields below are copy-paste ready. Character counts are noted where Apple enforces a limit.

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
Same price, less product? Scan any grocery barcode and Shrunk tells you instantly if it shrunk — plus what to buy instead. Independent. No brand pays us.
```
(151 chars)

## Keyword Field (≤100 chars, comma-separated, no spaces after commas to save characters)

```
shrinkflation,grocery savings,barcode scanner,price tracker,grocery prices,inflation,deals,coupon
```
(97 chars)

> Note: do NOT repeat words already in the App Name/Subtitle ("Shrunk", "scanner") — Apple indexes those automatically. Keywords above are chosen to broaden discovery (inflation, deals, coupon) without wasting characters on duplicates.

## Primary Category

**Shopping** (primary) · **Food & Drink** (secondary)

**Justification:** The core job-to-be-done is a purchase decision at the shelf — "is this product still worth the price?" — which is squarely a Shopping behavior (comparison, alternatives, savings tracking). Food & Drink is the natural secondary because the catalog is grocery/food products sourced from Open Food Facts, capturing users who browse that category. Shopping has lower competitive density for a utility like this than Food & Drink, improving ranking odds.

---

## Full Description

```
They shrunk it. We caught them.

Shrinkflation is when brands quietly shrink a package — fewer chips, less coffee, smaller bottle — while the price stays exactly the same. Over the last five years, common grocery items have lost 5–18% of their size with no price drop. Most people never notice. Shrunk does.

Point your camera at any grocery barcode. In seconds, Shrunk tells you:

• Whether the product shrunk — and by how much
• The real price-per-unit change, so you see what you're actually paying
• Better-value alternatives you can buy instead

HOW IT WORKS
Shrunk reads the barcode, looks the product up in Open Food Facts — a nonprofit, community-maintained database of millions of products — and compares current size to historical size. You get a clear verdict: good value, watch out, or shrunk.

INDEPENDENT BY DESIGN
No brand pays us. No sponsors. No ads. No tracking. Our data comes from a nonprofit catalog, and our only job is to be on your side at the shelf.

FREE
• Unlimited barcode scans
• Shrink verdict and size history
• Top alternatives for any product

SHRUNK PRO — one-time $9.99, yours forever
• Watchlist: add any product and we check it daily
• Real-time alerts the moment something you watch shrinks
• Every ranked alternative, not just the top two
• Savings dashboard that tracks exactly what you've protected

Pro is a single one-time purchase. No subscription. No auto-renew. Pay once, keep it.

Stop paying more for less. Catch shrinkflation before it catches you.
```

---

## What's New (v1.0)

```
Welcome to Shrunk — the first release.

• Scan any grocery barcode and get an instant shrinkflation verdict
• See real price-per-unit changes and better-value alternatives
• Shrunk Pro: watch products, get real-time shrink alerts, and track your savings — one-time purchase, no subscription

They shrunk it. We caught them.
```

---

## URLs

- **Support URL:** https://stackcurious.com/shrunk/support
- **Marketing URL:** https://stackcurious.com/shrunk
- **Privacy Policy:** https://stackcurious.com/shrunk/privacy
- **Terms of Service:** https://stackcurious.com/shrunk/terms

---

## Screenshots

Captured at 1320×2868 (iPhone 6.9" / 17 Pro Max — the required largest size) in `marketing/screenshots/`:

1. `01_browse.png` — Browse: "Trending shrinks" + "Hall of shame" ranked offenders
2. `02_watchlist.png` — Watchlist Pro feature gate ("Watching is a Pro feature")
3. `03_settings.png` — Settings: plan, data sources, version, legal links
4. `04_alerts.png` — Alerts: "Real-time protection" Pro feature

Not captured (simulator limitations — see ASC_SETUP.md reviewer note): the live camera scan reticle, the post-scan verdict/result screen, the onboarding savings reveal, and the in-app paywall sheet all require real device interaction (camera + multi-tap flows the simulator's permission dialog blocks). Recommend re-capturing these four on a physical device before final submission, ideally with a Pro-unlocked StoreKit sandbox account so the paywall and dashboard render with data.
