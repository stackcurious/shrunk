// Single source of truth for pricing, URLs and identifiers used across every
// /shrunk page. Keep this in sync with /Users/drao/Projects/shrunk/docs/APP_STORE_LISTING.md —
// that file wins if the two ever disagree.

export const SITE_URL = "https://stackcurious.com";
export const SHRUNK_URL = `${SITE_URL}/shrunk`;

export const APP_STORE_ID = "6805856154";
export const APP_STORE_URL = `https://apps.apple.com/us/app/shrunk-shrinkflation-scanner/id${APP_STORE_ID}`;

// The address published in docs/PRIVACY_POLICY.md and docs/TERMS.md in the app
// repo, and the one filed in App Store Connect. Those documents are the source
// of truth for Shrunk's legal pages — keep this in sync with them rather than
// with the studio-wide default address.
export const SUPPORT_EMAIL = "privacy@stackcurious.com";

export const PRICE_MONTHLY = "2.99";
export const PRICE_YEARLY = "14.99";
export const TRIAL_DAYS = 7;

export const RED = "#E24B4A";

export const FREE_FEATURES = [
  "Unlimited barcode scans",
  "Shrink verdict and size history",
  "Current price and cost per unit at your store",
  "The browse feed of verified cases",
  "Contribute label photos",
  "3 alternatives per scan",
];

export const PRO_FEATURES = [
  "Watchlist alerts — a push the moment something you watch gets smaller, or its price per unit jumps 5%",
  "Weekly “what shrank this week” digest for your categories",
  "Unlimited ranked alternatives at your store, cheapest per unit first",
  "Full price and size history charts",
  "Savings dashboard built from what you actually scan — no invented numbers",
];

export const DATA_SOURCES = [
  {
    name: "USDA FoodData Central",
    url: "https://fdc.nal.usda.gov/",
    body: "The federal government's public nutrition and packaging dataset. It records net-weight package sizes for hundreds of thousands of US grocery products going back years — the historical \"before\" size behind most verdicts.",
  },
  {
    name: "Kroger Products API",
    url: "https://developer.kroger.com/",
    body: "Kroger's official developer API. Once you pick your store, Shrunk reads today's shelf price, current package size, and stock status directly from it — not a scrape, not an estimate.",
  },
  {
    name: "Open Food Facts",
    url: "https://world.openfoodfacts.org/",
    body: "A nonprofit, community-maintained product database, licensed ODbL. It supplies product names, brands, and package photos for items outside the USDA and Kroger catalogs.",
  },
  {
    name: "Human-verified cases",
    url: undefined,
    body: "25 hand-checked shrinkflation cases, each with a cited public source — chiefly Edgar Dworsky's mouseprint.org downsizing archive. Every citation is fetched and must state both the before and the after size for that exact product. No entry ships without a link you can check yourself.",
  },
];
