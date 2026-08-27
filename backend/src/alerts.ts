import type { Env } from "./env";
import { pushSender } from "./push";
import type { PushPayload, PushSender } from "./push/PushSender";

/** Spec §6.2 — at most 40 pushes per five-minute invocation. */
export const MAX_PUSHES_PER_RUN = 40;
/** How many unsent jobs one run will even look at. */
const JOB_SCAN_LIMIT = 50;

export interface AlertJobRow {
  id: number;
  kind: string;
  gtin: string | null;
  brand: string | null;
  location_id: string | null;
  payload: string | null;
  sent_count: number;
}

export interface DrainResult {
  jobs: number;
  pushes: number;
  cleared: number;
  /**
   * C1 — count of failures the run survived: a per-device `send` that threw
   * (e.g. `APNS_KEY_P8` unset), or a per-job body (recipient/product query,
   * bookkeeping `UPDATE`) that threw. Either way the run continues past it.
   */
  failures: number;
}

interface RecipientRow {
  id: string;
  apns_token: string;
  prefs: string | null;
}

/** D1 alert_jobs.kind (snake) -> the app's per-kind toggle (camel). */
const PREF_KEY: Record<string, string> = {
  size_drop: "sizeDrop",
  price_hike: "priceHike",
  verified_case: "verifiedCase",
  digest: "digest",
};

/** D1 alert_jobs.kind -> the wire `kind` the app maps onto ShrinkAlert.Kind. */
const WIRE_KIND: Record<string, string> = {
  size_drop: "sizeDrop",
  price_hike: "priceHike",
  verified_case: "verifiedCase",
  digest: "digest",
};

/** A missing or unparseable prefs blob means every kind is on. */
export function prefAllows(prefsJSON: string | null, kind: string): boolean {
  const key = PREF_KEY[kind];
  if (!key || !prefsJSON) return true;
  try {
    const prefs = JSON.parse(prefsJSON) as Record<string, unknown>;
    return prefs[key] !== false;
  } catch {
    return true;
  }
}

function parsePayload(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function sizeDropBody(p: Record<string, unknown>): string {
  const previousSize = typeof p.previous_size === "string" ? p.previous_size : null;
  const size = typeof p.size === "string" ? p.size : null;
  if (previousSize && size) return `Now ${size} — was ${previousSize}. Tap to see the history.`;
  const percent = typeof p.percent_change === "number" ? p.percent_change : null;
  if (percent !== null) return `Down ${Math.abs(percent).toFixed(1)}% since the last size we saw. Tap to see the history.`;
  return "A smaller size was just observed. Tap to see the history.";
}

function priceHikeBody(p: Record<string, unknown>): string {
  const before = typeof p.previous_per_unit === "number" ? p.previous_per_unit : null;
  const after = typeof p.per_unit === "number" ? p.per_unit : null;
  if (before !== null && after !== null && before > 0) {
    const percent = ((after - before) / before) * 100;
    return `Now $${after.toFixed(2)} per unit at your store — was $${before.toFixed(2)} (+${percent.toFixed(1)}%).`;
  }
  return "The price per unit went up at your store. Tap to see the details.";
}

/** The push a job turns into. Copy lives here so it is testable without a network. */
export function alertCopy(job: AlertJobRow, product: { name: string; brand: string } | null): PushPayload {
  const payload = parsePayload(job.payload);
  const label = product?.name?.trim() || job.brand?.trim() || "A watched product";
  const kind = WIRE_KIND[job.kind] ?? job.kind;
  const collapseId = `${job.kind}:${job.gtin ?? job.brand ?? "all"}`;
  const gtin = job.gtin ?? undefined;

  switch (job.kind) {
    case "size_drop":
      return { title: `${label} just shrank`, body: sizeDropBody(payload), gtin, kind, collapseId, productName: label };
    case "price_hike":
      return { title: `${label} costs more per unit`, body: priceHikeBody(payload), gtin, kind, collapseId, productName: label };
    case "verified_case":
      return {
        title: `New verified case: ${label}`,
        body: "We just published a confirmed shrink for this one. Tap to see the evidence.",
        gtin,
        kind,
        collapseId,
        productName: label,
      };
    default:
      return { title: `Update on ${label}`, body: "Tap to see what changed.", gtin, kind, collapseId, productName: label };
  }
}

/**
 * The devices that should receive this job, ordered so `OFFSET` is a stable
 * resume cursor. Spec §6.2: Pro only, alerts enabled, token present.
 */
async function recipientsFor(env: Env, job: AlertJobRow, now: number, limit: number, offset: number): Promise<RecipientRow[]> {
  const clauses = ["w.alert_enabled = 1", "d.apns_token IS NOT NULL", "d.pro_until IS NOT NULL", "d.pro_until > ?"];
  const binds: unknown[] = [now];

  if (job.kind === "verified_case" && job.brand) {
    // Spec §3: a verified case for a watched product **or brand**.
    clauses.push("(w.gtin = ? OR (w.brand IS NOT NULL AND lower(w.brand) = lower(?)))");
    binds.push(job.gtin ?? "", job.brand);
  } else {
    if (!job.gtin) return [];
    clauses.push("w.gtin = ?");
    binds.push(job.gtin);
  }

  if (job.kind === "price_hike" && job.location_id) {
    // A per-unit price is store-specific; only that store's shoppers care.
    clauses.push("d.location_id = ?");
    binds.push(job.location_id);
  }

  binds.push(limit, offset);
  const { results } = await env.DB
    .prepare(
      `SELECT d.id AS id, d.apns_token AS apns_token, d.prefs AS prefs
       FROM watches w JOIN devices d ON d.id = w.device_id
       WHERE ${clauses.join(" AND ")}
       GROUP BY d.id
       ORDER BY d.id
       LIMIT ? OFFSET ?`
    )
    .bind(...binds)
    .all<RecipientRow>();
  return results;
}

/**
 * Spec §6.2 — every five minutes, turn unsent `alert_jobs` rows into pushes.
 * A job larger than the per-run budget keeps its `sent_at` NULL and resumes
 * from `sent_count` (an `OFFSET` into `recipientsFor`'s deterministic
 * ordering) next time. That guarantee — nobody pushed twice, nobody dropped —
 * holds only while the job's recipient set (watches joined with devices,
 * filtered by Pro/alert_enabled/token) is stable across the runs it spans; if
 * a device starts/stops watching, toggles `alert_enabled`, or its Pro window
 * starts/expires between two runs of the same large job, the `OFFSET` can
 * skip or double-push devices whose position shifted. Not a concern for the
 * common case (a job finishes within one run's 40-push budget).
 */
export async function runAlertDrain(
  env: Env,
  sender: PushSender = pushSender(env),
  now: number = Math.floor(Date.now() / 1000)
): Promise<DrainResult> {
  const result: DrainResult = { jobs: 0, pushes: 0, cleared: 0, failures: 0 };
  let budget = MAX_PUSHES_PER_RUN;
  // I3 — count only, never logged with a device id or token; see the
  // badDeviceToken handling below.
  let badDeviceTokenCount = 0;

  const { results: jobs } = await env.DB
    .prepare(
      "SELECT id, kind, gtin, brand, location_id, payload, sent_count FROM alert_jobs WHERE sent_at IS NULL ORDER BY created_at ASC, id ASC LIMIT ?"
    )
    .bind(JOB_SCAN_LIMIT)
    .all<AlertJobRow>();

  for (const job of jobs) {
    if (budget <= 0) break;
    result.jobs += 1;

    try {
      const limit = budget;
      const recipients = await recipientsFor(env, job, now, limit, job.sent_count);

      const product = job.gtin
        ? await env.DB.prepare("SELECT name, brand FROM products WHERE gtin = ?").bind(job.gtin).first<{ name: string; brand: string }>()
        : null;
      const payload = alertCopy(job, product);

      for (const device of recipients) {
        if (!prefAllows(device.prefs, job.kind)) continue;
        try {
          const sendResult = await sender.send(device.apns_token, payload);
          if (sendResult.ok) result.pushes += 1;
          if (sendResult.invalidToken) {
            await env.DB.prepare("UPDATE devices SET apns_token = NULL WHERE id = ?").bind(device.id).run();
            result.cleared += 1;
          } else if (sendResult.badDeviceToken) {
            // I3 — do NOT clear the token: 400 BadDeviceToken is also what an
            // APNS_ENV mismatch looks like. Counted as a failure and logged
            // (as a count, below) so an environment flip that starts
            // producing these is visible without wiping the fleet's tokens.
            result.failures += 1;
            badDeviceTokenCount += 1;
          }
        } catch {
          // C1 — one recipient's send rejecting (a missing/malformed
          // APNS_KEY_P8 secret, a transient KV/fetch fault, ...) must not
          // abort the job. `recipients.length` below still advances
          // `sent_count` past this recipient below, exactly as it already
          // does for a resolved `{ok:false}` (Minor #3) — a failed
          // recipient is skipped, not retried next run, so nobody is ever
          // pushed twice.
          result.failures += 1;
        }
      }

      const processed = job.sent_count + recipients.length;
      if (recipients.length < limit) {
        await env.DB.prepare("UPDATE alert_jobs SET sent_at = ?, sent_count = ? WHERE id = ?").bind(now, processed, job.id).run();
      } else {
        await env.DB.prepare("UPDATE alert_jobs SET sent_count = ? WHERE id = ?").bind(processed, job.id).run();
      }
      budget -= recipients.length;
    } catch {
      // C1 — a job whose recipient/product query or bookkeeping UPDATE
      // throws is skipped rather than aborting every job behind it in this
      // run. Nothing was persisted for this job (sent_at/sent_count
      // untouched), so it is retried whole on the next tick.
      result.failures += 1;
    }
  }

  if (badDeviceTokenCount > 0) {
    // No device id or token in the log — same policy as db.ts's
    // entitlement-write warning.
    console.warn(`alerts: APNs BadDeviceToken (token not cleared): ${badDeviceTokenCount}`);
  }

  return result;
}
