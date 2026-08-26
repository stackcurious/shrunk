// Mirror of scripts/fdc/gtin.py. Canonical form: 13-digit zero-padded GTIN with check digit.
export function normalizeGTIN(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12) return "0" + digits;
  if (digits.length === 13) return digits;
  if (digits.length === 14 && digits.startsWith("0")) return digits.slice(1);
  return null;
}
