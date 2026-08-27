import { insertAlertJob, setProductUnitKindIfMissing } from "./db";

/**
 * Spec §5.1: two observations within 1% are the same size. A "size drop" has to
 * clear that band, otherwise OCR rounding noise would page every watcher.
 */
const SAME_SIZE_TOLERANCE = 0.01;

export interface AcceptanceInput {
  gtin: string;
  quantity: number;
  unitKind: string;
  /** Latest accepted same-kind quantity as it stood *before* this row was accepted. */
  previousQuantity: number | null;
  /** `observed_at` of that same incumbent row, or null when there is none. */
  previousObservedAt: number | null;
  /** `observed_at` of the row being accepted. */
  observedAt: number;
  brand: string | null;
  now: number;
}

/**
 * Everything that must happen when a crowd observation becomes `accepted`,
 * whether it cleared the gate on arrival or a reviewer approved it later.
 * Returns true when a size_drop alert job was queued.
 */
export async function finalizeAcceptance(db: D1Database, input: AcceptanceInput): Promise<boolean> {
  // A product first seen through a contribution has no dominant kind until now;
  // without this the §6.3 kind-match component could never fire for it.
  await setProductUnitKindIfMissing(db, input.gtin, input.unitKind, input.now);

  const previous = input.previousQuantity;
  if (previous === null || previous <= 0) return false;

  // I6: a row that sat pending can be accepted after a newer same-kind
  // observation has already landed and become the incumbent. Comparing the
  // stale row against that newer incumbent would describe a change that
  // isn't the product's current state — skip the alert rather than queue a
  // false size_drop a Pro user's cron push would surface.
  if (input.previousObservedAt !== null && input.previousObservedAt > input.observedAt) return false;

  if (input.quantity >= previous * (1 - SAME_SIZE_TOLERANCE)) return false;

  const percentChange = ((input.quantity - previous) / previous) * 100;
  await insertAlertJob(db, {
    kind: "size_drop",
    gtin: input.gtin,
    brand: input.brand,
    location_id: null,
    payload: JSON.stringify({
      gtin: input.gtin,
      unit_kind: input.unitKind,
      previous_quantity: previous,
      quantity: input.quantity,
      percent_change: Math.round(percentChange * 10) / 10,
      source: "crowd",
    }),
    created_at: input.now,
  });
  return true;
}
