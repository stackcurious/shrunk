import { normalizeGTIN } from "../gtin";

/**
 * Kroger identifies products by an 11-digit UPC-A core zero-padded to 13 —
 * our GTIN-13 with the leading zero and the check digit removed.
 *   ours 0028400642255 -> Kroger 0002840064225
 */
export function krogerProductId(gtin: string | null | undefined): string | null {
  const normalized = normalizeGTIN(gtin ?? "");
  if (!normalized) return null;
  return normalized.slice(1, -1).padStart(13, "0");
}

/** The reverse: recompute the UPC-A check digit and prefix the GTIN-13 zero. */
export function gtinFromKroger(upc: string | null | undefined): string | null {
  const digits = (upc ?? "").replace(/\D/g, "");
  if (digits.length === 0 || digits.length > 13) return null;
  const core = digits.padStart(13, "0").slice(-11);
  return `0${core}${upcCheckDigit(core)}`;
}

/** UPC-A check digit over the 11 data digits: 3x the odd positions, 1x the even. */
export function upcCheckDigit(core: string): string {
  let sum = 0;
  for (let i = 0; i < 11; i++) {
    const digit = core.charCodeAt(i) - 48;
    sum += i % 2 === 0 ? digit * 3 : digit;
  }
  return String((10 - (sum % 10)) % 10);
}
