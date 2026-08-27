# Shrunk — Trending Data Feed

This directory hosts the canonical `trending.json` consumed by the iOS app.

## Where this file goes

`data/trending.json` is canonical. Two copies are derived from it, and CI (`scripts/check_repo_data.py`, job `fixtures`) fails the build when either drifts:

| Copy | Purpose | Re-sync with |
|---|---|---|
| `backend/src/data/trending.json` | Bundled into the Worker and merged into `GET /v1/feed`, which is what the app's Browse tab reads. | `cd backend && npm run sync:trending` |
| `Shrunk/Resources/trending.json` | The app's offline fallback, and the source of images, prices and evidence links that `/v1/feed` does not carry. | `cp data/trending.json Shrunk/Resources/trending.json` |

The catalogue is also seeded into D1 as `source='curated'` observations (confidence 1.0, `source_ref` = the evidence URL), which is what makes a curated product produce a verdict when it is scanned:

```
python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql
cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql
```

So publishing an edit is: edit `data/trending.json` → re-sync both copies → re-seed D1 → commit → `cd backend && npx wrangler deploy`.

> **Historical note.** Up to v1 the app fetched this file straight from jsDelivr
> (`https://cdn.jsdelivr.net/gh/stackcurious/shrunk@main/data/trending.json`).
> Phase 4 moved the live feed to `GET /v1/feed` so crowd and Kroger observations
> could be merged in. The Worker side of that move has shipped; the iOS Browse
> tab's switch away from jsDelivr (`Shrunk/Services/TrendingFeedService.swift`)
> lands in this same release. The CDN URL still resolves and remains a fine
> way for anyone else to consume the CC-BY data.

## JSON schema

```jsonc
{
  "version": 1,                            // bump on breaking format changes
  "updated": "2026-05-13T00:00:00Z",       // ISO-8601, used for "updated N min ago" UI
  "source_repo": "https://github.com/...", // self-reference for transparency
  "license": "CC-BY-4.0 — ...",
  "trending": [
    {
      "barcode": "0052000133417",          // real UPC if known; used as stable id
      "name": "Gatorade Thirst Quencher",
      "brand": "Gatorade",
      "category": "Beverages",              // see Categories below
      "image_url": "https://...front.jpg",  // null if we don't have one
      "history": [
        { "date": "2018-01-01", "quantity": 32, "unit": "fl oz" },
        { "date": "2021-06-01", "quantity": 28, "unit": "fl oz" }
      ],
      "current_price": 1.89,                // null when unknown
      "currency": "USD",
      "evidence_url": "https://...",        // source documenting the shrink
      "added_at": "2025-09-15"              // when we added this entry
    }
  ]
}
```

### Required fields per entry
- `barcode`, `name`, `brand`, `category`, `history`, `evidence_url`, `added_at`
- `history` must contain at least 2 records with the same unit, or units the
  app can normalize (`oz`, `fl oz`, `g`, `kg`, `ml`, `l`, `count`, `lb`).

### Categories
Must use one of (case-insensitive matching is forgiving but prefer canonical):
- `Snacks`
- `Beverages`
- `Dairy`
- `Paper products`
- `Personal care`
- `Cleaning`
- `Condiments`
- `Sugar`

Anything else falls into "Uncategorized" and won't be filterable from the Browse category tiles.

### Image URLs

Use Open Food Facts CDN where possible:
```
https://images.openfoodfacts.org/images/products/{barcode partitioned}/front_en.{rev}.400.jpg
```

The partitioned format is: split the 13-digit UPC into 3-3-3-4 chunks. e.g. `0052000133417` → `005/200/013/3417`.

If OFF doesn't have an image for this product, set `image_url: null` — the UI falls back to a category glyph.

## Evidence standard

Every entry MUST have an `evidence_url` pointing to a public, verifiable source confirming the shrink. Preferred sources, in order:

1. **Consumer Reports** investigations
2. **BBB** / Better Business Bureau alerts
3. **NYT / WaPo / WSJ / CNN / Reuters / Bloomberg** with specific size figures
4. **Edmunds-style independent investigations**
5. **Reddit r/shrinkflation** — accept only if there's a clear photo + timestamp

Do **not** accept:
- Brand press releases (biased)
- Aggregator articles without primary citation
- Unverified social posts

## Adding a new entry

1. Verify the shrink with at least one primary source. Save the URL.
2. Find the real UPC barcode (Google Image search "product name UPC", or scan IRL).
3. Confirm OFF has the product: `https://world.openfoodfacts.org/api/v2/product/{barcode}.json`
4. Copy the OFF image URL if available; else `null`.
5. Add the entry to `trending.json`.
6. Re-sync both copies: `cp data/trending.json Shrunk/Resources/trending.json` and `cd backend && npm run sync:trending`.
7. Re-seed D1: `python3 scripts/seed_curated.py --curated data/trending.json --out scripts/out/curated.sql` then `cd backend && npx wrangler d1 execute shrunk --remote --file ../scripts/out/curated.sql`.
8. Run `python3 scripts/check_repo_data.py` — it must print `repo data OK`.
9. Bump `version` only if you are changing the schema, not the data.

## Related automation

- `scripts/fdc_import.py` streams a USDA FoodData Central Branded Foods release into `products` + `observations` (`source='fdc'`) and cross-checks this catalogue, reporting which curated GTINs FDC knows about. Re-run on each FDC release (April/October).
- `POST /v1/observations` adds crowd label observations continuously, so `/v1/feed` surfaces shrinks this file has not caught yet.
- Curation stays human: an entry only lands here with a primary-source `evidence_url`.
