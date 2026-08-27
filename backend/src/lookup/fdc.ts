import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";

export interface FDCHit { name: string; brand: string; category: string }

function titleCase(s: string): string {
  return s.toLowerCase().replace(/(^|\s)\S/g, (m) => m.toUpperCase());
}

export async function lookupFDC(gtin: string, apiKey: string, fetchImpl: typeof fetch = fetch): Promise<FDCHit | null> {
  const url = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${gtin}&dataType=Branded&pageSize=1&api_key=${encodeURIComponent(apiKey)}`;
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    const body = (await res.json()) as { foods?: Array<{ gtinUpc?: string; description?: string; brandName?: string; brandOwner?: string; foodCategory?: string }> };
    const food = body.foods?.[0];
    if (!food || normalizeGTIN(food.gtinUpc ?? "") !== gtin) return null;
    return {
      name: titleCase((food.description ?? "").trim()),
      brand: (food.brandName ?? food.brandOwner ?? "").trim(),
      // I8: routed through canonicalCategory so it agrees with our
      // vocabulary when it matches an alias; otherwise the raw FDC wording
      // survives (canonicalCategory's own fallback behaviour).
      category: canonicalCategory(food.foodCategory) ?? "",
    };
  } catch {
    return null;
  }
}
