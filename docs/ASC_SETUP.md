# App Store Connect — Setup Sheet

Copy-paste checklist for creating the Shrunk record in App Store Connect (ASC). Work top to bottom.

---

## 1. App Record (App Store Connect → Apps → New App)

| Field | Value |
|---|---|
| Platform | iOS |
| Name | `Shrunk: Shrinkflation Scanner` |
| Primary language | English (U.S.) |
| Bundle ID | `com.shrunk.app` |
| SKU | `shrunk-ios-001` (any internal string; not user-visible) |
| User Access | Full Access |

> The bundle ID `com.shrunk.app` must already exist as an App ID in the Apple Developer portal (Certificates, Identifiers & Profiles) under team **X4VJ56X38V**. If it doesn't, create it there first with Push Notifications capability enabled (the app schedules local + background notifications).

---

## 2. In-App Purchase (ASC → app → Monetization → In-App Purchases)

| Field | Value |
|---|---|
| Type | **Non-Consumable** |
| Reference Name | `Shrunk Pro Lifetime` |
| Product ID | `com.shrunk.pro.lifetime` |
| Price | **$9.99** (Tier 10 / equivalent — set via Apple's price matrix) |
| Display Name | `Shrunk Pro` |
| Description | `Unlock the watchlist, real-time shrink alerts, every ranked alternative, and the savings dashboard. One-time purchase — yours forever.` |

- Add a localized display name/description for at least English (U.S.).
- Upload a screenshot of the paywall for IAP review (capture on a real device — see reviewer note).
- The product ID **must** match `com.shrunk.pro.lifetime` exactly — it is hard-coded in `Shrunk.storekit` and the StoreKit service.

---

## 3. Age Rating (ASC → app → General → Age Rating)

Answer **None** to every content question. Shrunk has no objectionable content, no user-generated content, no web browsing, no gambling.

- **Expected result: 4+.**
- No "Unrestricted Web Access" — the only web links are fixed, first-party URLs (privacy/terms/Open Food Facts).

---

## 4. App Privacy — Nutrition Label (ASC → app → App Privacy)

Shrunk collects **no personal data**. There is no account, no login, no analytics SDK, no ad SDK, and no tracking.

When prompted "Do you or your third-party partners collect data from this app?":

→ Answer: **No, we do not collect data from this app.**

Supporting facts for the questionnaire / review notes:

- **No account / no login.** The app has no sign-in. There is no user identity.
- **Product lookups** go to the **Open Food Facts** public API (`world.openfoodfacts.org`) using only the scanned barcode number. No personal identifier, device ID, or account is attached to those requests. Barcodes are product identifiers, not personal data.
- **Trending feed** is a static JSON fetched from a public CDN (jsDelivr). No data is sent to it — it is a one-way download.
- **Watchlist, alerts, scan history, onboarding answers** are stored **locally on device only** (SwiftData + UserDefaults). Nothing is uploaded to any server we control — we operate no backend.
- **No tracking** as Apple defines it: no data is used to track the user across other apps/websites, and there is no advertising. Answer **No** to the App Tracking Transparency / tracking questions.
- **Purchases** are handled entirely by Apple via StoreKit 2; we receive no payment data.

If ASC insists on listing any data type, the only candidate is "Purchases / Purchase History," which is handled by Apple, not collected by us — but the correct top-level answer remains **no data collected**.

---

## 5. Permissions / Capabilities

These are declared in `Shrunk/Resources/Info.plist` — confirm they survive the build:

- `NSCameraUsageDescription` — "Shrunk uses your camera to scan product barcodes. Nothing is recorded or stored." (Camera is the core scan feature.)
- `UIBackgroundModes` + `BGTaskSchedulerPermittedIdentifiers` — for the Pro daily watchlist sweep.
- Local notifications — for shrink alerts.

No HealthKit, location, contacts, photos, or microphone usage.

---

## 6. Build & Signing

- Team: **X4VJ56X38V** (set in `project.yml` → `DEVELOPMENT_TEAM`, automatic signing).
- Archive with a Distribution provisioning profile for `com.shrunk.app`, upload via Xcode Organizer or `xcodebuild -exportArchive`.
- Marketing version `1.0.0`, build `1` (from `project.yml`).

---

## 7. Reviewer Note (paste into "App Review Information → Notes")

```
Shrunk has no account or login — open the app and start scanning immediately. To test Shrunk Pro (in-app purchase com.shrunk.pro.lifetime, $9.99 non-consumable), use a StoreKit sandbox account; Pro unlocks the watchlist, alerts, full alternatives, and savings dashboard. Product data comes from the public Open Food Facts API using only the scanned barcode — no personal data is collected and there is no tracking.
```

---

## Pre-submission checklist

- [ ] App record created with bundle id `com.shrunk.app`
- [ ] IAP `com.shrunk.pro.lifetime` created (Non-Consumable, $9.99, "Shrunk Pro"), submitted with the build
- [ ] Age rating completed → 4+
- [ ] App Privacy → "No data collected", no tracking
- [ ] 6.9" screenshots uploaded (see `marketing/screenshots/` + re-capture device shots noted below)
- [ ] Promotional text, description, keywords, support/marketing URLs filled from `APP_STORE_LISTING.md`
- [ ] Privacy Policy URL set to `https://stackcurious.com/shrunk/privacy`
- [ ] Reviewer note pasted
- [ ] Build 1.0.0 (1) uploaded and attached
```
```
