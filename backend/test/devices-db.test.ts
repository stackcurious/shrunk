import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  getDevice,
  listWatches,
  previousAcceptedQuantity,
  replaceWatches,
  upsertDevice,
} from "../src/db";

const DEVICE = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";
const GTIN = "0028400642255";

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM products"),
  ]);
});

describe("device helpers", () => {
  it("inserts a device with a NULL pro_until", async () => {
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "aa11", location_id: "01400943", categories: ["Snacks"] }, 1700000000);
    const row = await getDevice(env.DB, DEVICE);
    expect(row).toMatchObject({ id: DEVICE, apns_token: "aa11", location_id: "01400943", pro_until: null });
    expect(JSON.parse(row!.categories!)).toEqual(["Snacks"]);
    expect(row!.prefs).toBeNull();
  });

  it("keeps columns the second upsert omits, and never touches pro_until", async () => {
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "aa11", location_id: "01400943", categories: ["Snacks"] }, 1700000000);
    await env.DB.prepare("UPDATE devices SET pro_until = 1800000000 WHERE id = ?").bind(DEVICE).run();

    await upsertDevice(env.DB, { id: DEVICE, apns_token: "bb22" }, 1700000900);

    const row = await getDevice(env.DB, DEVICE);
    expect(row).toMatchObject({
      apns_token: "bb22",            // updated
      location_id: "01400943",       // preserved
      pro_until: 1800000000,         // Phase 4 never writes this
    });
    expect(JSON.parse(row!.categories!)).toEqual(["Snacks"]);
    const updated = await env.DB.prepare("SELECT updated_at FROM devices WHERE id = ?").bind(DEVICE).first<{ updated_at: number }>();
    expect(updated!.updated_at).toBe(1700000900);
  });

  it("writes pro_until/app_account_token only when `verified` is passed, and COALESCE preserves them afterward", async () => {
    await upsertDevice(env.DB, { id: DEVICE }, 1700000000, { proUntil: 1900000000, appAccountToken: "abc-token" });
    expect(await getDevice(env.DB, DEVICE)).toMatchObject({ pro_until: 1900000000, app_account_token: "abc-token" });

    // A later sync with no verified entitlement (the default/omitted case) must not clear it.
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "zz99" }, 1700000900);
    expect(await getDevice(env.DB, DEVICE)).toMatchObject({
      apns_token: "zz99",
      pro_until: 1900000000,
      app_account_token: "abc-token",
    });
  });

  it("I3: an explicit empty location_id/categories clears the stored value; an absent key keeps it", async () => {
    await upsertDevice(env.DB, { id: DEVICE, location_id: "01400943", categories: ["Snacks"] }, 1700000000);
    let row = await getDevice(env.DB, DEVICE);
    expect(row!.location_id).toBe("01400943");
    expect(JSON.parse(row!.categories!)).toEqual(["Snacks"]);

    // Explicit clears (COALESCE only skips a real NULL — "" and "[]" are not NULL).
    await upsertDevice(env.DB, { id: DEVICE, location_id: "", categories: [] }, 1700000900);
    row = await getDevice(env.DB, DEVICE);
    expect(row!.location_id).toBe("");
    expect(row!.categories).toBe("[]");

    // A later upsert that omits both keys (undefined) must not resurrect them.
    await upsertDevice(env.DB, { id: DEVICE, apns_token: "zz99" }, 1700001800);
    row = await getDevice(env.DB, DEVICE);
    expect(row!.location_id).toBe("");
    expect(row!.categories).toBe("[]");
  });

  it("stores prefs as a JSON object", async () => {
    await upsertDevice(env.DB, { id: DEVICE, prefs: { sizeDrop: true, digest: false } }, 1700000000);
    expect(JSON.parse((await getDevice(env.DB, DEVICE))!.prefs!)).toEqual({ sizeDrop: true, digest: false });
  });

  it("returns null for an unknown device", async () => {
    expect(await getDevice(env.DB, "nope")).toBeNull();
  });

  it("replaces the whole watch set", async () => {
    await upsertDevice(env.DB, { id: DEVICE }, 1700000000);
    await replaceWatches(env.DB, DEVICE, [
      { gtin: GTIN, brand: "Gatorade", alert_enabled: true },
      { gtin: "0028400642262", brand: "Doritos", alert_enabled: false },
    ]);
    expect((await listWatches(env.DB, DEVICE)).map((w) => w.gtin)).toEqual([GTIN, "0028400642262"]);

    await replaceWatches(env.DB, DEVICE, [{ gtin: "0028400642262", brand: "Doritos", alert_enabled: true }]);
    const after = await listWatches(env.DB, DEVICE);
    expect(after).toEqual([{ gtin: "0028400642262", brand: "Doritos", alert_enabled: true }]);
  });

  it("clears the watch set when handed an empty array", async () => {
    await upsertDevice(env.DB, { id: DEVICE }, 1700000000);
    await replaceWatches(env.DB, DEVICE, [{ gtin: GTIN, brand: "Gatorade", alert_enabled: true }]);
    await replaceWatches(env.DB, DEVICE, []);
    expect(await listWatches(env.DB, DEVICE)).toEqual([]);
  });

  it("finds the newest accepted same-kind observation before a given one", async () => {
    await env.DB.prepare(
      "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'Gatorade', 'Beverages', NULL, 'volume', 1, 1)"
    ).bind(GTIN).run();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 946.353, 'volume', '32 fl oz', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 828.058, 'volume', '28 fl oz', 1625097600, 'kroger', '01400943', 0.8, 'accepted', 2)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 400, 'volume', 'bogus', 1650000000, 'crowd', 'sub-1', 0.5, 'pending', 3)").bind(GTIN),
      env.DB.prepare("INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, 340.194, 'mass', '12 oz', 1650000000, 'fdc', '2', 0.9, 'accepted', 4)").bind(GTIN),
    ]);
    const latest = await env.DB.prepare("SELECT id FROM observations WHERE observed_at = 1625097600").first<{ id: number }>();

    expect(await previousAcceptedQuantity(env.DB, GTIN, "volume", 1625097600, latest!.id)).toBe(946.353);
    expect(await previousAcceptedQuantity(env.DB, GTIN, "volume", 1517443200, 1)).toBeNull();
    expect(await previousAcceptedQuantity(env.DB, GTIN, "count", 1700000000, 999)).toBeNull();
  });
});
