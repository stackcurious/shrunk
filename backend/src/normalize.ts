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

export function parsePackageWeight(raw: string | null | undefined): ParsedQuantity | null {
  if (!raw) return null;
  const text = raw.trim();
  if (!text) return null;

  const parsed = text.split(SEGMENT_SPLIT).map(parseSegment).filter((p): p is [number, UnitKind] => p !== null);
  if (parsed.length === 0) return null;

  const preferred = parsed.filter((p) => p[1] !== "count");
  const chosen = preferred.length > 0 ? preferred : parsed;
  const [qty, kind] = chosen[0];

  for (const [otherQty, otherKind] of chosen.slice(1)) {
    if (otherKind === kind && Math.abs(otherQty - qty) / qty > TOLERANCE) return null;
  }
  return { quantity: Math.round(qty * 1000) / 1000, unitKind: kind, raw };
}
