import { canonicalCategory } from "../categories";

export interface OFFHit { name: string; brand: string; imageUrl: string | null; category: string }

export async function lookupOFF(gtin: string, fetchImpl: typeof fetch = fetch): Promise<OFFHit | null> {
  const url = `https://world.openfoodfacts.org/api/v2/product/${gtin}.json?fields=product_name,brands,image_url,categories_tags`;
  try {
    const res = await fetchImpl(url, { headers: { "User-Agent": "Shrunk/2.0 (stackcurious.com/shrunk)" } });
    if (!res.ok) return null;
    const body = (await res.json()) as {
      status?: number;
      product?: { product_name?: string; brands?: string; image_url?: string; categories_tags?: string[] };
    };
    if (body.status !== 1 || !body.product) return null;
    const name = (body.product.product_name ?? "").trim();
    if (!name) return null;
    return {
      name,
      brand: (body.product.brands ?? "").split(",")[0].trim(),
      imageUrl: body.product.image_url ?? null,
      category: offCategory(body.product.categories_tags),
    };
  } catch {
    return null;
  }
}

/**
 * I8 — never the literal "Uncategorized" sentinel; a real category or "".
 * `categories_tags` is a hierarchy from broadest to most specific
 * ("en:snacks", "en:salty-snacks", ...) — the last tag is the most specific.
 * Routed through canonicalCategory so it agrees with our vocabulary when
 * recognised, otherwise OFF's own wording survives rather than being
 * discarded.
 */
function offCategory(tags: string[] | undefined): string {
  const last = tags?.[tags.length - 1];
  if (!last) return "";
  const stripped = last.startsWith("en:") ? last.slice(3) : last;
  return canonicalCategory(stripped) ?? "";
}
