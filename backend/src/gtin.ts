// Mirror of scripts/fdc/gtin.py. Canonical form: 13-digit zero-padded GTIN with check digit.
export function normalizeGTIN(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const compact = raw.replace(/[\s-]/g, "");
  if (!/^\d+$/.test(compact)) return null;

  let canonical: string;
  if (compact.length === 8) canonical = "00000" + compact;
  else if (compact.length === 12) canonical = "0" + compact;
  else if (compact.length === 13) canonical = compact;
  else if (compact.length === 14 && compact.startsWith("0")) canonical = compact.slice(1);
  else return null;

  const digits = [...canonical].map(Number);
  const supplied = digits[12];
  const sum = digits.slice(0, 12).reverse().reduce(
    (total, digit, index) => total + digit * (index % 2 === 0 ? 3 : 1),
    0,
  );
  return (10 - (sum % 10)) % 10 === supplied ? canonical : null;
}
