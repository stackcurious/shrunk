import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { canonicalCategory } from "../src/categories";

const DEVICE = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";

async function post(body: unknown) {
  return app.request(
    "/v1/devices",
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) },
    env
  );
}

async function watchRows() {
  const { results } = await env.DB
    .prepare("SELECT gtin, brand, alert_enabled FROM watches WHERE device_id = ? ORDER BY gtin")
    .bind(DEVICE)
    .all<{ gtin: string; brand: string | null; alert_enabled: number }>();
  return results;
}

beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM watches"), env.DB.prepare("DELETE FROM devices")]);
});

describe("canonicalCategory", () => {
  it("folds every spelling we emit onto one name", () => {
    expect(canonicalCategory("Drinks")).toBe("Beverages");
    expect(canonicalCategory("beverages")).toBe("Beverages");
    expect(canonicalCategory("Personal")).toBe("Personal care");
    expect(canonicalCategory("cosmetics")).toBe("Personal care");
    expect(canonicalCategory("Paper")).toBe("Paper products");
    expect(canonicalCategory("Dairies")).toBe("Dairy");
    expect(canonicalCategory("Snacks")).toBe("Snacks");
    expect(canonicalCategory("Condiments")).toBe("Condiments");
    expect(canonicalCategory("  sugar ")).toBe("Sugar");
    expect(canonicalCategory("")).toBeNull();
    expect(canonicalCategory(null)).toBeNull();
  });

  it("passes an unknown category through, trimmed", () => {
    expect(canonicalCategory(" Frozen ")).toBe("Frozen");
  });
});

describe("POST /v1/devices", () => {
  it("upserts the device and its watches, and reports pro:false", async () => {
    const res = await post({
      device_id: DEVICE,
      apns_token: "a1b2c3",
      location_id: "01400943",
      categories: ["Snacks", "Drinks"],
      prefs: { digest: false },
      watches: [
        { gtin: "028400642255", brand: "Gatorade", alert_enabled: true },
        { gtin: "0028400642262", brand: "Doritos", alert_enabled: false },
      ],
      transaction_jws: "aaa.bbb.ccc",
    });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, pro: false });

    const row = await env.DB
      .prepare("SELECT apns_token, location_id, categories, prefs, pro_until, transaction_jws FROM devices WHERE id = ?")
      .bind(DEVICE)
      .first<any>();
    expect(row.apns_token).toBe("a1b2c3");
    expect(row.location_id).toBe("01400943");
    expect(JSON.parse(row.categories)).toEqual(["Snacks", "Beverages"]);
    expect(JSON.parse(row.prefs)).toEqual({ digest: false });
    expect(row.pro_until).toBeNull();
    expect(row.transaction_jws).toBeNull();   // R34: verified-and-discarded, never persisted

    expect(await watchRows()).toEqual([
      { gtin: "0028400642255", brand: "Gatorade", alert_enabled: 1 },   // 12-digit UPC padded
      { gtin: "0028400642262", brand: "Doritos", alert_enabled: 0 },
    ]);
  });

  it("replaces the watch set on the next sync", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255", brand: "Gatorade" }] });
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642262", brand: "Doritos" }] });
    expect((await watchRows()).map((w) => w.gtin)).toEqual(["0028400642262"]);
  });

  it("leaves the watch set alone when the key is absent, and clears it on []", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255", brand: "Gatorade" }] });

    await post({ device_id: DEVICE, transaction_jws: "aaa.bbb.ccc" });   // the Phase 5 two-field call
    expect((await watchRows()).map((w) => w.gtin)).toEqual(["0028400642255"]);

    await post({ device_id: DEVICE, watches: [] });
    expect(await watchRows()).toEqual([]);
  });

  it("defaults alert_enabled to 1 and drops unparseable gtins", async () => {
    await post({ device_id: DEVICE, watches: [{ gtin: "0028400642255" }, { gtin: "12345" }, { gtin: null }] });
    expect(await watchRows()).toEqual([{ gtin: "0028400642255", brand: null, alert_enabled: 1 }]);
  });

  it("reports pro:true when pro_until is in the future", async () => {
    await post({ device_id: DEVICE });
    await env.DB.prepare("UPDATE devices SET pro_until = ? WHERE id = ?")
      .bind(Math.floor(Date.now() / 1000) + 86400, DEVICE)
      .run();
    const res = await post({ device_id: DEVICE, apns_token: "a1b2c3" });
    expect(await res.json()).toEqual({ ok: true, pro: true });
  });

  it("reports pro:false when pro_until has passed", async () => {
    await post({ device_id: DEVICE });
    await env.DB.prepare("UPDATE devices SET pro_until = 1 WHERE id = ?").bind(DEVICE).run();
    expect(await (await post({ device_id: DEVICE })).json()).toEqual({ ok: true, pro: false });
  });

  it("rejects a device id that is not a UUID", async () => {
    const res = await post({ device_id: "not-a-uuid" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_device_id" });
  });

  it("rejects a body that is not JSON", async () => {
    const res = await app.request("/v1/devices", { method: "POST", body: "{" }, env);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_json" });
  });

  it("rejects more than 500 watches", async () => {
    const watches = Array.from({ length: 501 }, (_, i) => ({ gtin: `002840064${String(i).padStart(4, "0")}` }));
    const res = await post({ device_id: DEVICE, watches });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "too_many_watches" });
    expect(await watchRows()).toEqual([]);
  });
});
