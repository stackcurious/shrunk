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

> The bundle ID `com.shrunk.app` must already exist as an App ID in the Apple Developer portal (Certificates, Identifiers & Profiles) under team **X4VJ56X38V**, with the **Push Notifications** capability enabled — the app registers for remote notifications and the Worker sends watchlist alerts and the weekly digest through APNs. The same portal holds the APNs auth key (`.p8`) the Worker signs with; see `docs/RELEASE_CHECKLIST.md`. The app also declares the `aps-environment` entitlement through `Shrunk/Shrunk.entitlements`, wired via `CODE_SIGN_ENTITLEMENTS` in `project.yml` — `development` for TestFlight, and the App Store build is re-signed to `production` automatically at distribution.

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
- **Still 4+ in v2, and the two questions that changed both stay "No".** Label photos are user-generated, but they are sent to a private review queue and are never shown to other users, so there is no in-app user-generated content to moderate; and the app's only tappable outbound links, all in Settings, are USDA FoodData Central (`fdc.nal.usda.gov`), "Prices from Kroger" (`www.kroger.com`), Open Food Facts (`world.openfoodfacts.org`), the privacy policy (`stackcurious.com/shrunk/privacy`), and the terms page (`stackcurious.com/shrunk/terms`) — all fixed, first-party-chosen URLs — plus a "Share Shrunk" row that opens the OS share sheet on a fixed `stackcurious.com/shrunk` link rather than loading a page. "Unrestricted Web Access" remains No.

---

## 4. App Privacy — Nutrition Label (ASC → app → App Privacy)

**This answer changed in v2.** v1 truthfully answered "no data collected" because the app had no backend. v2 talks to a first-party Cloudflare Worker and stores a device row, so the answer is now **Yes**, with everything marked *not linked to identity* and *not used for tracking*. The facts below come from `docs/PRIVACY_POLICY.md` — if that document changes, change these answers with it.

"Do you or your third-party partners collect data from this app?" → **Yes**.

| Data type (Apple's taxonomy) | What it is | Purpose | Linked to the user? | Used for tracking? |
|---|---|---|---|---|
| Identifiers → **Device ID** | A UUID the app generates at first launch, and the APNs push token | App Functionality | **No** | **No** |
| User Content → **Photos or Videos** | A label photo, uploaded to our server with every contribution; discarded immediately (never stored) if the reading is confident enough to auto-accept, or kept until a human reviews it, then deleted, if it is not | App Functionality | **No** | **No** |
| User Content → **Other User Content** | The net-weight reading parsed from a label | App Functionality | **No** | **No** |
| Purchases → **Purchase History** | After purchase, the app sends the App Store transaction JWS to `POST /v1/devices`; the Worker verifies Apple's signature and keeps `pro_until` and `app_account_token` (the same random device UUID), used solely to unlock Pro, plus `entitlement_updated_at` and `last_notification_uuid` (a timestamp and an id, used only to apply Apple's renewal notifications in order and never twice) — no product or price history is stored. The iOS StoreKit rewrite (phase-5 Tasks 6–8) wires this; the Task 0 gate re-verifies `StoreKitService.swift` before submission. | App Functionality | **No** | **No** |
| Other Data → **Other Data Types** | The Kroger store id you pick, your category choices and notification preferences, and your watchlist | App Functionality (and Product Personalization for categories) | **No** | **No** |

Answer **No** to tracking on every data type, and **No** to "Do you use data for tracking purposes?" — there is no advertising SDK, no analytics SDK, no ad identifier, and nothing is shared with data brokers. App Tracking Transparency is therefore not required and the app never shows the ATT prompt.

Not collected, and must stay unticked: Contact Info, Health & Fitness, Financial Info (Apple handles payment — we never see it), **Location** (the app asks for a *store*, never the device's location, and requests no location permission), Contacts, Search History, Browsing History, Sensitive Info, Diagnostics, Usage Data.

Supporting facts if a reviewer asks:

- **No account, no login.** There is no user identity to link anything to.
- **Scan history stays on the device** (`UserDefaults`) and is never uploaded.
- **Kroger-proxied requests** (`/v1/kroger/*`) carry the barcode/ZIP and store id, plus the same `X-Device-Id` header every API call carries (used for rate limiting) — never the push token.
- **Photos are transient.** They exist in R2 only while a submission is pending human review and are deleted on accept and on reject alike.

---

## 5. Permissions / Capabilities

These are declared in `Shrunk/Resources/Info.plist` — confirm they survive the build:

- `NSCameraUsageDescription` — "Shrunk uses your camera to scan product barcodes and, when you choose to contribute, to photograph a product label so we can read its net weight." Covers both the scanner and the label-capture flow.
- `UIBackgroundModes` — `fetch`, `processing` (the watchlist live-size check) and `remote-notification` (silent handling of alert pushes).
- `BGTaskSchedulerPermittedIdentifiers` — `com.shrunk.refresh-watchlist`.
- Push Notifications — remote alerts from the Worker (watchlist, digest, verified cases) plus local notifications.
- `NSAppTransportSecurity` → `NSAllowsLocalNetworking` — development only, so the app can talk to `wrangler dev` on `localhost:8787`. It permits **local** connections only, does not weaken ATS for any remote host, and needs no justification to review.

No HealthKit, no location, no contacts, no photo library, no microphone. The label-capture flow uses the camera, never the photo library, so `NSPhotoLibraryUsageDescription` is deliberately absent.

---

## 6. Build & Signing

- Team **X4VJ56X38V** (`project.yml` → `DEVELOPMENT_TEAM`, automatic signing).
- Marketing version **2.0.0**, build **2** — set by Task 10 in `project.yml`; `Info.plist` reads them through `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`.
- The Xcode project is generated: `xcodegen generate` before any archive. `Shrunk.xcodeproj` is not in git.
- Archive and upload with the commands in `docs/RELEASE_CHECKLIST.md` (`xcodebuild archive` → `-exportArchive` with `ExportOptions.plist` → `xcrun altool --upload-app`), or Xcode → Product → Archive → Distribute App.

---

## 7. Reviewer Note (paste into "App Review Information → Notes")

```
Shrunk has no account or login — open the app and start scanning immediately. Shrunk Pro is an auto-renewable subscription in the "Shrunk Pro" group: com.shrunk.pro.yearly ($14.99/year, with a 7-day free trial) and com.shrunk.pro.monthly ($2.99/month). Either one unlocks watchlist alerts, the weekly digest, unlimited ranked alternatives, full size and price history, and the savings dashboard; scanning, verdicts, size history and three alternatives are free forever. Use a StoreKit sandbox account to test. Product size history comes from the public USDA FoodData Central dataset and from shoppers' own label photos; live prices come from Kroger's official Products API and are shown with "Prices from Kroger" attribution.
```

---

## 8. Export compliance

`Shrunk/Resources/Info.plist` already declares:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

That is correct and means ASC will **not** ask the encryption questions on every build. Shrunk uses only HTTPS/TLS through the OS (App Transport Security) and Apple's own StoreKit and Vision frameworks; it implements no cryptography of its own and ships no custom encryption. That falls squarely inside the exemption for apps that merely use standard OS-provided encryption.

The Worker's App Store JWS verification runs **on the server**, not in the app, so it does not affect this answer.

If a build ever prompts for encryption answers anyway, the correct chain is: "Does your app use encryption?" → Yes → "Does it qualify for any of the exemptions?" → Yes, "only uses encryption available in iOS/macOS" → no CCATS or French declaration needed for a US-only release.

---

## Pre-submission checklist

App record
- [ ] App record exists with bundle id `com.shrunk.app`, team X4VJ56X38V, Push Notifications capability enabled
- [ ] Name, subtitle, promotional text, keywords, description **including the subscription disclosure**, and What's New pasted from `docs/APP_STORE_LISTING.md`
- [ ] Support, Marketing, Privacy Policy and EULA/Terms URLs set, and all four load in a browser
- [ ] Age rating completed → 4+

Subscriptions (details in §2)
- [ ] Subscription group `Shrunk Pro` created
- [ ] `com.shrunk.pro.yearly` ($14.99/yr, level 1) and `com.shrunk.pro.monthly` ($2.99/mo, level 2) created and submitted **with the build**
- [ ] 7-day Free Trial introductory offer on the yearly product only
- [ ] Paywall screenshot uploaded for subscription review
- [ ] App Store Server Notifications set to Version 2, both URLs pointing at `https://<worker>/v1/appstore/notifications`, and ASC's **Test Notification** returns 200

Privacy and compliance
- [ ] App Privacy re-answered per §4 — **"Yes, we collect data"**, five data types, all *not linked* and *not used for tracking*
- [ ] `ITSAppUsesNonExemptEncryption=false` present in the built Info.plist (§8)
- [ ] `https://stackcurious.com/shrunk/privacy` and `/terms` publish the current `docs/PRIVACY_POLICY.md` and `docs/TERMS.md`

Build
- [ ] Six 6.9" screenshots re-captured on a device from the 2.0.0 build (`docs/APP_STORE_LISTING.md`); the v1 set deleted
- [ ] Reviewer note pasted (§7)
- [ ] Version 2.0.0 (2) uploaded, processed, and attached to the release
- [ ] `scripts/acceptance.md` filled in and passing — 35/35 curated verdicts, ≥60% kitchen-scan history, ≥25/30 live prices
