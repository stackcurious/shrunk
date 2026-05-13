# Shrunk — Trending Data Feed

This directory hosts the canonical `trending.json` consumed by the iOS app.

## Deployment

The app fetches the live feed from jsDelivr (a free CDN that fronts GitHub):

```
https://cdn.jsdelivr.net/gh/stackcurious/shrunk@main/data/trending.json
```

To publish updates: edit `trending.json`, commit, push to `main`. jsDelivr serves the new version within ~minutes (or force-purge at https://www.jsdelivr.com/tools/purge).

The app also bundles a copy at `Shrunk/Resources/trending.json` as an offline fallback. **Keep these two files in sync** — easiest is to copy after edits:

```
cp data/trending.json Shrunk/Resources/trending.json
```

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
5. Add the entry to `trending.json`, push to main.
6. Copy the updated file into `Shrunk/Resources/trending.json` so the bundled fallback stays current.
7. Bump `version` only if you're changing the schema, not the data.

## Future automation

Phase 2 of the data pipeline (not yet built) will:
- Process OFF's daily JSONL dump (~5GB compressed) on a Cloudflare Worker cron
- Diff product quantities week-over-week
- Auto-flag candidates with >5% size reduction
- Surface to an admin queue for human verification before joining `trending.json`

For now this is fully manual / curated.
