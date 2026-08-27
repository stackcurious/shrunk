import { canonicalCategory } from "../categories";
import { normalizeGTIN } from "../gtin";

export interface FDCHit {
  name: string;
  brand: string;
  category: string;
  /** Raw FDC `packageWeight` (e.g. "28 fl oz"), for spec §1 rule 6 — null when FDC didn't report one. */
  packageWeight: string | null;
  /** Epoch seconds parsed from FDC `publishedDate`/`modifiedDate`, or null when neither is present/parseable. */
  observedAt: number | null;
  /** FDC's own id for this record, used as observations.source_ref when we record a size. */
  fdcId: string | null;
}

function titleCase(s: string): string {
  return s.toLowerCase().replace(/(^|\s)\S/g, (m) => m.toUpperCase());
}

/** Spec §1 rule 6 — FDC `publishedDate`/`modifiedDate`, preferring publishedDate. */
function parseFdcDate(publishedDate?: string, modifiedDate?: string): number | null {
  for (const candidate of [publishedDate, modifiedDate]) {
    if (!candidate) continue;
    const ms = Date.parse(candidate);
    if (Number.isFinite(ms)) return Math.floor(ms / 1000);
  }
  return null;
}

export async function lookupFDC(gtin: string, apiKey: string, fetchImpl: typeof fetch = fetch): Promise<FDCHit | null> {
  const url = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${gtin}&dataType=Branded&pageSize=1&api_key=${encodeURIComponent(apiKey)}`;
  try {
    const res = await fetchImpl(url);
    if (!res.ok) return null;
    const body = (await res.json()) as {
      foods?: Array<{
        fdcId?: number | string;
        gtinUpc?: string;
        description?: string;
        brandName?: string;
        brandOwner?: string;
        foodCategory?: string;
        packageWeight?: string;
        publishedDate?: string;
        modifiedDate?: string;
      }>;
    };
    const food = body.foods?.[0];
    if (!food || normalizeGTIN(food.gtinUpc ?? "") !== gtin) return null;
    return {
      name: titleCase((food.description ?? "").trim()),
      brand: (food.brandName ?? food.brandOwner ?? "").trim(),
      // I8: routed through canonicalCategory so it agrees with our
      // vocabulary when it matches an alias; otherwise the raw FDC wording
      // survives (canonicalCategory's own fallback behaviour).
      category: canonicalCategory(food.foodCategory) ?? "",
      packageWeight: food.packageWeight?.trim() || null,
      observedAt: parseFdcDate(food.publishedDate, food.modifiedDate),
      fdcId: food.fdcId != null ? String(food.fdcId) : null,
    };
  } catch {
    return null;
  }
}
