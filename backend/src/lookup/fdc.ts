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

/**
 * FDC matches `query` against the `gtinUpc` string exactly as it stores it,
 * and it stores all three spellings — of 50 sampled "Doritos" records, 26 were
 * 14-digit, 19 were 12-digit and only 5 were 13-digit. Sending our canonical
 * 13-digit zero-padded GTIN therefore missed most of the catalogue outright
 * (`query=0016000362451` -> 0 hits; `query=00016000362451` -> 1), which is why
 * on-miss lookups so rarely carried FDC data. A field-scoped leading wildcard
 * on the zero-stripped digits matches every padding; the caller still requires
 * an exact `normalizeGTIN` match, so the wildcard cannot widen what we accept.
 */
function gtinQuery(gtin: string): string | null {
  const digits = gtin.replace(/^0+/, "");
  return digits ? `gtinUpc:*${digits}` : null;
}

export async function lookupFDC(gtin: string, apiKey: string, fetchImpl: typeof fetch = fetch): Promise<FDCHit | null> {
  const query = gtinQuery(gtin);
  if (!query) return null;
  // pageSize > 1 because a leading wildcard can also match a longer gtin that
  // ends in the same digits; the exact match below picks ours out of the page.
  const url = `https://api.nal.usda.gov/fdc/v1/foods/search?query=${encodeURIComponent(query)}&dataType=Branded&pageSize=5&api_key=${encodeURIComponent(apiKey)}`;
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
    const food = body.foods?.find((f) => normalizeGTIN(f.gtinUpc ?? "") === gtin);
    if (!food) return null;
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
