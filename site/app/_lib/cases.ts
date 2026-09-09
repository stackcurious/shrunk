// AUTO-COPIED from /Users/drao/Projects/shrunk/data/trending.json — do not hand-edit
// the RAW_CASES array below. Re-sync by re-running the export in that repo and pasting
// the `trending` array back in here (see shrunk/CLAUDE.md: "curated catalogue lives in
// three places"). Everything else in this file — types, slugify, and the derived-field
// helpers — is hand-written and safe to edit.
//
// Source dataset version: 1 · last updated: 2026-08-27T18:00:00Z
// License: CC-BY-4.0 — data fields are facts; the curation/commentary is licensed Creative Commons Attribution.

export interface CaseHistoryPoint {
  date: string;
  quantity: number;
  unit: string;
}

export interface RawCase {
  barcode: string;
  name: string;
  brand: string;
  category: string;
  image_url: string | null;
  history: CaseHistoryPoint[];
  current_price: number | null;
  currency: string;
  evidence_url: string;
  /** Human-readable name of the publication behind `evidence_url`. */
  source: string;
  added_at: string;
}

export interface Case extends RawCase {
  slug: string;
  before: CaseHistoryPoint;
  after: CaseHistoryPoint;
  /** How much smaller the package got, 0-100. (32oz -> 28oz = 12.5) */
  percentSmaller: number;
  /** Current price divided by the earlier documented size; a comparison, not price history. */
  pricePerUnitAtEarlierSize: number | null;
  /** Current price divided by the reduced documented size; a comparison, not price history. */
  pricePerUnitAtReducedSize: number | null;
  /** Difference between those two same-current-price comparisons, 0-100+. */
  unitPriceDifferencePercent: number | null;
  sourceDomain: string;
}

/** Normalizes accented characters, drops apostrophes, and dashes everything else. */
export function slugify(input: string): string {
  return input
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/['’]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function toCase(raw: RawCase): Case {
  const [before, after] = raw.history;
  const percentSmaller = ((before.quantity - after.quantity) / before.quantity) * 100;
  // `current_price` is the real Kroger shelf price where we have one, and null
  // where we don't — never a stand-in. Every derived per-unit figure is null in
  // that case rather than silently reading as $0.00.
  const price = raw.current_price;
  const pricePerUnitAtEarlierSize = price === null ? null : price / before.quantity;
  const pricePerUnitAtReducedSize = price === null ? null : price / after.quantity;
  const unitPriceDifferencePercent =
    pricePerUnitAtEarlierSize === null || pricePerUnitAtReducedSize === null
      ? null
      : ((pricePerUnitAtReducedSize - pricePerUnitAtEarlierSize) /
          pricePerUnitAtEarlierSize) *
        100;
  let sourceDomain = raw.evidence_url;
  try {
    sourceDomain = new URL(raw.evidence_url).hostname.replace(/^www\./, "");
  } catch {
    // leave sourceDomain as the raw URL if it somehow doesn't parse
  }
  return {
    ...raw,
    slug: slugify(raw.name),
    before,
    after,
    percentSmaller,
    pricePerUnitAtEarlierSize,
    pricePerUnitAtReducedSize,
    unitPriceDifferencePercent,
    sourceDomain,
  };
}

const RAW_CASES: RawCase[] = [
  {
    "barcode": "0052000135138",
    "name": "Gatorade Thirst Quencher",
    "brand": "Gatorade",
    "category": "Beverages",
    "image_url": "https://images.openfoodfacts.org/images/products/005/200/013/5138/front_en.6.400.jpg",
    "history": [
      {
        "date": "2021-03-07",
        "quantity": 32,
        "unit": "fl oz"
      },
      {
        "date": "2022-03-07",
        "quantity": 28,
        "unit": "fl oz"
      }
    ],
    "current_price": 1.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2022/03/07/shrink-mar22/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0028400516464",
    "name": "Doritos Nacho Cheese",
    "brand": "Doritos",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/002/840/051/6464/front_en.62.400.jpg",
    "history": [
      {
        "date": "2020-05-10",
        "quantity": 9.75,
        "unit": "oz"
      },
      {
        "date": "2021-05-10",
        "quantity": 9.25,
        "unit": "oz"
      }
    ],
    "current_price": 5.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2021/05/10/here-we-downsize-and-up-size-again-spring-2021/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0025500304403",
    "name": "Folgers Breakfast Blend Coffee",
    "brand": "Folgers",
    "category": "Beverages",
    "image_url": "https://images.openfoodfacts.org/images/products/002/550/030/4403/front_en.5.400.jpg",
    "history": [
      {
        "date": "2022-12-18",
        "quantity": 25.4,
        "unit": "oz"
      },
      {
        "date": "2023-12-18",
        "quantity": 22.6,
        "unit": "oz"
      }
    ],
    "current_price": 16.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2023/12/18/here-we-shrink-again-year-end-2023/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0030772132173",
    "name": "Charmin Ultra Strong Mega Roll",
    "brand": "Charmin",
    "category": "Paper products",
    "image_url": null,
    "history": [
      {
        "date": "2017-12-24",
        "quantity": 308,
        "unit": "count"
      },
      {
        "date": "2018-12-24",
        "quantity": 286,
        "unit": "count"
      }
    ],
    "current_price": 16.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2018/12/24/here-we-downsize-again-dec-2018/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0036000554892",
    "name": "Cottonelle Ultra Clean Care",
    "brand": "Cottonelle",
    "category": "Paper products",
    "image_url": null,
    "history": [
      {
        "date": "2021-03-14",
        "quantity": 340,
        "unit": "count"
      },
      {
        "date": "2022-03-14",
        "quantity": 312,
        "unit": "count"
      }
    ],
    "current_price": 13.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2022/03/14/here-we-downsize-again-winter-22-part-2/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0030772157039",
    "name": "Bounty Select-A-Size Paper Towels",
    "brand": "Bounty",
    "category": "Paper products",
    "image_url": null,
    "history": [
      {
        "date": "2022-05-01",
        "quantity": 98,
        "unit": "count"
      },
      {
        "date": "2023-05-01",
        "quantity": 90,
        "unit": "count"
      }
    ],
    "current_price": 14.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2023/05/01/may23/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0030772125472",
    "name": "Crest 3D White Toothpaste",
    "brand": "Crest",
    "category": "Personal care",
    "image_url": null,
    "history": [
      {
        "date": "2020-12-27",
        "quantity": 4.1,
        "unit": "oz"
      },
      {
        "date": "2021-12-27",
        "quantity": 3.8,
        "unit": "oz"
      }
    ],
    "current_price": 5.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2021/12/27/here-we-downsize-again-year-end-2021/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0044000069216",
    "name": "Wheat Thins Original",
    "brand": "Nabisco",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/004/400/006/9216/front_en.37.400.jpg",
    "history": [
      {
        "date": "2020-05-10",
        "quantity": 16,
        "unit": "oz"
      },
      {
        "date": "2021-05-10",
        "quantity": 14,
        "unit": "oz"
      }
    ],
    "current_price": 6.29,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2021/05/10/here-we-downsize-and-up-size-again-spring-2021/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0044000060169",
    "name": "Oreo Thins Family Size",
    "brand": "Nabisco",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/004/400/006/0169/front_en.48.400.jpg",
    "history": [
      {
        "date": "2023-04-15",
        "quantity": 13.1,
        "unit": "oz"
      },
      {
        "date": "2024-04-15",
        "quantity": 11.78,
        "unit": "oz"
      }
    ],
    "current_price": 5.29,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2024/04/15/here-we-shrink-again-spring-2024/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0028400310413",
    "name": "Lay's Classic Party Size",
    "brand": "Lay's",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/002/840/031/0413/front_en.39.400.jpg",
    "history": [
      {
        "date": "2019-08-03",
        "quantity": 15.25,
        "unit": "oz"
      },
      {
        "date": "2020-08-03",
        "quantity": 13,
        "unit": "oz"
      }
    ],
    "current_price": 5.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2020/08/03/here-we-downsize-again-summer-2020/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0028400517942",
    "name": "Tostitos Hint of Lime",
    "brand": "Tostitos",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/002/840/051/7942/front_en.60.400.jpg",
    "history": [
      {
        "date": "2020-08-09",
        "quantity": 13,
        "unit": "oz"
      },
      {
        "date": "2021-08-09",
        "quantity": 11,
        "unit": "oz"
      }
    ],
    "current_price": 5.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2021/08/09/here-we-downsize-again-summer-2021-part-2/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0014100054672",
    "name": "Goldfish Cheddar Carton",
    "brand": "Pepperidge Farm",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/001/410/005/4672/front_en.30.400.jpg",
    "history": [
      {
        "date": "2022-12-18",
        "quantity": 30,
        "unit": "oz"
      },
      {
        "date": "2023-12-18",
        "quantity": 27.3,
        "unit": "oz"
      }
    ],
    "current_price": 10.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2023/12/18/here-we-shrink-again-year-end-2023/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0077567254238",
    "name": "Breyers Natural Vanilla",
    "brand": "Breyers",
    "category": "Dairy",
    "image_url": "https://images.openfoodfacts.org/images/products/007/756/725/4238/front_en.8.400.jpg",
    "history": [
      {
        "date": "2007-05-12",
        "quantity": 56,
        "unit": "fl oz"
      },
      {
        "date": "2008-05-12",
        "quantity": 48,
        "unit": "fl oz"
      }
    ],
    "current_price": 5.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2008/05/12/ice-cream-scoop-major-brands-downsize-again/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0041548001869",
    "name": "Edy's/Dreyer's Slow Churned",
    "brand": "Edy's",
    "category": "Dairy",
    "image_url": "https://images.openfoodfacts.org/images/products/004/154/800/1869/front_en.11.400.jpg",
    "history": [
      {
        "date": "2007-05-12",
        "quantity": 56,
        "unit": "fl oz"
      },
      {
        "date": "2008-05-12",
        "quantity": 48,
        "unit": "fl oz"
      }
    ],
    "current_price": 3.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2008/05/12/ice-cream-scoop-major-brands-downsize-again/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0048500205716",
    "name": "Tropicana Pure Premium Orange Juice",
    "brand": "Tropicana",
    "category": "Beverages",
    "image_url": "https://images.openfoodfacts.org/images/products/004/850/020/5716/front_en.58.400.jpg",
    "history": [
      {
        "date": "2017-08-13",
        "quantity": 59,
        "unit": "fl oz"
      },
      {
        "date": "2018-08-13",
        "quantity": 52,
        "unit": "fl oz"
      }
    ],
    "current_price": 4.79,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2018/08/13/tropicana-orange-juice-downsizes-again/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0048001213487",
    "name": "Hellmann's Real Mayonnaise",
    "brand": "Hellmann's",
    "category": "Condiments",
    "image_url": "https://images.openfoodfacts.org/images/products/004/800/121/3487/front_en.105.400.jpg",
    "history": [
      {
        "date": "2005-08-28",
        "quantity": 32,
        "unit": "fl oz"
      },
      {
        "date": "2006-08-28",
        "quantity": 30,
        "unit": "fl oz"
      }
    ],
    "current_price": 7.29,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2006/08/28/hellmans-mayo-introduces-the-30-oz-quart/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0019200771825",
    "name": "Lysol Disinfecting Wipes",
    "brand": "Lysol",
    "category": "Cleaning",
    "image_url": null,
    "history": [
      {
        "date": "2017-03-05",
        "quantity": 19.7,
        "unit": "oz"
      },
      {
        "date": "2018-03-05",
        "quantity": 17.7,
        "unit": "oz"
      }
    ],
    "current_price": 5.79,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2018/03/05/a-different-kind-of-downsizing/",
    "source": "Mouse Print*",
    "added_at": "2025-09-15"
  },
  {
    "barcode": "0030772222300",
    "name": "Dawn Platinum Dish Soap",
    "brand": "Dawn",
    "category": "Cleaning",
    "image_url": null,
    "history": [
      {
        "date": "2025-06-08",
        "quantity": 32,
        "unit": "fl oz"
      },
      {
        "date": "2026-06-08",
        "quantity": 30,
        "unit": "fl oz"
      }
    ],
    "current_price": 5.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2026/06/08/here-we-shrink-again-spring-2026-part-2/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0051500442951",
    "name": "Smucker's Strawberry Jam",
    "brand": "Smucker's",
    "category": "Condiments",
    "image_url": "https://images.openfoodfacts.org/images/products/005/150/044/2951/front_en.3.400.jpg",
    "history": [
      {
        "date": "2025-06-08",
        "quantity": 32,
        "unit": "oz"
      },
      {
        "date": "2026-06-08",
        "quantity": 30,
        "unit": "oz"
      }
    ],
    "current_price": 4.99,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2026/06/08/here-we-shrink-again-spring-2026-part-2/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0048121959517",
    "name": "Thomas' Plain Bagels (6 ct)",
    "brand": "Thomas'",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/004/812/195/9517/front_en.131.400.jpg",
    "history": [
      {
        "date": "2025-06-01",
        "quantity": 20,
        "unit": "oz"
      },
      {
        "date": "2026-06-01",
        "quantity": 18,
        "unit": "oz"
      }
    ],
    "current_price": 4.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2026/06/01/here-we-shrink-again-spring-2026-part-1/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0013300009611",
    "name": "Hungry Jack Original Syrup",
    "brand": "Hungry Jack",
    "category": "Condiments",
    "image_url": "https://images.openfoodfacts.org/images/products/001/330/000/9611/front_en.9.400.jpg",
    "history": [
      {
        "date": "2025-01-26",
        "quantity": 27.6,
        "unit": "fl oz"
      },
      {
        "date": "2026-01-26",
        "quantity": 24,
        "unit": "fl oz"
      }
    ],
    "current_price": 4.79,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2026/01/26/here-we-shrink-again-winter-2026-part-2/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0689544083016",
    "name": "Fage Total 0% Greek Yogurt",
    "brand": "Fage",
    "category": "Dairy",
    "image_url": "https://images.openfoodfacts.org/images/products/068/954/408/3016/front_en.450.400.jpg",
    "history": [
      {
        "date": "2022-05-01",
        "quantity": 35.3,
        "unit": "oz"
      },
      {
        "date": "2023-05-01",
        "quantity": 32,
        "unit": "oz"
      }
    ],
    "current_price": 7.29,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2023/05/01/may23/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0041192100413",
    "name": "Kellogg's Froot Loops",
    "brand": "Kellogg's",
    "category": "Snacks",
    "image_url": "https://images.openfoodfacts.org/images/products/004/119/210/0413/front_en.23.400.jpg",
    "history": [
      {
        "date": "2023-04-15",
        "quantity": 10.1,
        "unit": "oz"
      },
      {
        "date": "2024-04-15",
        "quantity": 8.9,
        "unit": "oz"
      }
    ],
    "current_price": 4.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2024/04/15/here-we-shrink-again-spring-2024/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0035000510853",
    "name": "Colgate Cavity Protection",
    "brand": "Colgate",
    "category": "Personal care",
    "image_url": null,
    "history": [
      {
        "date": "2015-05-16",
        "quantity": 8.2,
        "unit": "oz"
      },
      {
        "date": "2016-05-16",
        "quantity": 8,
        "unit": "oz"
      }
    ],
    "current_price": 2.69,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2016/05/16/here-we-downsize-again-2016-part-2/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  },
  {
    "barcode": "0047400097728",
    "name": "Gillette Antiperspirant",
    "brand": "Gillette",
    "category": "Personal care",
    "image_url": null,
    "history": [
      {
        "date": "2014-12-21",
        "quantity": 4,
        "unit": "oz"
      },
      {
        "date": "2015-12-21",
        "quantity": 3.8,
        "unit": "oz"
      }
    ],
    "current_price": 7.49,
    "currency": "USD",
    "evidence_url": "https://www.mouseprint.org/2015/12/21/here-we-downsize-again-2015-part-4/",
    "source": "Mouse Print*",
    "added_at": "2026-08-27"
  }
];

export const CASES: Case[] = RAW_CASES.map(toCase).sort(
  (a, b) => b.percentSmaller - a.percentSmaller
);

export const CATEGORIES: string[] = Array.from(new Set(CASES.map((c) => c.category))).sort();

export function caseBySlug(slug: string): Case | undefined {
  return CASES.find((c) => c.slug === slug);
}

export function casesByCategory(): { category: string; cases: Case[] }[] {
  return CATEGORIES.map((category) => ({
    category,
    cases: CASES.filter((c) => c.category === category),
  }));
}

export function relatedCases(current: Case, count = 3): Case[] {
  const sameCategory = CASES.filter(
    (c) => c.category === current.category && c.slug !== current.slug
  );
  const rest = CASES.filter(
    (c) => c.category !== current.category && c.slug !== current.slug
  );
  return [...sameCategory, ...rest].slice(0, count);
}

export function formatQuantity(point: CaseHistoryPoint): string {
  return `${point.quantity} ${point.unit}`;
}
