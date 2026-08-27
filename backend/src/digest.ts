import { canonicalCategory } from "./categories";
import { previousAcceptedQuantities } from "./db";
import type { Env } from "./env";
import { prefAllows } from "./alerts";
import { pushSender } from "./push";
import type { PushSender } from "./push/PushSender";

/** Spec §6.2 — "the last 7 days". */
export const DIGEST_WINDOW_SECONDS = 7 * 24 * 60 * 60;
/** Spec §5.1 — inside 1% is the same size. */
const SHRINK_TOLERANCE = 0.01;
const OBSERVATION_LIMIT = 500;
/** A hard ceiling, not a paging scheme: past 1000 Pro devices this needs paging. */
const DEVICE_LIMIT = 1000;

export interface DigestResult {
  counts: Record<string, number>;
  devices: number;
  pushes: number;
  cleared: number;
  /**
   * C1 — count of devices whose send (or the invalidToken clear) threw. The
   * digest is a single flat pass over devices with no job/resume concept
   * (unlike `alerts.ts`'s `sent_count`, nothing here is ever retried), so a
   * failed device just gets no digest this week rather than the whole run
   * aborting and every device behind it losing theirs too.
   */
  failures: number;
}

interface WeekObservation {
  id: number;
  gtin: string;
  quantity: number;
  unit_kind: string;
  observed_at: number;
  category: string | null;
}

/**
 * Distinct products per canonical category that shrank in the last seven days:
 * accepted crowd/Kroger observations smaller than the previous same-kind one
 * (same source restriction as `buildFeed` — `fdc` is bulk-import data, not a
 * "just happened" shrink), plus curated additions published as `verified_case`
 * jobs (spec §6.2).
 */
export async function weeklyCounts(env: Env, now: number): Promise<Map<string, number>> {
  const since = now - DIGEST_WINDOW_SECONDS;
  const byCategory = new Map<string, Set<string>>();
  const add = (category: string, gtin: string) => {
    const set = byCategory.get(category) ?? new Set<string>();
    set.add(gtin);
    byCategory.set(category, set);
  };

  const { results: observations } = await env.DB
    .prepare(
      `SELECT o.id AS id, o.gtin AS gtin, o.quantity AS quantity, o.unit_kind AS unit_kind,
              o.observed_at AS observed_at, p.category AS category
       FROM observations o JOIN products p ON p.gtin = o.gtin
       WHERE o.status = 'accepted' AND o.source IN ('crowd','kroger') AND o.created_at >= ?
       ORDER BY o.id DESC
       LIMIT ?`
    )
    .bind(since, OBSERVATION_LIMIT)
    .all<WeekObservation>();

  // I2 — one grouped query for every candidate's "previous quantity" instead
  // of one D1 round trip per observation row (up to OBSERVATION_LIMIT of them).
  const categorized = observations
    .map((row) => ({ row, category: canonicalCategory(row.category) }))
    .filter((entry): entry is { row: WeekObservation; category: string } => entry.category !== null);
  const previousByObservationId = await previousAcceptedQuantities(
    env.DB,
    categorized.map(({ row }) => ({ gtin: row.gtin, unitKind: row.unit_kind, observedAt: row.observed_at, id: row.id }))
  );

  for (const { row, category } of categorized) {
    const previous = previousByObservationId.get(row.id) ?? null;
    if (previous === null || previous <= 0) continue;
    if ((previous - row.quantity) / previous <= SHRINK_TOLERANCE) continue;
    add(category, row.gtin);
  }

  const { results: cases } = await env.DB
    .prepare(
      `SELECT j.gtin AS gtin, p.category AS category
       FROM alert_jobs j LEFT JOIN products p ON p.gtin = j.gtin
       WHERE j.kind = 'verified_case' AND j.created_at >= ?`
    )
    .bind(since)
    .all<{ gtin: string | null; category: string | null }>();

  for (const row of cases) {
    const category = canonicalCategory(row.category);
    if (!category || !row.gtin) continue;   // a brand-only case has no category to file under
    add(category, row.gtin);
  }

  return new Map([...byCategory].map(([category, gtins]) => [category, gtins.size]));
}

/** "3 new shrinks in Snacks, 1 in Dairy" (spec §6.2). */
export function digestBody(counts: Array<[string, number]>): string {
  return counts
    .map(([category, count], index) =>
      index === 0 ? `${count} new shrink${count === 1 ? "" : "s"} in ${category}` : `${count} in ${category}`
    )
    .join(", ");
}

function subscribedCategories(raw: string | null): string[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const out: string[] = [];
    for (const entry of parsed) {
      const name = canonicalCategory(typeof entry === "string" ? entry : null);
      if (name && !out.includes(name)) out.push(name);
    }
    return out;
  } catch {
    return [];
  }
}

/**
 * Monday 01:00 (spec §6.2): one push per Pro device that subscribes to a
 * category something shrank in. A device with no categories gets nothing.
 */
export async function runWeeklyDigest(
  env: Env,
  sender: PushSender = pushSender(env),
  now: number = Math.floor(Date.now() / 1000)
): Promise<DigestResult> {
  const counts = await weeklyCounts(env, now);
  const result: DigestResult = { counts: Object.fromEntries(counts), devices: 0, pushes: 0, cleared: 0, failures: 0 };
  if (counts.size === 0) return result;

  const { results: devices } = await env.DB
    .prepare(
      `SELECT id, apns_token, categories, prefs FROM devices
       WHERE apns_token IS NOT NULL AND pro_until IS NOT NULL AND pro_until > ?
       ORDER BY id LIMIT ?`
    )
    .bind(now, DEVICE_LIMIT)
    .all<{ id: string; apns_token: string; categories: string | null; prefs: string | null }>();

  for (const device of devices) {
    result.devices += 1;
    if (!prefAllows(device.prefs, "digest")) continue;

    const mine = subscribedCategories(device.categories)
      .map((category) => [category, counts.get(category) ?? 0] as [string, number])
      .filter(([, count]) => count > 0)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    if (mine.length === 0) continue;

    try {
      const sendResult = await sender.send(device.apns_token, {
        title: "What shrank this week",
        body: digestBody(mine),
        kind: "digest",
        collapseId: "digest",
      });
      if (sendResult.ok) result.pushes += 1;
      if (sendResult.invalidToken) {
        await env.DB.prepare("UPDATE devices SET apns_token = NULL WHERE id = ?").bind(device.id).run();
        result.cleared += 1;
      }
    } catch {
      // C1 — see DigestResult.failures: one device's send throwing must not
      // cost every device behind it that week's digest.
      result.failures += 1;
    }
  }

  return result;
}
