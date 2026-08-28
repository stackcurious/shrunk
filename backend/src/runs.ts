/**
 * Size runs — spec §5.1.
 *
 * A verdict is never read off the last two *observations*. When a second
 * source reports exactly the size the previous observation already recorded,
 * that pair is `450 → 450`, `+0.0 %`, "Unchanged" — and a documented
 * `500 → 450` behind it is erased. Eight of the 25 verified curated entries
 * scored "no shrink" that way (`.curated-verify-report.md` §5); Fage is the
 * starkest, because USDA independently confirms *both* of its endpoints and
 * the product still read as never having shrunk.
 *
 * So consecutive same-kind observations that agree within `SAME_SIZE_TOLERANCE`
 * are first collapsed into one run, and the verdict compares the last two runs.
 *
 * Parity: `Shrunk/Services/ShrinkDetector.swift` (`collapseRuns`) and
 * `scripts/hit_rate.py` (`collapse_runs`) implement the same rule and must
 * stay in step with this file.
 */

/** Spec §5.1 — two observations that normalize within 1% are the same size. */
export const SAME_SIZE_TOLERANCE = 0.01;

export interface RunObservation {
  quantity: number;
  observed_at: number;
  source: string;
}

export interface SizeRun {
  /** The value that opened the run — the run's size. */
  quantity: number;
  /** The source that opened the run, i.e. the one `quantity` came from. */
  source: string;
  /** `observed_at` of the observation that opened the run. */
  opened_at: number;
  /** `observed_at` of the run's most recent observation. */
  observed_at: number;
  /** Every source that reported this size, in the order they first did. */
  sources: string[];
}

/**
 * Within `SAME_SIZE_TOLERANCE` of `reference`. A zero (or negative) reference
 * has no meaningful percentage, so only an exact match counts — which keeps a
 * `0 → 28` history two runs rather than one.
 */
function isSameSize(reference: number, quantity: number): boolean {
  if (reference <= 0) return quantity === reference;
  return Math.abs(quantity - reference) / reference <= SAME_SIZE_TOLERANCE;
}

/**
 * Collapses same-kind observations — **already sorted oldest first**, and
 * already normalized to the kind's base unit — into size runs.
 *
 * Each observation is compared against the quantity that *opened* the current
 * run rather than against its immediate predecessor, so a slow drift of
 * within-tolerance steps can never accumulate into one run spanning a real
 * change.
 */
export function collapseRuns(observations: RunObservation[]): SizeRun[] {
  const runs: SizeRun[] = [];
  for (const observation of observations) {
    const run = runs[runs.length - 1];
    if (run && isSameSize(run.quantity, observation.quantity)) {
      run.observed_at = observation.observed_at;
      if (!run.sources.includes(observation.source)) run.sources.push(observation.source);
    } else {
      runs.push({
        quantity: observation.quantity,
        source: observation.source,
        opened_at: observation.observed_at,
        observed_at: observation.observed_at,
        sources: [observation.source],
      });
    }
  }
  return runs;
}
