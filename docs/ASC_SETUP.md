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

## 2. Subscriptions (ASC → app → Monetization → Subscriptions)

Create **one subscription group**, then two subscriptions inside it. The product IDs must match `Shrunk/Resources/Shrunk.storekit` and `ShrunkProProduct` in `Shrunk/Services/StoreKitService.swift` character for character.

| Field | Value |
|---|---|
| Subscription Group Reference Name | `Shrunk Pro` |
| Group Localization (en-US) — Display Name | `Shrunk Pro` |
| App Name in group localization | `Shrunk` |

### 2a. Yearly (create this one first — it is the preselected plan)

| Field | Value |
|---|---|
| Reference Name | `Shrunk Pro Yearly` |
| Product ID | `com.shrunk.pro.yearly` |
| Subscription Duration | **1 Year** |
| Price | **$14.99** (United States; let ASC generate the other storefronts) |
| Subscription Level (rank in group) | **1** |
| Display Name (en-US) | `Shrunk Pro Yearly` |
| Description (en-US) | `Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.` |

### 2b. Monthly

| Field | Value |
|---|---|
| Reference Name | `Shrunk Pro Monthly` |
| Product ID | `com.shrunk.pro.monthly` |
| Subscription Duration | **1 Month** |
| Price | **$2.99** (United States) |
| Subscription Level (rank in group) | **2** |
| Display Name (en-US) | `Shrunk Pro Monthly` |
| Description (en-US) | `Watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and your savings dashboard.` |

Level 1 for yearly and level 2 for monthly makes monthly → yearly an upgrade and yearly → monthly a downgrade, which is what the paywall's "Save 58%" implies.

### 2c. Introductory Offer — 7-day free trial (yearly only)

On `com.shrunk.pro.yearly` → **Introductory Offers → Create Introductory Offer**:

| Field | Value |
|---|---|
| Countries or Regions | United States |
| Start Date | today |
| End Date | **No End Date** |
| Type | **Free Trial** |
| Duration | **1 Week** |

Do **not** add an introductory offer to the monthly product — the app's paywall shows the trial only on the yearly plan and `StoreKitConfigurationTests` asserts monthly has none.

### 2d. App Store Server Notifications V2

ASC → app → **General → App Information → App Store Server Notifications**:

| Field | Value |
|---|---|
| Version | **Version 2** |
| Production Server URL | `https://<worker>/v1/appstore/notifications` |
| Sandbox Server URL | `https://<worker>/v1/appstore/notifications` |

Replace `<worker>` with the origin printed by `wrangler deploy` (for example `shrunk-api.stackcurious.workers.dev`). The endpoint verifies Apple's signature against a pinned copy of Apple Root CA - G3, needs no shared secret, and answers `401 {"error":"invalid_signature"}` to anything it cannot verify — which is what ASC's **Test Notification** button will surface if the URL is wrong.

- Upload a screenshot of the paywall for review (capture on a real device).
- The removed `com.shrunk.pro.lifetime` non-consumable has no purchases; delete it in ASC if it was ever created, or leave it marked "Removed from Sale". The app no longer references it.

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
Shrunk has no account or login — open the app and start scanning immediately. Shrunk Pro is an auto-renewable subscription in the "Shrunk Pro" group: com.shrunk.pro.yearly ($14.99/year, with a 7-day free trial) and com.shrunk.pro.monthly ($2.99/month). Either one unlocks watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and the savings dashboard; scanning, verdicts, size history and three alternatives are free forever. Use a StoreKit sandbox account to test. Product size history comes from the public USDA FoodData Central dataset and from shoppers' own label photos; live prices come from Kroger's official Products API and are shown with "Prices from Kroger" attribution.
```

---

## Pre-submission checklist

- [ ] App record created with bundle id `com.shrunk.app`
- [ ] Subscription group `Shrunk Pro` created
- [ ] `com.shrunk.pro.yearly` ($14.99/yr, level 1) and `com.shrunk.pro.monthly` ($2.99/mo, level 2) created and submitted with the build
- [ ] 7-day Free Trial introductory offer added to the yearly product only
- [ ] App Store Server Notifications set to Version 2, both URLs pointing at `https://<worker>/v1/appstore/notifications`, and ASC's Test Notification returns 200
- [ ] Age rating completed → 4+
- [ ] App Privacy re-answered before submission — the app now talks to a first-party Cloudflare Worker and stores a device UUID, an APNs token, a store id, and category preferences server-side. The "we operate no backend" wording in §4 is stale as of Phase 5 and must be rewritten in week 6.
- [ ] 6.9" screenshots uploaded (see `marketing/screenshots/` + re-capture device shots noted below)
- [ ] Promotional text, description, keywords, support/marketing URLs filled from `APP_STORE_LISTING.md`
- [ ] Privacy Policy URL set to `https://stackcurious.com/shrunk/privacy`
- [ ] Reviewer note pasted
- [ ] Build 1.0.0 (1) uploaded and attached
```
```
