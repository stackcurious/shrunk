/**
 * One spelling per category. The app's `GroceryCategory` titles, the curated
 * catalogue and `products.category` all use slightly different words for the
 * same shelf; the digest and the feed compare *canonical* names only.
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
  personal: "Personal care",
  "personal care": "Personal care",
  cosmetics: "Personal care",
  paper: "Paper products",
  "paper products": "Paper products",
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
