import type { UnitKind } from "./normalize";

const VALID_KINDS: string[] = ["mass", "volume", "count"] satisfies UnitKind[];

export interface GateInput {
  /** Normalized quantity the device parsed (grams / millilitres / count). */
  quantity: number;
  unitKind: string;
  /** Vision's confidence for the line the quantity came from, 0..1. */
  ocrConfidence: number;
  /** The product's dominant kind, or null when we have never established one. */
  productUnitKind: string | null;
  /** Latest accepted observation of the same kind, or null when there is none. */
  latestAcceptedQuantity: number | null;
}

export interface GateResult {
  confidence: number;
  status: "pending";
  components: { parsed: number; kindMatch: number; range: number; ocr: number };
}

/**
 * Spec §6.3:
 *   0.5 parsed + 0.2 kind matches dominant + 0.2 within 0.5x-1.5x of the latest
 *   accepted observation + 0.1 OCR confidence >= 0.9.
 *
 * Always recomputed server-side — the device's own score is advisory only.
 * A score describes plausibility and review priority only. Crowd claims
 * always remain pending until a human verifies the stored label photo.
 */
export function scoreSubmission(input: GateInput): GateResult {
  const parsed =
    Number.isFinite(input.quantity) && input.quantity > 0 && VALID_KINDS.includes(input.unitKind)
      ? 0.5
      : 0;

  const kindMatch = input.productUnitKind !== null && input.productUnitKind === input.unitKind ? 0.2 : 0;

  const latest = input.latestAcceptedQuantity;
  const range =
    latest !== null && latest > 0 && input.quantity >= latest * 0.5 && input.quantity <= latest * 1.5
      ? 0.2
      : 0;

  const ocr = Number.isFinite(input.ocrConfidence) && input.ocrConfidence >= 0.9 ? 0.1 : 0;

  // 0.5 + 0.2 + 0.1 evaluates to 0.7999999999999999 in IEEE-754 doubles, which
  // would fail a bare `>= 0.8`. Round to cents before comparing or reporting.
  const confidence = Math.round((parsed + kindMatch + range + ocr) * 100) / 100;

  return {
    confidence,
    status: "pending",
    components: { parsed, kindMatch, range, ocr },
  };
}
