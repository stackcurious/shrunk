import { describe, expect, it, vi } from "vitest";
import { lookupFDC } from "../src/lookup/fdc";
import { lookupOFF } from "../src/lookup/off";

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("lookupFDC", () => {
  it("returns name/brand/category when the gtin matches", async () => {
    const fetchImpl = vi.fn(async (url: string) => {
      expect(url).toContain("query=0028400642255");
      expect(url).toContain("api_key=k");
      return jsonResponse({ foods: [{ gtinUpc: "028400642255", description: "GATORADE THIRST QUENCHER", brandOwner: "Stokely-Van Camp", brandName: "Gatorade", foodCategory: "Sports Drinks" }] });
    });
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    // "Sports Drinks" matches no alias, so canonicalCategory keeps it as-is.
    expect(hit).toEqual({ name: "Gatorade Thirst Quencher", brand: "Gatorade", category: "Sports Drinks" });
  });

  it("returns null when the top hit is a different gtin or the request fails", async () => {
    const wrong = vi.fn(async () => jsonResponse({ foods: [{ gtinUpc: "011111111111", description: "X" }] }));
    expect(await lookupFDC("0028400642255", "k", wrong as unknown as typeof fetch)).toBeNull();
    const failing = vi.fn(async () => jsonResponse({}, 500));
    expect(await lookupFDC("0028400642255", "k", failing as unknown as typeof fetch)).toBeNull();
  });

  // I8: foodCategory is routed through canonicalCategory so it agrees with
  // the same vocabulary products.category, the digest and the feed use.
  it("I8: maps foodCategory through canonicalCategory when it matches an alias", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ foods: [{ gtinUpc: "028400642255", description: "X", brandName: "X", foodCategory: "beverage" }] }),
    );
    const hit = await lookupFDC("0028400642255", "k", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("Beverages");
  });
});

describe("lookupOFF", () => {
  it("returns name/brand/image/category on status 1", async () => {
    const fetchImpl = vi.fn(async (url: string, init?: RequestInit) => {
      expect((init?.headers as Record<string, string>)["User-Agent"]).toContain("Shrunk/2.0");
      // I8: categories_tags must be requested — it is the only source of a
      // real category from OFF.
      expect(url).toContain("categories_tags");
      return jsonResponse({
        status: 1,
        product: {
          product_name: "Doritos Nacho Cheese",
          brands: "Doritos, Frito-Lay",
          image_url: "https://img/x.jpg",
          categories_tags: ["en:snacks", "en:salty-snacks", "en:tortilla-chips"],
        },
      });
    });
    expect(await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch)).toEqual({
      name: "Doritos Nacho Cheese",
      brand: "Doritos",
      imageUrl: "https://img/x.jpg",
      // I8: last tag, "en:" stripped, routed through canonicalCategory —
      // "tortilla-chips" has no alias, so it is kept as-is.
      category: "tortilla-chips",
    });
  });

  it("I8: maps the last categories_tags entry through canonicalCategory when it matches an alias", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ status: 1, product: { product_name: "X", categories_tags: ["en:groceries", "en:beverages"] } }),
    );
    const hit = await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("Beverages");
  });

  it("I8: category is '' — never the literal 'Uncategorized' — when categories_tags is absent", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ status: 1, product: { product_name: "X" } }));
    const hit = await lookupOFF("0028400642255", fetchImpl as unknown as typeof fetch);
    expect(hit?.category).toBe("");
    expect(hit?.category).not.toBe("Uncategorized");
  });

  it("returns null on status 0 or non-200", async () => {
    const miss = vi.fn(async () => jsonResponse({ status: 0 }));
    expect(await lookupOFF("0028400642255", miss as unknown as typeof fetch)).toBeNull();
    const notFound = vi.fn(async () => jsonResponse({}, 404));
    expect(await lookupOFF("0028400642255", notFound as unknown as typeof fetch)).toBeNull();
  });
});
