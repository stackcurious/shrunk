import { canonicalCategory } from "./categories";
import { runPairEndingAt } from "./db";
import type { Env } from "./env";
import { normalizeGTIN } from "./gtin";
import { parsePackageWeight } from "./normalize";
import catalogue from "./data/trending.json";

/** Spec §6.1 — the feed shows the last 30 days of accepted observations. */
export const FEED_WINDOW_SECONDS = 30 * 24 * 60 * 60;
/** Spec §5.1 — inside 1% is the same size, so it is not a shrink. */
const SHRINK_TOLERANCE = 0.01;
/**
 * C2 parity with `ShrinkDetector.analyze` (Shrunk/Services/ShrinkDetector.swift):
 * a single-step drop to under a quarter of the previous size is far more likely
 * a unit-parsing mismatch between two sources — a per-unit size read against a
 * multipack total, or a garbled vendor size string — than a real shrink.
 *
 * The app already refuses to render a verdict for such a pair. `/v1/feed` did
 * not, and it is the more consequential of the two: it is what publishes a
 * "verified" shrink card to every Browse tab. Found on 2026-08-27, when the
 * feed was advertising `0044000060251` (OREO Double Stuf Family Size) as
 * "530 g → 31.5 g, −94.1 %" because Kroger's own product record gives that
 * pack's size as "1.11 oz". Nothing shrinks by 94 % — publishing it as a
 * verified case is exactly the kind of unearned claim the curated audit was
 * about.
 *
 * Curated entries are deliberately exempt (see `curatedItems`): they are
 * same-source, hand-checked pairs with a citation, and a real documented
 * collapse should still be publishable.
 */
const IMPLAUSIBLE_SHRINK_RATIO = 0.25;
const OBSERVATION_LIMIT = 200;

export interface FeedItem {
  gtin: string;
  name: string;
  brand: string;
  category: string;
  previous_quantity: number;
  current_quantity: number;
  unit_kind: string;
  shrink_percent: number;
  observed_at: number;
  source: string;
}

export interface FeedResponse {
  updated: number;
  items: FeedItem[];
}

interface CuratedEntry {
  barcode: string;
  name: string;
  brand: string;
  category: string;
  history: { date: string; quantity: number; unit: string }[];
}

const CURATED = (catalogue as unknown as { trending: CuratedEntry[] }).trending;

const round1 = (n: number) => Math.round(n * 10) / 10;

/** The verified cases shipped in `data/trending.json`, as feed items. */
export function curatedItems(): FeedItem[] {
  const items: FeedItem[] = [];
  for (const entry of CURATED) {
    const gtin = normalizeGTIN(entry.barcode);
    const history = entry.history ?? [];
    if (!gtin || history.length < 2) continue;

    const before = parsePackageWeight(`${history[history.length - 2].quantity} ${history[history.length - 2].unit}`);
    const after = parsePackageWeight(`${history[history.length - 1].quantity} ${history[history.length - 1].unit}`);
    if (!before || !after || before.unitKind !== after.unitKind || before.quantity <= 0) continue;
    if ((before.quantity - after.quantity) / before.quantity <= SHRINK_TOLERANCE) continue;

    const observedAt = Date.parse(`${history[history.length - 1].date}T00:00:00Z`);
    if (Number.isNaN(observedAt)) continue;

    items.push({
      gtin,
      name: entry.name,
      brand: entry.brand,
      category: canonicalCategory(entry.category) ?? "",
      previous_quantity: before.quantity,
      current_quantity: after.quantity,
      unit_kind: after.unitKind,
      shrink_percent: round1(((after.quantity - before.quantity) / before.quantity) * 100),
      observed_at: Math.floor(observedAt / 1000),
      source: "curated",
    });
  }
  return items;
}

interface ObservationRow {
  id: number;
  gtin: string;
  quantity: number;
  unit_kind: string;
  observed_at: number;
  source: string;
  name: string;
  brand: string;
  category: string;
}

/**
 * Spec §6.1 — curated catalogue plus every accepted crowd/Kroger observation
 * from the last 30 days that is actually smaller than the one before it.
 * Database rows win over curated rows for the same product: they are fresher.
 */
export async function buildFeed(env: Env, category: string | null, now: number): Promise<FeedResponse> {
  const { results } = await env.DB
    .prepare(
      `SELECT o.id AS id, o.gtin AS gtin, o.quantity AS quantity, o.unit_kind AS unit_kind,
              o.observed_at AS observed_at, o.source AS source,
              p.name AS name, p.brand AS brand, p.category AS category
       FROM observations o JOIN products p ON p.gtin = o.gtin
       WHERE o.status = 'accepted' AND o.source IN ('crowd','kroger') AND o.created_at >= ?
       ORDER BY o.observed_at DESC, o.id DESC
       LIMIT ?`
    )
    .bind(now - FEED_WINDOW_SECONDS, OBSERVATION_LIMIT)
    .all<ObservationRow>();

  const byGtin = new Map<string, FeedItem>();

  for (const row of results) {
    if (byGtin.has(row.gtin)) continue;   // newest row per product wins
    // Spec §5.1 — the last two size *runs*, so a second source confirming the
    // new size cannot flatten the pair to +0.0% and unpublish a real shrink.
    const pair = await runPairEndingAt(env.DB, row.gtin, row.unit_kind, row.observed_at, row.id);
    if (pair === null || pair.previous <= 0) continue;
    if ((pair.previous - pair.current) / pair.previous <= SHRINK_TOLERANCE) continue;
    if (pair.current / pair.previous < IMPLAUSIBLE_SHRINK_RATIO) continue;

    byGtin.set(row.gtin, {
      gtin: row.gtin,
      name: row.name,
      brand: row.brand,
      category: canonicalCategory(row.category) ?? "",
      previous_quantity: pair.previous,
      current_quantity: pair.current,
      unit_kind: row.unit_kind,
      shrink_percent: round1(((pair.current - pair.previous) / pair.previous) * 100),
      // When the smaller size was first seen, not when it was last confirmed —
      // a re-read of an unchanged package must not re-date the card to today.
      observed_at: pair.currentOpenedAt,
      source: row.source,
    });
  }

  for (const item of curatedItems()) {
    if (!byGtin.has(item.gtin)) byGtin.set(item.gtin, item);
  }

  const wanted = canonicalCategory(category);
  const items = [...byGtin.values()]
    .filter((item) => !wanted || item.category === wanted)
    .sort((a, b) => b.observed_at - a.observed_at);

  return { updated: items.reduce((max, item) => Math.max(max, item.observed_at), 0), items };
}
