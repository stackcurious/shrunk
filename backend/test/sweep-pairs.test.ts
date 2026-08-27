import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { runKrogerSweep } from "../src/sweep";
import type { KrogerClient } from "../src/kroger/client";
import type { Env } from "../src/env";

// Both are 13-digit GTINs that Phase 3's `krogerProductId` converts cleanly —
// the sweep silently drops any it cannot convert, which would mask a bug here.
const GTIN_WATCHED = "0028400642255";
const GTIN_SNAPSHOT = "0028400642262";
const LOCATION = "01400943";
const OTHER_LOCATION = "09999999";

interface Batch { ids: string[]; locationId: string }

/** A KrogerClient that answers every batch with no products and records the call. */
function fakeClient(): { client: KrogerClient; batches: Batch[] } {
  const batches: Batch[] = [];
  const client = {
    async products(ids: string[], locationId: string) {
      batches.push({ ids, locationId });
      return { data: [] };
    },
  } as unknown as KrogerClient;
  return { client, batches };
}

const on = () => ({ ...env, KROGER_PERSIST: "on" }) as Env;

async function seedDevice(id: string, locationId: string | null) {
  await env.DB.prepare(
    "INSERT INTO devices (id, apns_token, location_id, categories, prefs, pro_until, app_account_token, transaction_jws, updated_at) VALUES (?, 'tok', ?, NULL, NULL, NULL, NULL, NULL, 1)"
  ).bind(id, locationId).run();
}

async function seedWatch(deviceId: string, gtin: string, alertEnabled: number = 1) {
  await env.DB.prepare("INSERT INTO watches (device_id, gtin, brand, alert_enabled) VALUES (?, ?, 'Gatorade', ?)")
    .bind(deviceId, gtin, alertEnabled)
    .run();
}

async function seedSnapshot(gtin: string, locationId: string) {
  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, 2.0, '32 fl oz', 'HIGH', 1700000000)"
  ).bind(gtin, locationId).run();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM watches"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM alert_jobs"),
  ]);
});

describe("runKrogerSweep pair selection", () => {
  it("sweeps a watched product at the watcher's store", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);

    const { client, batches } = fakeClient();
    const result = await runKrogerSweep(on(), client);

    expect(result.pairs).toBe(1);
    expect(batches).toHaveLength(1);
    expect(batches[0].locationId).toBe(LOCATION);
    expect(batches[0].ids).toHaveLength(1);
  });

  it("ignores a watcher with no store set", async () => {
    await seedDevice("dev-1", null);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", "");
    await seedWatch("dev-2", GTIN_WATCHED);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(0);
    expect(batches).toHaveLength(0);
  });

  it("keeps sweeping pairs we already hold snapshots for", async () => {
    await seedSnapshot(GTIN_SNAPSHOT, LOCATION);
    const { client } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(1);
  });

  it("counts a pair once when it is both watched and snapshotted", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", LOCATION);
    await seedWatch("dev-2", GTIN_WATCHED);
    await seedSnapshot(GTIN_WATCHED, LOCATION);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(1);
    expect(batches[0].ids).toHaveLength(1);
  });

  it("groups by store", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    await seedDevice("dev-2", OTHER_LOCATION);
    await seedWatch("dev-2", GTIN_SNAPSHOT);

    const { client, batches } = fakeClient();
    expect((await runKrogerSweep(on(), client)).pairs).toBe(2);
    expect(new Set(batches.map((b) => b.locationId))).toEqual(new Set([LOCATION, OTHER_LOCATION]));
  });

  it("still does nothing when persistence is off", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED);
    const { client, batches } = fakeClient();
    expect(await runKrogerSweep(env, client)).toEqual({ pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0, failures: 0 });
    expect(batches).toHaveLength(0);
  });

  it("sweeps muted watches (alert_enabled = 0)", async () => {
    await seedDevice("dev-1", LOCATION);
    await seedWatch("dev-1", GTIN_WATCHED, 0);

    const { client, batches } = fakeClient();
    const result = await runKrogerSweep(on(), client);

    expect(result.pairs).toBe(1);
    expect(batches).toHaveLength(1);
    expect(batches[0].locationId).toBe(LOCATION);
    expect(batches[0].ids).toHaveLength(1);
  });
});
