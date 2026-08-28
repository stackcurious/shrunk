import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { collapseRuns } from "../src/runs";
import { runPairEndingAt } from "../src/db";

const GTIN = "0052000135138";

/** Shorthand for a same-kind observation, oldest first. */
const obs = (quantity: number, observed_at: number, source = "fdc") => ({ quantity, observed_at, source });

describe("collapseRuns (spec §5.1)", () => {
  it("collapses a confirmation into the run it confirms", () => {
    // The bug this exists for: curated 500 -> 450, then USDA reports the same
    // 450. The last two *observations* are 450/450 (+0.0%, "Unchanged"), which
    // erased a documented shrink. The last two *runs* are 500 -> 450.
    const runs = collapseRuns([obs(500, 10, "curated"), obs(450, 20, "curated"), obs(450, 30, "fdc")]);

    expect(runs).toHaveLength(2);
    expect(runs[0]).toMatchObject({ quantity: 500, source: "curated", opened_at: 10, observed_at: 10 });
    expect(runs[1]).toMatchObject({ quantity: 450, source: "curated", opened_at: 20, observed_at: 30 });
    expect(runs[1].sources).toEqual(["curated", "fdc"]);
  });

  it("keeps three runs separate so only the last two are ever compared", () => {
    const runs = collapseRuns([obs(500, 10), obs(450, 20), obs(450, 30), obs(400, 40)]);
    expect(runs.map((r) => r.quantity)).toEqual([500, 450, 400]);
  });

  it("treats measurement noise inside the tolerance as one run", () => {
    // 450 -> 452 (+0.44%) -> 450: three observations, one size.
    const runs = collapseRuns([obs(450, 10), obs(452, 20), obs(450, 30)]);
    expect(runs).toHaveLength(1);
    expect(runs[0]).toMatchObject({ quantity: 450, opened_at: 10, observed_at: 30 });
  });

  it("compares against the value that opened the run, so drift cannot accumulate", () => {
    // Each step is under 1% of its predecessor, but 450 -> 460 is not.
    const runs = collapseRuns([obs(450, 10), obs(454, 20), obs(458, 30), obs(460, 40)]);
    expect(runs.map((r) => r.quantity)).toEqual([450, 458]);
  });

  it("never merges anything into a zero-quantity run", () => {
    const runs = collapseRuns([obs(0, 10), obs(0, 20), obs(28, 30)]);
    expect(runs.map((r) => r.quantity)).toEqual([0, 28]);
    expect(runs[0].observed_at).toBe(20);
  });

  it("returns nothing for no observations", () => {
    expect(collapseRuns([])).toEqual([]);
  });
});

describe("runPairEndingAt", () => {
  beforeEach(async () => {
    await env.DB.batch([env.DB.prepare("DELETE FROM observations"), env.DB.prepare("DELETE FROM products")]);
    await env.DB
      .prepare(
        "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'G', 'Gatorade', 'Beverages', NULL, 'volume', 1, 1)"
      )
      .bind(GTIN)
      .run();
  });

  async function seed(rows: Array<[number, string, number, string, string?]>) {
    for (const [quantity, unitKind, observedAt, source, status] of rows) {
      await env.DB
        .prepare(
          "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, NULL, ?, ?, NULL, 0.9, ?, ?)"
        )
        .bind(GTIN, quantity, unitKind, observedAt, source, status ?? "accepted", observedAt)
        .run();
    }
  }

  const latest = () =>
    env.DB.prepare("SELECT id, observed_at FROM observations ORDER BY observed_at DESC, id DESC LIMIT 1").first<{
      id: number;
      observed_at: number;
    }>();

  it("looks past a confirming observation to the size before it", async () => {
    await seed([
      [946.353, "volume", 100, "fdc"],
      [828.058, "volume", 200, "kroger"],
      [828.058, "volume", 300, "crowd"],
    ]);
    const row = (await latest())!;
    expect(await runPairEndingAt(env.DB, GTIN, "volume", row.observed_at, row.id)).toEqual({
      previous: 946.353,
      current: 828.058,
      currentOpenedAt: 200,
    });
  });

  it("compares the last two runs when there are three", async () => {
    await seed([
      [946.353, "volume", 100, "fdc"],
      [828.058, "volume", 200, "kroger"],
      [828.058, "volume", 300, "crowd"],
      [700, "volume", 400, "kroger"],
    ]);
    const row = (await latest())!;
    expect(await runPairEndingAt(env.DB, GTIN, "volume", row.observed_at, row.id)).toEqual({
      previous: 828.058,
      current: 700,
      currentOpenedAt: 400,
    });
  });

  it("returns null when every observation is the same size", async () => {
    await seed([
      [450, "volume", 100, "fdc"],
      [452, "volume", 200, "kroger"],
      [450, "volume", 300, "crowd"],
    ]);
    const row = (await latest())!;
    expect(await runPairEndingAt(env.DB, GTIN, "volume", row.observed_at, row.id)).toBeNull();
  });

  it("never crosses unit kinds and never reads a pending observation", async () => {
    await seed([
      [946.353, "volume", 100, "fdc"],
      [340.194, "mass", 150, "fdc"],
      [400, "volume", 180, "crowd", "pending"],
      [828.058, "volume", 200, "kroger"],
    ]);
    const row = (await latest())!;
    expect(await runPairEndingAt(env.DB, GTIN, "volume", row.observed_at, row.id)).toEqual({
      previous: 946.353,
      current: 828.058,
      currentOpenedAt: 200,
    });
    expect(await runPairEndingAt(env.DB, GTIN, "mass", 150, 999)).toBeNull();
  });

  it("ignores anything recorded after the observation it is asked about", async () => {
    await seed([
      [946.353, "volume", 100, "fdc"],
      [828.058, "volume", 200, "kroger"],
      [700, "volume", 300, "kroger"],
    ]);
    const middle = (await env.DB
      .prepare("SELECT id FROM observations WHERE observed_at = 200")
      .first<{ id: number }>())!;
    expect(await runPairEndingAt(env.DB, GTIN, "volume", 200, middle.id)).toEqual({
      previous: 946.353,
      current: 828.058,
      currentOpenedAt: 200,
    });
  });
});
