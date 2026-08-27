import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_PUSHES_PER_RUN, alertCopy, prefAllows, runAlertDrain } from "../src/alerts";
import type { PushPayload, PushResult, PushSender } from "../src/push/PushSender";

const NOW = 1800000000;
const PRO_UNTIL = NOW + 86400;
const GTIN = "0052000133417";
const LOCATION = "01400943";

function fakeSender(results: PushResult[] = []) {
  const sent: Array<{ token: string; payload: PushPayload }> = [];
  const sender: PushSender = {
    async send(token, payload) {
      sent.push({ token, payload });
      return results.shift() ?? { ok: true, status: 200, invalidToken: false };
    },
  };
  return { sender, sent };
}

async function seedDevice(
  id: string,
  opts: { token?: string | null; proUntil?: number | null; locationId?: string | null; prefs?: string | null } = {}
) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, ?, ?, NULL, ?, ?, NULL, NULL, ?)"
  )
    .bind(
      id,
      opts.token === undefined ? `token-${id}` : opts.token,
      opts.locationId === undefined ? LOCATION : opts.locationId,
      opts.prefs ?? null,
      opts.proUntil === undefined ? PRO_UNTIL : opts.proUntil,
      NOW
    )
    .run();
}

async function seedWatch(deviceId: string, gtin: string, brand: string | null, enabled = true) {
  await env.DB.prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, ?, ?)")
    .bind(deviceId, gtin, brand, enabled ? 1 : 0)
    .run();
}

async function seedJob(
  kind: string,
  opts: { gtin?: string | null; brand?: string | null; locationId?: string | null; payload?: unknown } = {}
): Promise<number> {
  const result = await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at, sent_count) VALUES (?, ?, ?, ?, ?, ?, NULL, 0)"
  )
    .bind(
      kind,
      opts.gtin === undefined ? GTIN : opts.gtin,
      opts.brand === undefined ? "Gatorade" : opts.brand,
      opts.locationId ?? null,
      JSON.stringify(opts.payload ?? { previous_size: "32 fl oz", size: "28 fl oz" }),
      NOW - 60
    )
    .run();
  return result.meta.last_row_id as number;
}

async function jobRow(id: number) {
  return env.DB.prepare("SELECT sent_at, sent_count FROM alert_jobs WHERE id = ?").bind(id).first<{ sent_at: number | null; sent_count: number }>();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM products"),
  ]);
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade Thirst Quencher', 'Gatorade', 'Beverages', NULL, 'volume', 1, 1)"
  ).bind(GTIN).run();
});

describe("prefAllows", () => {
  it("defaults to on and honours an explicit false", () => {
    expect(prefAllows(null, "size_drop")).toBe(true);
    expect(prefAllows("{}", "size_drop")).toBe(true);
    expect(prefAllows(JSON.stringify({ sizeDrop: false }), "size_drop")).toBe(false);
    expect(prefAllows(JSON.stringify({ sizeDrop: false }), "price_hike")).toBe(true);
    expect(prefAllows(JSON.stringify({ priceHike: false }), "price_hike")).toBe(false);
    expect(prefAllows(JSON.stringify({ verifiedCase: false }), "verified_case")).toBe(false);
    expect(prefAllows("not json", "size_drop")).toBe(true);
  });
});

describe("alertCopy", () => {
  const base = { id: 1, gtin: GTIN, brand: "Gatorade", location_id: null, sent_count: 0 };

  it("writes size-drop copy from the Kroger sweep payload", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", payload: JSON.stringify({ previous_size: "32 fl oz", size: "28 fl oz" }) },
      { name: "Gatorade Thirst Quencher", brand: "Gatorade" }
    );
    expect(payload).toEqual({
      title: "Gatorade Thirst Quencher just shrank",
      body: "Now 28 fl oz — was 32 fl oz. Tap to see the history.",
      gtin: GTIN,
      kind: "sizeDrop",
      collapseId: `size_drop:${GTIN}`,
    });
  });

  it("writes size-drop copy from the crowd payload", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", payload: JSON.stringify({ percent_change: -12.5, source: "crowd" }) },
      null
    );
    expect(payload.title).toBe("Gatorade just shrank");
    expect(payload.body).toBe("Down 12.5% since the last size we saw. Tap to see the history.");
    expect(payload.kind).toBe("sizeDrop");
  });

  it("writes price-hike copy with the percentage", () => {
    const payload = alertCopy(
      { ...base, kind: "price_hike", location_id: LOCATION, payload: JSON.stringify({ previous_per_unit: 2, per_unit: 2.1 }) },
      { name: "Gatorade Thirst Quencher", brand: "Gatorade" }
    );
    expect(payload.title).toBe("Gatorade Thirst Quencher costs more per unit");
    expect(payload.body).toBe("Now $2.10 per unit at your store — was $2.00 (+5.0%).");
    expect(payload.kind).toBe("priceHike");
  });

  it("writes verified-case copy", () => {
    const payload = alertCopy({ ...base, kind: "verified_case", payload: null }, null);
    expect(payload.title).toBe("New verified case: Gatorade");
    expect(payload.kind).toBe("verifiedCase");
    expect(payload.body).toBe("We just published a confirmed shrink for this one. Tap to see the evidence.");
  });

  it("falls back when there is no product and no brand", () => {
    const payload = alertCopy({ ...base, kind: "size_drop", brand: null, payload: null }, null);
    expect(payload.title).toBe("A watched product just shrank");
    expect(payload.body).toBe("A smaller size was just observed. Tap to see the history.");
  });
});

describe("runAlertDrain", () => {
  it("pushes a size drop to a Pro watcher and marks the job sent", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    const id = await seedJob("size_drop");

    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 1, cleared: 0 });

    expect(sent).toHaveLength(1);
    expect(sent[0].token).toBe("token-dev-1");
    expect(sent[0].payload.kind).toBe("sizeDrop");
    expect(sent[0].payload.gtin).toBe(GTIN);
    expect(await jobRow(id)).toEqual({ sent_at: NOW, sent_count: 1 });
  });

  it("never pushes twice for the same job", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    await seedJob("size_drop");

    const first = fakeSender();
    await runAlertDrain(env, first.sender, NOW);
    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 0, pushes: 0, cleared: 0 });
    expect(second.sent).toHaveLength(0);
  });

  it("skips devices that are not Pro, muted, tokenless, or opted out", async () => {
    await seedDevice("dev-pro");
    await seedWatch("dev-pro", GTIN, "Gatorade");
    await seedDevice("dev-free", { proUntil: null });
    await seedWatch("dev-free", GTIN, "Gatorade");
    await seedDevice("dev-expired", { proUntil: NOW - 1 });
    await seedWatch("dev-expired", GTIN, "Gatorade");
    await seedDevice("dev-muted");
    await seedWatch("dev-muted", GTIN, "Gatorade", false);
    await seedDevice("dev-notoken", { token: null });
    await seedWatch("dev-notoken", GTIN, "Gatorade");
    await seedDevice("dev-optout", { prefs: JSON.stringify({ sizeDrop: false }) });
    await seedWatch("dev-optout", GTIN, "Gatorade");
    await seedJob("size_drop");

    const { sender, sent } = fakeSender();
    const result = await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-pro"]);
    expect(result.pushes).toBe(1);
  });

  it("reaches a brand watcher for a verified case", async () => {
    await seedDevice("dev-brand");
    await seedWatch("dev-brand", "0099999999999", "gatorade");   // different product, same brand
    await seedDevice("dev-other");
    await seedWatch("dev-other", "0099999999998", "Doritos");
    await seedJob("verified_case");

    const { sender, sent } = fakeSender();
    await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-brand"]);
    expect(sent[0].payload.kind).toBe("verifiedCase");
  });

  it("sends a price hike only to devices at that store", async () => {
    await seedDevice("dev-here", { locationId: LOCATION });
    await seedWatch("dev-here", GTIN, "Gatorade");
    await seedDevice("dev-elsewhere", { locationId: "09999999" });
    await seedWatch("dev-elsewhere", GTIN, "Gatorade");
    await seedJob("price_hike", { locationId: LOCATION, payload: { previous_per_unit: 2, per_unit: 2.1 } });

    const { sender, sent } = fakeSender();
    await runAlertDrain(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-here"]);
  });

  it("clears a device token that APNs rejected", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    await seedJob("size_drop");

    const { sender } = fakeSender([{ ok: false, status: 410, invalidToken: true }]);
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 1 });

    const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
    expect(row!.apns_token).toBeNull();
  });

  it("caps a run at 40 pushes and resumes the job on the next run", async () => {
    for (let i = 0; i < 45; i++) {
      const id = `dev-${String(i).padStart(2, "0")}`;
      await seedDevice(id);
      await seedWatch(id, GTIN, "Gatorade");
    }
    const id = await seedJob("size_drop");

    const first = fakeSender();
    expect(await runAlertDrain(env, first.sender, NOW)).toEqual({ jobs: 1, pushes: MAX_PUSHES_PER_RUN, cleared: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: null, sent_count: 40 });

    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 1, pushes: 5, cleared: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: NOW + 300, sent_count: 45 });
    expect(new Set([...first.sent, ...second.sent].map((s) => s.token)).size).toBe(45);
  });

  it("marks a job with no recipients sent, without pushing", async () => {
    const id = await seedJob("size_drop");
    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 0 });
    expect(sent).toHaveLength(0);
    expect(await jobRow(id)).toEqual({ sent_at: NOW, sent_count: 0 });
  });
});
