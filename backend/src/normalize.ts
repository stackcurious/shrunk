// Mirror of scripts/fdc/normalize.py — both must pass fixtures/package_weights.json.
export type UnitKind = "mass" | "volume" | "count";
export interface ParsedQuantity { quantity: number; unitKind: UnitKind; raw: string }

const UNITS: Record<string, [UnitKind, number]> = {
  g: ["mass", 1], gr: ["mass", 1], gram: ["mass", 1], grams: ["mass", 1], grm: ["mass", 1],
  kg: ["mass", 1000], kgm: ["mass", 1000], kilogram: ["mass", 1000], kilograms: ["mass", 1000],
  oz: ["mass", 28.3495], onz: ["mass", 28.3495], ounce: ["mass", 28.3495], ounces: ["mass", 28.3495],
  lb: ["mass", 453.592], lbs: ["mass", 453.592], lbr: ["mass", 453.592], pound: ["mass", 453.592], pounds: ["mass", 453.592],
  ml: ["volume", 1], mlt: ["volume", 1], milliliter: ["volume", 1], milliliters: ["volume", 1], millilitre: ["volume", 1],
  l: ["volume", 1000], ltr: ["volume", 1000], liter: ["volume", 1000], liters: ["volume", 1000], litre: ["volume", 1000], litres: ["volume", 1000],
  floz: ["volume", 29.5735], oza: ["volume", 29.5735],
  pt: ["volume", 473.176], ptl: ["volume", 473.176], pint: ["volume", 473.176], pints: ["volume", 473.176],
  qt: ["volume", 946.353], qtl: ["volume", 946.353], quart: ["volume", 946.353], quarts: ["volume", 946.353],
  gal: ["volume", 3785.41], gll: ["volume", 3785.41], gallon: ["volume", 3785.41], gallons: ["volume", 3785.41],
  ct: ["count", 1], count: ["count", 1], pk: ["count", 1], pack: ["count", 1],
  ea: ["count", 1], each: ["count", 1], h87: ["count", 1], pc: ["count", 1], pcs: ["count", 1], piece: ["count", 1], pieces: ["count", 1],
};

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const UNIT_ALT = Object.keys(UNITS).sort((a, b) => b.length - a.length).map(esc).join("|");
const NUM = "(\\d+(?:[.,]\\d+)?)";
const MULTIPACK = new RegExp(`${NUM}\\s*(?:[-–x×*]|pk\\s+of|pack\\s+of)\\s*${NUM}\\s*(fl\\s?oz|${UNIT_ALT})\\b`);
const QTY_UNIT = new RegExp(`${NUM}\\s*(fl\\s?oz|${UNIT_ALT})\\b`, "g");
const SEGMENT_SPLIT = /\s*\/\s*|\s*\(|\)\s*/;
const TOLERANCE = 0.02;

// "1/2 Gallon" is a fraction; "12/12 fl oz" is a 12-pack of 12 fl oz. Only a
// proper fraction with a household denominator is expanded, and only when it
// leads the string — everything else stays a "/"-separated segment list.
const LEADING_FRACTION = /^\s*(\d+)\s*\/\s*(\d+)\s+([a-zA-Z].*)$/;
const FRACTION_DENOMINATORS = new Set([2, 3, 4, 8]);

// R45 — a bare integer segment ("12/12 fl oz") or a count-unit segment
// ("12 ct / 12 fl oz") that *leads* a "/"-separated list is a multipack
// count, not an independent quantity: Kroger's items[].size spells a 12-pack
// of 12 fl oz cans as "12/12 FL OZ", where the second segment is the size of
// *one* unit, not the pack total. The old code discarded the leading count
// (a bare "12" fails to parse at all; "12 ct" was filtered out by the
// count-vs-mass preference below) and returned the per-unit size as if it
// were the whole package — a silent 12x-too-small reading.
const BARE_COUNT = /^\d+(?:[.,]\d+)?$/;

function expandLeadingFraction(text: string): string {
  const match = LEADING_FRACTION.exec(text);
  if (!match) return text;
  const numerator = parseInt(match[1], 10);
  const denominator = parseInt(match[2], 10);
  if (!FRACTION_DENOMINATORS.has(denominator) || numerator === 0 || numerator >= denominator) return text;
  return `${numerator / denominator} ${match[3]}`;
}

const toFloat = (t: string) => parseFloat(t.replace(",", "."));
const unit = (t: string) => UNITS[t.toLowerCase().replace(/\s/g, "")];

function parseSegment(segment: string): [number, UnitKind] | null {
  const text = segment.toLowerCase().trim();
  if (!text) return null;

  const m = MULTIPACK.exec(text);
  if (m) {
    const [kind, factor] = unit(m[3]);
    const qty = toFloat(m[1]) * toFloat(m[2]) * factor;
    return qty > 0 ? [qty, kind] : null;
  }

  const matches = [...text.matchAll(QTY_UNIT)];
  if (matches.length === 0) return null;

  const [firstKind, firstFactor] = unit(matches[0][2]);
  let total = toFloat(matches[0][1]) * firstFactor;
  for (const extra of matches.slice(1)) {
    const [kind, factor] = unit(extra[2]);
    if (kind !== firstKind) break;
    total += toFloat(extra[1]) * factor;
  }
  return total > 0 ? [total, firstKind] : null;
}

/** The multiplier a leading segment contributes, or null if it isn't one. */
function leadingCountFactor(segment: string): number | null {
  const text = segment.trim();
  if (!text) return null;
  if (BARE_COUNT.test(text)) return toFloat(text);
  const parsed = parseSegment(text);
  return parsed && parsed[1] === "count" ? parsed[0] : null;
}

export function parsePackageWeight(raw: string | null | undefined): ParsedQuantity | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const text = expandLeadingFraction(trimmed);

  const rawSegments = text.split(SEGMENT_SPLIT);

  if (rawSegments.length > 1) {
    const factor = leadingCountFactor(rawSegments[0]);
    if (factor !== null && factor > 0) {
      // A leading count multiplies whichever per-unit size follows it — but
      // only a real one. If nothing after it parses to a mass/volume
      // quantity ("12/", a dangling "12 ct" with no size after it, or a
      // second count with no size at all), the count alone is not a package
      // weight — R45 says unparseable, not "12 of an unknown unit".
      const rest = rawSegments
        .slice(1)
        .map(parseSegment)
        .filter((p): p is [number, UnitKind] => p !== null);
      const perUnit = rest.filter((p) => p[1] !== "count");
      if (perUnit.length === 0) return null;

      const [unitQty, kind] = perUnit[0];
      for (const [otherQty, otherKind] of perUnit.slice(1)) {
        if (otherKind === kind && Math.abs(otherQty - unitQty) / unitQty > TOLERANCE) return null;
      }
      const total = unitQty * factor;
      return total > 0 ? { quantity: Math.round(total * 1000) / 1000, unitKind: kind, raw } : null;
    }
  }

  const parsed = rawSegments.map(parseSegment).filter((p): p is [number, UnitKind] => p !== null);
  if (parsed.length === 0) return null;

  const preferred = parsed.filter((p) => p[1] !== "count");
  const chosen = preferred.length > 0 ? preferred : parsed;
  const [qty, kind] = chosen[0];

  for (const [otherQty, otherKind] of chosen.slice(1)) {
    if (otherKind === kind && Math.abs(otherQty - qty) / qty > TOLERANCE) return null;
  }
  return { quantity: Math.round(qty * 1000) / 1000, unitKind: kind, raw };
}
