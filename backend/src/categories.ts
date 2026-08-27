/**
 * One spelling per category. The app's `GroceryCategory` titles, the curated
 * catalogue and `products.category` all use slightly different words for the
 * same shelf; the digest and the feed compare *canonical* names only.
 *
 * I5 — Kroger's product API (`product.categories[0]`, `kroger/map.ts`)
 * reports its own top-level taxonomy. Most of it already agrees with ours
 * case-insensitively ("Personal Care", "Paper Products", "Beverages",
 * "Dairy", "Snacks" all canonicalise correctly with no entry needed below);
 * "Household Essentials" is the confirmed mismatch — Kroger files cleaning
 * supplies under that name, not "Cleaning" — so it, and the "Cleaning
 * Supplies" variant seen elsewhere in Kroger's own taxonomy, are aliased.
 */
const ALIASES: Record<string, string> = {
  snack: "Snacks",
  snacks: "Snacks",
  drink: "Beverages",
  drinks: "Beverages",
  beverage: "Beverages",
  beverages: "Beverages",
  dairy: "Dairy",
  dairies: "Dairy",
  cleaning: "Cleaning",
  "cleaning products": "Cleaning",
  "cleaning supplies": "Cleaning",
  "household essentials": "Cleaning",
  personal: "Personal care",
  "personal care": "Personal care",
  cosmetics: "Personal care",
  paper: "Paper products",
  "paper products": "Paper products",
  // I5 — curated-catalogue-only shelves (backend/src/data/trending.json has
  // exactly one product filed under each). Kept as their own canonical
  // names on purpose: the feed and Browse's "hall of shame" list still need
  // to match a product filed under "Condiments" or "Sugar". But
  // `GroceryCategory` (Shrunk/Models/GroceryCategory+Feed.swift) has no case
  // for either — condiments were deliberately pulled out of the Personal
  // Care tile filter rather than given their own (commit 519fd30) — so
  // onboarding never offers them and no device.categories can ever contain
  // "Condiments" or "Sugar". A weekly-digest count filed under either name
  // is therefore always uncollectable by design, not a bug: see the
  // "curated-only categories" test in test/digest.test.ts.
  condiment: "Condiments",
  condiments: "Condiments",
  sugar: "Sugar",
};

export function canonicalCategory(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  return ALIASES[trimmed.toLowerCase()] ?? trimmed;
}
