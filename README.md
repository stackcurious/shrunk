# Shrunk

iOS app that scans grocery barcodes and tells you when a product has shrunk in size while the price stayed the same.

- **Free**: unlimited scans, verdict + size history, top alternatives
- **Pro ($9.99 one-time)**: watchlist with background sweeps, real-time alerts, ranked alternatives, savings dashboard

## Stack

- SwiftUI · iOS 17+
- SwiftData (Watchlist, Alerts)
- Swift Charts (Savings Dashboard)
- StoreKit 2 (one-time non-consumable IAP)
- AVFoundation (barcode scanning)
- XcodeGen (`project.yml` is the source of truth)

## Build

```
brew install xcodegen
xcodegen generate
open Shrunk.xcodeproj
```

## Data feed

The Browse tab pulls verified shrinkflation cases from a hosted JSON at:

```
https://cdn.jsdelivr.net/gh/stackcurious/shrunk@main/data/trending.json
```

To update the feed, edit `data/trending.json` on `main`. jsDelivr serves the new copy within minutes. See [data/README.md](./data/README.md) for the schema and evidence standard.

The app bundles a fallback copy at `Shrunk/Resources/trending.json` so it works offline.

## License

Code: all rights reserved (for now).
Data in `data/trending.json`: CC-BY-4.0 — facts are facts, attribute the curation if you reuse.
