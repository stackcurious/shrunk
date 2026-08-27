import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { digestBody, runWeeklyDigest, weeklyCounts } from "../src/digest";
import type { PushPayload, PushResult, PushSender } from "../src/push/PushSender";

const NOW = 1800000000;
const DAY = 86400;
const PRO_UNTIL = NOW + DAY;

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

async function seedShrink(gtin: string, category: string, previous: number, current: number, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'P', 'B', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', 'old', ?, 'fdc', '1', 0.9, 'accepted', ?)"
  ).bind(gtin, previous, createdAt - 400 * DAY, createdAt - 400 * DAY).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', 'new', ?, 'crowd', 'sub-1', 0.9, 'accepted', ?)"
  ).bind(gtin, current, createdAt, createdAt).run();
}

async function seedVerifiedCase(gtin: string, category: string, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'P', 'B', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO alert_jobs (kind, gtin, brand, location_id, payload, created_at, sent_at, sent_count) VALUES ('verified_case', ?, 'B', NULL, '{}', ?, NULL, 0)"
  ).bind(gtin, createdAt).run();
}

async function seedDevice(
  id: string,
  categories: string[] | null,
  opts: { token?: string | null; proUntil?: number | null; prefs?: string | null } = {}
) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, ?, '01400943', ?, ?, ?, NULL, NULL, 1)"
  )
    .bind(
      id,
      opts.token === undefined ? `token-${id}` : opts.token,
      categories === null ? null : JSON.stringify(categories),
      opts.prefs ?? null,
      opts.proUntil === undefined ? PRO_UNTIL : opts.proUntil
    )
    .run();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM products"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM watches"),
  ]);
});

describe("digestBody", () => {
  it("spells the first category out and abbreviates the rest", () => {
    expect(digestBody([["Snacks", 3], ["Dairy", 1]])).toBe("3 new shrinks in Snacks, 1 in Dairy");
    expect(digestBody([["Dairy", 1]])).toBe("1 new shrink in Dairy");
  });
});

describe("weeklyCounts", () => {
  it("counts shrinks and verified cases per canonical category, once per product", async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000012", "snacks", 340, 300, NOW - 2 * DAY);
    await seedShrink("0000000000013", "Dairy", 946, 800, NOW - 3 * DAY);
    await seedVerifiedCase("0000000000014", "Drinks", NOW - DAY);
    await seedVerifiedCase("0000000000011", "Snacks", NOW - DAY);   // same product, already counted

    const counts = await weeklyCounts(env, NOW);
    expect(Object.fromEntries(counts)).toEqual({ Snacks: 2, Dairy: 1, Beverages: 1 });
  });

  it("ignores anything older than seven days, and anything that did not shrink", async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - 8 * DAY);
    await seedShrink("0000000000012", "Snacks", 340, 341, NOW - DAY);
    await seedVerifiedCase("0000000000013", "Snacks", NOW - 30 * DAY);
    expect(Object.fromEntries(await weeklyCounts(env, NOW))).toEqual({});
  });
});

describe("runWeeklyDigest", () => {
  beforeEach(async () => {
    await seedShrink("0000000000011", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000012", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000013", "Snacks", 340, 300, NOW - DAY);
    await seedShrink("0000000000014", "Dairy", 946, 800, NOW - DAY);
  });

  it("sends one push per Pro device summarising its categories", async () => {
    await seedDevice("dev-1", ["Snacks", "Dairy", "Paper products"]);
    const { sender, sent } = fakeSender();

    const result = await runWeeklyDigest(env, sender, NOW);
    expect(result).toMatchObject({ devices: 1, pushes: 1, cleared: 0 });
    expect(sent).toHaveLength(1);
    expect(sent[0].token).toBe("token-dev-1");
    expect(sent[0].payload).toEqual({
      title: "What shrank this week",
      body: "3 new shrinks in Snacks, 1 in Dairy",
      kind: "digest",
      collapseId: "digest",
    });
  });

  it("skips devices with no matching category, no categories, no token, no Pro, or digest off", async () => {
    await seedDevice("dev-match", ["Snacks"]);
    await seedDevice("dev-other", ["Cleaning"]);
    await seedDevice("dev-nocats", []);
    await seedDevice("dev-nullcats", null);
    await seedDevice("dev-notoken", ["Snacks"], { token: null });
    await seedDevice("dev-free", ["Snacks"], { proUntil: null });
    await seedDevice("dev-expired", ["Snacks"], { proUntil: NOW - 1 });
    await seedDevice("dev-optout", ["Snacks"], { prefs: JSON.stringify({ digest: false }) });

    const { sender, sent } = fakeSender();
    await runWeeklyDigest(env, sender, NOW);
    expect(sent.map((s) => s.token)).toEqual(["token-dev-match"]);
  });

  it("canonicalises the device's stored category names", async () => {
    await seedDevice("dev-1", ["Drinks", "Snacks"]);
    const { sender, sent } = fakeSender();
    await runWeeklyDigest(env, sender, NOW);
    expect(sent[0].payload.body).toBe("3 new shrinks in Snacks");
  });

  it("clears a token the push provider rejected", async () => {
    await seedDevice("dev-1", ["Snacks"]);
    const { sender } = fakeSender([{ ok: false, status: 410, invalidToken: true }]);
    const result = await runWeeklyDigest(env, sender, NOW);
    expect(result).toMatchObject({ pushes: 0, cleared: 1 });
    const row = await env.DB.prepare("SELECT apns_token FROM devices WHERE id = 'dev-1'").first<{ apns_token: string | null }>();
    expect(row!.apns_token).toBeNull();
  });

  it("sends nothing at all in a quiet week", async () => {
    await env.DB.prepare("DELETE FROM observations").run();
    await seedDevice("dev-1", ["Snacks"]);
    const { sender, sent } = fakeSender();
    expect(await runWeeklyDigest(env, sender, NOW)).toEqual({ counts: {}, devices: 0, pushes: 0, cleared: 0 });
    expect(sent).toHaveLength(0);
  });
});
