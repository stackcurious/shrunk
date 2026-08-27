import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";

const AUTH = { Authorization: "Bearer test-secret" };

const DEVICE = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const OTHER_DEVICE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const GTIN_A = "0028400642255";
const GTIN_B = "0011110000003";

const PENDING_PHOTO_KEY = "submissions/sub-pending-1.jpg";
const OTHER_PHOTO_KEY = "submissions/sub-other-1.jpg";

async function photoKeys(): Promise<string[]> {
  return (await env.PHOTOS.list()).objects.map((o) => o.key);
}

async function seed() {
  await env.DB.batch([
    // The target device: two watches, one pending submission with a photo,
    // one already-reviewed (accepted) submission whose photo_key is already
    // NULL — mirroring what markSubmissionReviewed leaves behind.
    env.DB.prepare("INSERT INTO devices (id, updated_at) VALUES (?, 1)").bind(DEVICE),
    env.DB
      .prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, 'Gatorade', 1)")
      .bind(DEVICE, GTIN_A),
    env.DB
      .prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, 'Tide', 1)")
      .bind(DEVICE, GTIN_B),
    env.DB
      .prepare(
        "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES ('sub-pending-1', ?, ?, ?, 'NET WT 28 OZ', 793.786, 'mass', 'pending', 1, NULL)"
      )
      .bind(DEVICE, GTIN_A, PENDING_PHOTO_KEY),
    env.DB
      .prepare(
        "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES ('sub-accepted-1', ?, ?, NULL, 'NET WT 32 OZ', 907.184, 'mass', 'accepted', 1, 2)"
      )
      .bind(DEVICE, GTIN_A),

    // A second, unrelated device — must survive untouched.
    env.DB.prepare("INSERT INTO devices (id, updated_at) VALUES (?, 1)").bind(OTHER_DEVICE),
    env.DB
      .prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, 'Tide', 1)")
      .bind(OTHER_DEVICE, GTIN_B),
    env.DB
      .prepare(
        "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES ('sub-other-1', ?, ?, ?, 'NET WT 28 OZ', 793.786, 'mass', 'pending', 1, NULL)"
      )
      .bind(OTHER_DEVICE, GTIN_A, OTHER_PHOTO_KEY),
  ]);
  await env.PHOTOS.put(PENDING_PHOTO_KEY, new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
  await env.PHOTOS.put(OTHER_PHOTO_KEY, new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
}

function erase(id: string, headers: Record<string, string> = AUTH) {
  return app.request(`/v1/admin/devices/${id}/erase`, { method: "POST", headers }, env);
}

describe("POST /v1/admin/devices/:id/erase", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM watches"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM devices"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("rejects a missing or wrong bearer", async () => {
    await seed();

    const anonymous = await erase(DEVICE, {});
    expect(anonymous.status).toBe(401);
    expect(await anonymous.json()).toEqual({ error: "unauthorized" });

    const wrong = await erase(DEVICE, { Authorization: "Bearer nope" });
    expect(wrong.status).toBe(401);

    // Nothing was touched.
    const row = await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(DEVICE).first();
    expect(row).not.toBeNull();
  });

  it("400s a malformed device id", async () => {
    const res = await erase("not-a-uuid");
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("erases everything tied to the device, leaves other devices alone, and is case-insensitive on the id", async () => {
    await seed();

    // Call with an upper-cased id to prove the route lowercases before matching.
    const res = await erase(DEVICE.toUpperCase());
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      deleted: { devices: 1, watches: 2, submissions: 2, photos: 1 },
    });

    // Target device is gone entirely.
    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(DEVICE).first()).toBeNull();
    expect(
      (await env.DB.prepare("SELECT COUNT(*) AS n FROM watches WHERE device_id = ?").bind(DEVICE).first<{ n: number }>())!.n
    ).toBe(0);
    expect(
      (await env.DB.prepare("SELECT COUNT(*) AS n FROM submissions WHERE device_id = ?").bind(DEVICE).first<{ n: number }>())!.n
    ).toBe(0);
    expect(await env.PHOTOS.get(PENDING_PHOTO_KEY)).toBeNull();

    // observations/products/price_snapshots are never touched by this route
    // — nothing was seeded there for this test, so there is nothing to
    // assert beyond the fact eraseDevice never references those tables.

    // The other device's rows and photo are untouched.
    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(OTHER_DEVICE).first()).not.toBeNull();
    expect(
      (
        await env.DB.prepare("SELECT COUNT(*) AS n FROM watches WHERE device_id = ?").bind(OTHER_DEVICE).first<{ n: number }>()
      )!.n
    ).toBe(1);
    expect(
      (
        await env.DB
          .prepare("SELECT COUNT(*) AS n FROM submissions WHERE device_id = ?")
          .bind(OTHER_DEVICE)
          .first<{ n: number }>()
      )!.n
    ).toBe(1);
    expect(await env.PHOTOS.get(OTHER_PHOTO_KEY)).not.toBeNull();
  });

  it("is idempotent: a second call against the same id returns all zeros", async () => {
    await seed();
    await erase(DEVICE);

    const again = await erase(DEVICE);
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({
      ok: true,
      deleted: { devices: 0, watches: 0, submissions: 0, photos: 0 },
    });
  });
});

// R42 — eraseDevice matches with a plain `=` (no `lower()`), which is only
// correct once every stored device id is canonical. migrations/0005 backfills
// rows written before R40's canonicalization existed; this proves the two
// work together: an uppercase-cased "legacy" row, once the backfill runs,
// is found and erased by (either-cased) id like any other.
describe("R42 — migration 0005 backfill + erase", () => {
  const LEGACY_UPPER = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
  const LEGACY_LOWER = LEGACY_UPPER.toLowerCase();

  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM watches"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM devices"),
    ]);
  });

  /** Runs migration 0005's own queries directly, independent of the D1
   * migrations bookkeeping table — the test harness already applied it once
   * (against an empty database, before this test seeded anything), so this
   * re-runs the real backfill SQL against the "legacy" row seeded below,
   * simulating what happens when 0005 ships against a database that
   * predates R40. */
  async function runBackfillMigration() {
    const migration = env.TEST_MIGRATIONS.find((m) => m.name.includes("0005_lowercase_device_ids"));
    expect(migration, "migrations/0005_lowercase_device_ids.sql must exist").toBeTruthy();
    for (const query of migration!.queries) {
      await env.DB.prepare(query).run();
    }
  }

  it("normalizes an uppercase-cased legacy row to lowercase", async () => {
    // Seeded exactly as a pre-R40 write would have left it: device id,
    // watches.device_id, and submissions.device_id all uppercase.
    await env.DB.batch([
      env.DB.prepare("INSERT INTO devices (id, updated_at) VALUES (?, 1)").bind(LEGACY_UPPER),
      env.DB
        .prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, '0028400642255', 'Gatorade', 1)")
        .bind(LEGACY_UPPER),
      env.DB
        .prepare(
          "INSERT INTO submissions (id, device_id, gtin, photo_key, ocr_text, parsed_quantity, parsed_kind, status, created_at, reviewed_at) VALUES ('sub-legacy-1', ?, '0028400642255', NULL, 'NET WT 28 OZ', 793.786, 'mass', 'accepted', 1, 2)"
        )
        .bind(LEGACY_UPPER),
    ]);

    await runBackfillMigration();

    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(LEGACY_LOWER).first()).not.toBeNull();
    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(LEGACY_UPPER).first()).toBeNull();
    expect(
      (await env.DB.prepare("SELECT COUNT(*) AS n FROM watches WHERE device_id = ?").bind(LEGACY_LOWER).first<{ n: number }>())!
        .n
    ).toBe(1);
    expect(
      (
        await env.DB
          .prepare("SELECT COUNT(*) AS n FROM submissions WHERE device_id = ?")
          .bind(LEGACY_LOWER)
          .first<{ n: number }>()
      )!.n
    ).toBe(1);
  });

  it("re-running the backfill against an already-lowercase database is a no-op", async () => {
    await env.DB.prepare("INSERT INTO devices (id, updated_at) VALUES (?, 1)").bind(LEGACY_LOWER).run();
    await runBackfillMigration();
    await runBackfillMigration();   // idempotent
    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(LEGACY_LOWER).first()).not.toBeNull();
  });

  it("erase finds and deletes a legacy uppercase row once the backfill has run, by either case", async () => {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO devices (id, updated_at) VALUES (?, 1)").bind(LEGACY_UPPER),
      env.DB
        .prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, '0028400642255', 'Gatorade', 1)")
        .bind(LEGACY_UPPER),
    ]);
    await runBackfillMigration();

    const res = await erase(LEGACY_UPPER);   // the admin still has the id in its original casing
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, deleted: { devices: 1, watches: 1, submissions: 0, photos: 0 } });
    expect(await env.DB.prepare("SELECT id FROM devices WHERE id = ?").bind(LEGACY_LOWER).first()).toBeNull();
  });
});
