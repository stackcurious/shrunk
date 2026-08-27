import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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
      productName: "Gatorade Thirst Quencher",
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

  it("includes productName from product.name when available", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", payload: JSON.stringify({ previous_size: "32 fl oz", size: "28 fl oz" }) },
      { name: "Gatorade Thirst Quencher", brand: "Gatorade" }
    );
    expect(payload.productName).toBe("Gatorade Thirst Quencher");
  });

  it("includes productName from brand when no product", () => {
    const payload = alertCopy(
      { ...base, kind: "size_drop", brand: "Doritos", payload: null },
      null
    );
    expect(payload.productName).toBe("Doritos");
  });

  it("includes productName in all alert kinds", () => {
    const product = { name: "Gatorade Thirst Quencher", brand: "Gatorade" };

    const sizeDrop = alertCopy({ ...base, kind: "size_drop", payload: JSON.stringify({ previous_size: "32 fl oz", size: "28 fl oz" }) }, product);
    expect(sizeDrop.productName).toBe("Gatorade Thirst Quencher");

    const priceHike = alertCopy({ ...base, kind: "price_hike", location_id: LOCATION, payload: JSON.stringify({ previous_per_unit: 2, per_unit: 2.1 }) }, product);
    expect(priceHike.productName).toBe("Gatorade Thirst Quencher");

    const verifiedCase = alertCopy({ ...base, kind: "verified_case", payload: null }, product);
    expect(verifiedCase.productName).toBe("Gatorade Thirst Quencher");

    const digest = alertCopy({ ...base, kind: "digest", payload: null }, product);
    expect(digest.productName).toBe("Gatorade Thirst Quencher");
  });
});

describe("runAlertDrain", () => {
  it("pushes a size drop to a Pro watcher and marks the job sent", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    const id = await seedJob("size_drop");

    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 1, cleared: 0, failures: 0 });

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
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 0, pushes: 0, cleared: 0, failures: 0 });
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
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 1, failures: 0 });

    const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
    expect(row!.apns_token).toBeNull();
  });

  describe("I3 — 400 BadDeviceToken is not a token wipe", () => {
    afterEach(() => vi.restoreAllMocks());

    it("does not clear the token on 400 BadDeviceToken, counts it as a failure, and logs the count", async () => {
      await seedDevice("dev-1");
      await seedWatch("dev-1", GTIN, "Gatorade");
      await seedJob("size_drop");
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

      const { sender } = fakeSender([{ ok: false, status: 400, invalidToken: false, badDeviceToken: true }]);
      expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 0, failures: 1 });

      const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
      expect(row!.apns_token).toBe("token-dev-1");

      expect(warn).toHaveBeenCalledTimes(1);
      const [message] = warn.mock.calls[0];
      expect(message).toContain("1");
      expect(message).not.toContain("dev-1");
      expect(message).not.toContain("token-dev-1");
    });
  });

  it("caps a run at 40 pushes and resumes the job on the next run", async () => {
    for (let i = 0; i < 45; i++) {
      const id = `dev-${String(i).padStart(2, "0")}`;
      await seedDevice(id);
      await seedWatch(id, GTIN, "Gatorade");
    }
    const id = await seedJob("size_drop");

    const first = fakeSender();
    expect(await runAlertDrain(env, first.sender, NOW)).toEqual({ jobs: 1, pushes: MAX_PUSHES_PER_RUN, cleared: 0, failures: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: null, sent_count: 40 });

    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 1, pushes: 5, cleared: 0, failures: 0 });
    expect(await jobRow(id)).toEqual({ sent_at: NOW + 300, sent_count: 45 });
    expect(new Set([...first.sent, ...second.sent].map((s) => s.token)).size).toBe(45);
  });

  it("marks a job with no recipients sent, without pushing", async () => {
    const id = await seedJob("size_drop");
    const { sender, sent } = fakeSender();
    expect(await runAlertDrain(env, sender, NOW)).toEqual({ jobs: 1, pushes: 0, cleared: 0, failures: 0 });
    expect(sent).toHaveLength(0);
    expect(await jobRow(id)).toEqual({ sent_at: NOW, sent_count: 0 });
  });
});

describe("C1 — per-send and per-job failure containment", () => {
  it("continues past a rejecting send, still reaches a later recipient and a second job, and counts the failure", async () => {
    await seedDevice("dev-1");
    await seedDevice("dev-2");
    await seedWatch("dev-1", GTIN, "Gatorade");
    await seedWatch("dev-2", GTIN, "Gatorade");
    const firstJob = await seedJob("size_drop");

    const otherGtin = "0099999999997";
    await env.DB.prepare(
      "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Other', 'Other', 'Snacks', NULL, 'mass', 1, 1)"
    ).bind(otherGtin).run();
    await seedDevice("dev-3");
    await seedWatch("dev-3", otherGtin, "Other");
    const secondJob = await seedJob("size_drop", { gtin: otherGtin, brand: "Other" });

    const sent: string[] = [];
    let calls = 0;
    const sender: PushSender = {
      async send(token) {
        calls += 1;
        if (calls === 1) throw new Error("boom: APNS_KEY_P8 not set");
        sent.push(token);
        return { ok: true, status: 200, invalidToken: false };
      },
    };

    const result = await runAlertDrain(env, sender, NOW);
    expect(result).toEqual({ jobs: 2, pushes: 2, cleared: 0, failures: 1 });
    // dev-1's send rejected; dev-2 (same job) and dev-3 (a second, unrelated
    // job) were still reached.
    expect(sent.sort()).toEqual(["token-dev-2", "token-dev-3"]);

    // sent_count advanced past the failed recipient (recipients.length still
    // includes dev-1), so a second run pushes nobody in either job again.
    expect(await jobRow(firstJob)).toEqual({ sent_at: NOW, sent_count: 2 });
    expect(await jobRow(secondJob)).toEqual({ sent_at: NOW, sent_count: 1 });

    const second = fakeSender();
    expect(await runAlertDrain(env, second.sender, NOW + 300)).toEqual({ jobs: 0, pushes: 0, cleared: 0, failures: 0 });
    expect(second.sent).toHaveLength(0);
  });

  it("skips a job whose body throws, without aborting jobs behind it", async () => {
    await seedDevice("dev-1");
    await seedWatch("dev-1", GTIN, "Gatorade");
    const badJob = await seedJob("size_drop");

    const otherGtin = "0099999999996";
    await env.DB.prepare(
      "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Other', 'Other', 'Snacks', NULL, 'mass', 1, 1)"
    ).bind(otherGtin).run();
    await seedDevice("dev-2");
    await seedWatch("dev-2", otherGtin, "Other");
    const goodJob = await seedJob("size_drop", { gtin: otherGtin, brand: "Other" });

    // Poison the product lookup for the FIRST job's gtin only, so its
    // per-job body throws before any send is even attempted.
    const poisoned = new Proxy(env.DB, {
      get(target: D1Database, prop: string | symbol, receiver: unknown) {
        if (prop === "prepare") {
          return (sql: string) => {
            const stmt = target.prepare(sql);
            if (!sql.includes("SELECT name, brand FROM products")) return stmt;
            return {
              bind: (...args: unknown[]) => {
                if (args[0] === GTIN) throw new Error("boom: simulated D1 read failure");
                return stmt.bind(...args);
              },
            } as unknown as D1PreparedStatement;
          };
        }
        return Reflect.get(target as object, prop, receiver as object);
      },
    }) as unknown as D1Database;

    const { sender, sent } = fakeSender();
    const result = await runAlertDrain({ ...env, DB: poisoned }, sender, NOW);
    expect(result).toEqual({ jobs: 2, pushes: 1, cleared: 0, failures: 1 });
    expect(sent.map((s) => s.token)).toEqual(["token-dev-2"]);
    // The bad job's row is untouched — nothing was persisted, so it is
    // retried whole on the next run.
    expect(await jobRow(badJob)).toEqual({ sent_at: null, sent_count: 0 });
  });
});
