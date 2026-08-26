export interface OFFHit { name: string; brand: string; imageUrl: string | null }

export async function lookupOFF(gtin: string, fetchImpl: typeof fetch = fetch): Promise<OFFHit | null> {
  const url = `https://world.openfoodfacts.org/api/v2/product/${gtin}.json?fields=product_name,brands,image_url`;
  try {
    const res = await fetchImpl(url, { headers: { "User-Agent": "Shrunk/2.0 (stackcurious.com/shrunk)" } });
    if (!res.ok) return null;
    const body = (await res.json()) as { status?: number; product?: { product_name?: string; brands?: string; image_url?: string } };
    if (body.status !== 1 || !body.product) return null;
    const name = (body.product.product_name ?? "").trim();
    if (!name) return null;
    return {
      name,
      brand: (body.product.brands ?? "").split(",")[0].trim(),
      imageUrl: body.product.image_url ?? null,
    };
  } catch {
    return null;
  }
}
