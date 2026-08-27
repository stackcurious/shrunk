# Shrunk — Privacy Policy

**Last updated: 2026-08-26**

Publish this document at `https://stackcurious.com/shrunk/privacy`. The app links to that exact URL from Settings and from the subscription paywall, and App Store Connect points at it too.

## The short version

Shrunk has no accounts and no logins. We do not sell your data, we run no ads, we use no analytics or advertising SDKs, and we do not track you across other apps or websites. We store the minimum needed to look up a product, alert you about something you asked us to watch, and honour a subscription you bought from Apple.

## What Shrunk stores

| What | When it is stored | Where | How long |
|---|---|---|---|
| The barcode you scanned (a 13-digit product number) | Every scan | Sent to our API to look the product up. Not stored as a record of your scanning. | Not retained |
| A random device id (a UUID generated on your phone at first launch) | First launch | On your device, and in a `devices` row in our database | Until you ask us to delete it |
| Your Apple push token | Only if you allow notifications | Same `devices` row | Until you turn notifications off or ask us to delete it |
| The Kroger store you picked (a store id, not your location) | When you pick a store | On your device and in the `devices` row | Until you change or clear it |
| Your category and notification preferences | Onboarding and Settings | On your device and in the `devices` row | Until you change them |
| Your watchlist (product barcodes and brands) | When you add a product | On your device and in a `watches` row | Until you remove the item |
| A label photo you choose to contribute | Uploaded to our server with every contribution | Held only in memory unless the reading needs a human check, in which case it is written to Cloudflare R2 | **Discarded immediately** (never stored) if accepted automatically; otherwise **deleted the moment it is reviewed**, accepted or rejected |
| Your submission record (the barcode, the size you reported, the label text Shrunk read, your device id, and whether it was accepted) | When you contribute | In a `submissions` row in our database | Until you ask us to delete it |
| The net weight read from a label | When you contribute | Stored as product data (`observations`) | Kept as part of the product's size history |
| Your subscription status | After a purchase or restore | Apple's signed transaction is verified and reduced to an expiry date in the `devices` row | Until it expires or you ask us to delete it |
| Your recent scans | Every scan | **On your device only** (`UserDefaults`), never uploaded | Until you tap "Clear scan history" or delete the app |

**Shrunk never collects:** your name, email address, postal address, phone number, precise location, contacts, photo library, health data, payment details, or any advertising identifier. There is no advertising SDK and no analytics SDK in the app.

## Label photos

Contributing a photo is optional and free. On your phone, Shrunk reads the label with Apple's on-device Vision framework to make an initial read. When you submit, the photo is uploaded to our server along with that reading, **every time** — not only when the reading is unclear. If the reading is confident (a clear net-weight line that agrees with what we already know about the product), the submission is accepted automatically and the photo is **discarded immediately and never stored**. If it is not confident, the photo is written to storage so a human can check it, and it is deleted as soon as that check happens, whether the submission is accepted or rejected. The number that survives review becomes part of the product's public size history and is not attributed to you.

## Notifications

If you allow notifications, Apple issues a push token for this install and we store it so watchlist alerts and the weekly digest can reach you. Turning notifications off in iOS Settings stops delivery; asking us to delete your device row removes the token.

## Purchases

Shrunk Pro is an auto-renewable subscription sold by Apple. Apple handles payment; we never see your card, your Apple Account, or your billing details. Our server receives Apple's cryptographically signed transaction, verifies it, and stores only an expiry date plus the random purchase token the app generated, so your subscription survives a reinstall.

## Who else sees this data

- **Cloudflare** — hosts our API, database, photo storage and cache (United States).
- **Apple** — delivers push notifications and processes subscriptions.
- **Kroger** — when you have a store selected, we ask Kroger's Products API for that store's price and size for the barcode you scanned; we send the barcode and the store id. To find stores near you, we send the ZIP code you type to Kroger's Locations API. To find alternatives, we send the product's category as a search term to Kroger's Products API. Neither the ZIP code nor the category is stored by us, and **we never send your device id, push token, or anything else about you.**
- **USDA FoodData Central** and **Open Food Facts** — queried by barcode when a product is new to us, to fill in a name and image.

Nobody else. We do not sell, rent or share data with advertisers, data brokers or analytics companies.

## Data sources and attribution

- **U.S. Department of Agriculture, FoodData Central** — Branded Foods package sizes. Public domain data; USDA does not endorse Shrunk.
- **Kroger Products API** — live store prices and sizes, shown in the app with the attribution "Prices from Kroger". Shrunk is not affiliated with, endorsed by, or sponsored by The Kroger Co.
- **Open Food Facts** — product names and images, licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/1-0/). Open Food Facts is a nonprofit, community-maintained project and does not endorse Shrunk.
- **Shoppers** — label photos and net-weight readings contributed through the app.
- Brand and product names are trademarks of their owners, used to identify products.

## Your choices

- **Stop everything:** delete the app. Nothing further is sent.
- **Delete what is on the server:** email us the Device ID shown in Settings → About → Device ID and we will erase the device record, your watchlist, your notification settings, and any submissions tied to it. Accepted size observations stay, because they are product facts and carry no identifier.
- **Turn off alerts:** Settings → Notification preferences, or iOS Settings → Notifications → Shrunk.
- **Clear local scan history:** Settings → Clear scan history.
- **Manage or cancel Pro:** iOS Settings → your name → Subscriptions. Apple handles cancellations and refunds.

## Children

Shrunk is not directed at children under 13 and we do not knowingly collect data from them. There is nothing in the app that asks for a name or an age.

## Security

Everything travels over HTTPS. The API stores no credentials for you, because there are none. Our own service credentials live in encrypted secret storage, never in the app.

## Changes

If this policy changes materially, we will update the date at the top and note the change in the app's release notes. The current version always lives at this URL.

## Contact

privacy@stackcurious.com
