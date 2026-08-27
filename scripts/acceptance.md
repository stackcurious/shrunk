# Shrunk — acceptance run (spec §10)

Run this on the TestFlight build, on a real iPhone, before submitting. Fill in the tables; the filled file is the evidence, and `docs/ASC_SETUP.md`'s pre-submission checklist refuses to pass without it.

**Build:** 2.0.0 (____) · **Date:** ____ · **Device:** ____ · **Store:** Kroger ____ (Cincinnati), locationId ____ · **API:** ____

---

## A. 35/35 curated verdicts — scripted

```
python3 scripts/hit_rate.py --api "$API" --curated data/trending.json | tee scripts/out/acceptance-hitrate.txt
```

**Pass:** `with_history=35/35` (a verdict needs two same-kind observations) **and** `shrink_detected=35/35` (every curated entry is a documented shrink, so anything else is a data bug).

Summary line: `____________________________________________`

| Failure | Barcode | What the observations looked like | Fix |
|---|---|---|---|
| | | | |

Then spot-check three by scanning them on the device, to prove the app agrees with the script: one food item, one non-food item (paper or cleaning), one with a live Kroger price.

| Product | Verdict on device | Matches the script? |
|---|---|---|
| | | |
| | | |
| | | |

---

## B. 30-item kitchen scan — history for ≥60% of food items

Pick 30 real items off your own shelves. Aim for the mix a shopper actually has: roughly two-thirds food, the rest paper, cleaning and personal care. Scan each one and record what the result screen shows.

**Pass:** of the **food** items, at least 60% show a size history (two or more observations, i.e. a real verdict rather than "Not enough history yet").

| # | Product | Food? | History points | Verdict shown | Live price shown | Notes |
|---|---|---|---|---|---|---|
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | | | |
| 6 | | | | | | |
| 7 | | | | | | |
| 8 | | | | | | |
| 9 | | | | | | |
| 10 | | | | | | |
| 11 | | | | | | |
| 12 | | | | | | |
| 13 | | | | | | |
| 14 | | | | | | |
| 15 | | | | | | |
| 16 | | | | | | |
| 17 | | | | | | |
| 18 | | | | | | |
| 19 | | | | | | |
| 20 | | | | | | |
| 21 | | | | | | |
| 22 | | | | | | |
| 23 | | | | | | |
| 24 | | | | | | |
| 25 | | | | | | |
| 26 | | | | | | |
| 27 | | | | | | |
| 28 | | | | | | |
| 29 | | | | | | |
| 30 | | | | | | |

Food items: ____ · With history: ____ · **Rate: ____%** (needs ≥60%)

For every food item with no history, contribute a label photo from the result screen. That is the growth loop working, and it should turn "not enough history yet" into a second observation on the spot.

---

## C. Live prices at a Cincinnati Kroger — ≥25 of the 30

With the store set (Settings → Store, or onboarding), the live-price panel must show a price for at least 25 of the same 30 items.

**Pass:** ____ / 30 items show a regular or promo price, and every one of them displays **"Prices from Kroger"**.

| Miss | Product | What the panel said |
|---|---|---|
| | | |

Spot-check the arithmetic on three: compare the app's cost-per-unit against the shelf tag's unit price. They will not match to the cent (Kroger's per-unit estimate is its own), but the order of magnitude and the unit must be right.

| Product | App cost/unit | Shelf tag | Same unit? |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

---

## D. Subscription and push, end to end

- [ ] Paywall shows yearly preselected with "Save 58%", the 7-day trial (yearly plan only — the monthly plan shows no trial), and working Terms and Privacy links
- [ ] Sandbox purchase of the yearly plan unlocks Pro, and `SELECT id, pro_until FROM devices WHERE pro_until IS NOT NULL` shows a future timestamp — the only check that exercises a genuinely Apple-signed JWS
- [ ] `POST /v1/admin/verified-case` for a watched brand delivers a push within five minutes; tapping it opens the product
- [ ] A non-Pro device receives nothing
- [ ] Turning "Weekly digest" off in Settings writes `prefs.digest=false` on the device row

---

## E. Degradation (spec §8)

Airplane mode, two cases — do not conflate them, they exercise different code paths:

- [ ] **A previously scanned product** (already in this device's cache — scan it once with network on, then re-scan in airplane mode): the result screen shows the **cached last result** for that barcode — verdict, size history and price as last fetched — not an error, and never a stale spinner.
- [ ] **A barcode never scanned on this device before** (in airplane mode): the result screen shows the exact copy `Couldn't reach Shrunk — check connection.` — not iOS's generic "The Internet connection appears to be offline." or any other network-error string — and there is no fallback to Open Food Facts or any other on-device data source.
- [ ] With `KROGER_PERSIST="off"` deployed: the live panel says "Store prices unavailable right now", the verdict and history still render, alternatives fall back to curated cases
- [ ] An unknown barcode offers the contribution flow

---

## Result

- [ ] A: 35/35 · [ ] B: ≥60% · [ ] C: ≥25/30 · [ ] D · [ ] E

**Signed off:** ____ on ____
