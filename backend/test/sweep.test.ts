import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { runKrogerSweep } from "../src/sweep";
import worker from "../src/worker";

const TOKEN_BODY = { access_token: "tok-123", expires_in: 1800, token_type: "bearer" };
const GTIN = "0028400642255";
const LOCATION = "01400943";

function jsonResponse(body: unknown, status = 200, responseHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

function stubBatch(size: string, perUnit: number, regular = 4.0) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
      if (url.pathname === "/v1/products") {
        return jsonResponse({
          data: [
            {
              productId: "0002840064225",
              upc: "0002840064225",
              brand: "Gatorade",
              description: "Gatorade Thirst Quencher",
              categories: ["Beverages"],
              items: [{ size, price: { regular, promo: 0, regularPerUnitEstimate: perUnit }, inventory: { stockLevel: "HIGH" } }],
            },
          ],
        });
      }
      throw new Error(`unexpected fetch: ${url.pathname}${url.search}`);
    }),
  );
}

/** Seed the previous snapshot the sweep will compare against. */
async function seedSnapshot(sizeRaw: string, perUnit: number) {
  await env.DB.prepare("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
  await env.DB.prepare(
    "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, ?, ?, 'HIGH', 1700000000)",
  ).bind(GTIN, LOCATION, perUnit, sizeRaw).run();
}

const on = () => ({ ...env, KROGER_PERSIST: "on" as const });

beforeEach(async () => {
  await env.KV.delete("kroger:token");
  await env.DB.batch([
    env.DB.prepare("DELETE FROM alert_jobs"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM price_snapshots"),
    env.DB.prepare("DELETE FROM products"),
  ]);
});

afterEach(() => vi.unstubAllGlobals());

async function jobKinds(): Promise<string[]> {
  const rows = await env.DB.prepare("SELECT kind FROM alert_jobs ORDER BY id").all<{ kind: string }>();
  return rows.results.map((r) => r.kind);
}

describe("runKrogerSweep", () => {
  it("does nothing when persistence is off", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    expect(await runKrogerSweep(env)).toEqual({ pairs: 0, snapshots: 0, sizeDrops: 0, priceHikes: 0 });
    expect(await jobKinds()).toEqual([]);
  });

  it("files a size_drop, and I1: the real per-unit price rise from that shrink also files a price_hike", async () => {
    // Same $4.00 shelf price, 32 fl oz -> 28 fl oz is a genuine ~14.3%
    // per-unit price increase (I1: computed from OUR price/quantity, not
    // Kroger's estimate) — the sweep should catch it as both event kinds.
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("28 fl oz", 2.0);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ pairs: 1, snapshots: 1, sizeDrops: 1, priceHikes: 1 });
    expect(await jobKinds()).toEqual(["size_drop", "price_hike"]);

    const job = await env.DB.prepare("SELECT gtin, location_id, payload FROM alert_jobs WHERE kind = 'size_drop'").first<any>();
    expect(job.gtin).toBe(GTIN);
    expect(job.location_id).toBe(LOCATION);
    expect(JSON.parse(job.payload)).toEqual({ previous_size: "32 fl oz", size: "28 fl oz" });
  });

  it("ignores a +4.9% per-unit price move at a fixed size", async () => {
    // "1000 g" (metric, no oz/lb conversion factor) keeps the ratio exact —
    // "32 fl oz" -> mL involves an irrational constant whose float rounding
    // can land a hair below a razor's-edge threshold.
    await seedSnapshot("1000 g", 2.0);
    stubBatch("1000 g", 2.0, 4.196);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ sizeDrops: 0, priceHikes: 0 });
    expect(await jobKinds()).toEqual([]);
  });

  it("I1: never compares Kroger's per_unit_estimate — a null-then-positive estimate files no alert", async () => {
    // The previous snapshot has no per_unit_estimate (Kroger omits it per-item,
    // not per-product); the new one has a large positive estimate in Kroger's
    // own unit ($/fl oz). Comparing per_unit_estimate directly against our own
    // price/quantity space would read as a ~1550% "price_hike". Both sides
    // must be computed the same way (our price ÷ our normalized quantity), so
    // an unchanged $4.00/32 fl oz price files nothing.
    await env.DB.prepare("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'G', 'Beverages', NULL, 'volume', 1, 1)").bind(GTIN).run();
    await env.DB.prepare(
      "INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, NULL, '32 fl oz', 'HIGH', 1700000000)",
    ).bind(GTIN, LOCATION).run();
    stubBatch("32 fl oz", 0.07, 4.0);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ sizeDrops: 0, priceHikes: 0 });
    expect(await jobKinds()).toEqual([]);
  });

  it("files a price_hike at exactly +5% (real price, at a fixed size)", async () => {
    await seedSnapshot("1000 g", 2.0);
    stubBatch("1000 g", 2.0, 4.2);

    const result = await runKrogerSweep(on());
    expect(result).toMatchObject({ sizeDrops: 0, priceHikes: 1 });
    expect(await jobKinds()).toEqual(["price_hike"]);
    const payload = JSON.parse((await env.DB.prepare("SELECT payload FROM alert_jobs").first<any>()).payload);
    expect(payload.previous_per_unit).toBeCloseTo(4.0 / 1000, 8);
    expect(payload.per_unit).toBeCloseTo(4.2 / 1000, 8);
  });

  it("writes a fresh snapshot on every pass", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("32 fl oz", 2.0);

    await runKrogerSweep(on());
    const snaps = await env.DB.prepare("SELECT COUNT(*) AS n FROM price_snapshots WHERE gtin = ?").bind(GTIN).first<{ n: number }>();
    expect(snaps!.n).toBe(2);
    expect(await jobKinds()).toEqual([]);
  });

  it("batches at most 50 productIds per Kroger call", async () => {
    for (let i = 0; i < 60; i++) {
      const gtin = `00284006422${String(i).padStart(2, "0")}`;
      await env.DB.prepare("INSERT OR IGNORE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'x','x','x',NULL,'volume',1,1)").bind(gtin).run();
      await env.DB.prepare("INSERT INTO price_snapshots (gtin, location_id, regular, promo, per_unit_estimate, size_raw, stock_level, observed_at) VALUES (?, ?, 4.0, 0, 2.0, '32 fl oz', 'HIGH', 1700000000)").bind(gtin, LOCATION).run();
    }

    const batchSizes: number[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = new URL(input instanceof Request ? input.url : String(input));
        if (url.pathname === "/v1/connect/oauth2/token") return jsonResponse(TOKEN_BODY);
        if (url.pathname === "/v1/products") {
          const ids = decodeURIComponent(url.searchParams.get("filter.productId")!);
          batchSizes.push(ids.split(",").length);
          return jsonResponse({ data: [] });
        }
        throw new Error(`unexpected fetch: ${url.pathname}${url.search}`);
      }),
    );

    const result = await runKrogerSweep(on());
    expect(result.pairs).toBe(60);
    expect(batchSizes).toEqual([50, 10]);
  });
});

describe("worker.scheduled", () => {
  it("runs the Kroger sweep on the six-hourly cron string", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("28 fl oz", 2.0);

    const ctx = createExecutionContext();
    await worker.scheduled({ cron: "0 */6 * * *", scheduledTime: Date.now() } as ScheduledController, on(), ctx);
    await waitOnExecutionContext(ctx);

    // I1: the same shrink (§32 fl oz -> 28 fl oz at an unchanged $4.00) is
    // also a genuine ~14.3% real per-unit price rise.
    expect(await jobKinds()).toEqual(["size_drop", "price_hike"]);
  });

  it("does nothing for an unrelated cron string", async () => {
    await seedSnapshot("32 fl oz", 2.0);
    stubBatch("28 fl oz", 2.0);

    const ctx = createExecutionContext();
    await worker.scheduled({ cron: "0 0 * * *", scheduledTime: Date.now() } as ScheduledController, on(), ctx);
    await waitOnExecutionContext(ctx);

    expect(await jobKinds()).toEqual([]);
  });
});
