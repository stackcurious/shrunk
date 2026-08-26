import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { curatedItems } from "../src/feed";

const GATORADE = "0052000133417";   // curated: 32 fl oz -> 28 fl oz
const SNACK = "0028400642262";

const NOW = Math.floor(Date.now() / 1000);
const DAY = 86400;

async function feed(query = "") {
  const res = await app.request(`/v1/feed${query}`, {}, env);
  expect(res.status).toBe(200);
  return (await res.json()) as { updated: number; items: any[] };
}

async function seedShrink(gtin: string, category: string, previous: number, current: number, createdAt: number) {
  await env.DB.prepare(
    "INSERT OR REPLACE INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Doritos Nacho Cheese', 'Doritos', ?, NULL, 'mass', 1, 1)"
  ).bind(gtin, category).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', '12 oz', ?, 'fdc', '1', 0.9, 'accepted', ?)"
  ).bind(gtin, previous, createdAt - 400 * DAY, createdAt - 400 * DAY).run();
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, 'mass', '10.5 oz', ?, 'kroger', '01400943', 0.8, 'accepted', ?)"
  ).bind(gtin, current, createdAt, createdAt).run();
}

beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM observations"), env.DB.prepare("DELETE FROM products")]);
});

describe("curatedItems", () => {
  it("turns the bundled catalogue into shrink items", () => {
    const items = curatedItems();
    expect(items.length).toBeGreaterThanOrEqual(30);

    const gatorade = items.find((i) => i.gtin === GATORADE)!;
    expect(gatorade).toMatchObject({
      gtin: GATORADE,
      brand: "Gatorade",
      category: "Beverages",
      unit_kind: "volume",
      source: "curated",
      shrink_percent: -12.5,
      observed_at: 1630454400,   // 2021-09-01T00:00:00Z
    });
    expect(gatorade.previous_quantity).toBeCloseTo(946.353, 2);
    expect(gatorade.current_quantity).toBeCloseTo(828.058, 2);
  });

  it("never emits a growth or an unparseable entry", () => {
    for (const item of curatedItems()) {
      expect(item.shrink_percent).toBeLessThan(0);
      expect(item.previous_quantity).toBeGreaterThan(0);
      expect(["mass", "volume", "count"]).toContain(item.unit_kind);
    }
  });
});

describe("GET /v1/feed", () => {
  it("serves the curated catalogue when the database is empty", async () => {
    const body = await feed();
    expect(body.items.some((i) => i.gtin === GATORADE)).toBe(true);
    expect(body.updated).toBeGreaterThan(0);
    expect(body.items[0].observed_at).toBeGreaterThanOrEqual(body.items[body.items.length - 1].observed_at);
  });

  it("merges an accepted Kroger shrink from the last 30 days", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 300, NOW - 2 * DAY);
    const item = (await feed()).items.find((i) => i.gtin === SNACK)!;
    expect(item).toMatchObject({
      name: "Doritos Nacho Cheese",
      brand: "Doritos",
      category: "Snacks",
      unit_kind: "mass",
      source: "kroger",
      shrink_percent: -11.8,
    });
    expect(item.previous_quantity).toBeCloseTo(340.194, 2);
    expect(item.current_quantity).toBe(300);
  });

  it("ignores observations older than the 30-day window", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 300, NOW - 45 * DAY);
    expect((await feed()).items.some((i) => i.gtin === SNACK)).toBe(false);
  });

  it("ignores an accepted observation that did not shrink", async () => {
    await seedShrink(SNACK, "Snacks", 340.194, 341, NOW - DAY);
    expect((await feed()).items.some((i) => i.gtin === SNACK)).toBe(false);
  });

  it("lets a database observation win over the curated row for the same gtin", async () => {
    await seedShrink(GATORADE, "Beverages", 828.058, 700, NOW - DAY);
    const item = (await feed()).items.find((i) => i.gtin === GATORADE)!;
    expect(item.source).toBe("kroger");
    expect(item.current_quantity).toBe(700);
    expect((await feed()).items.filter((i) => i.gtin === GATORADE)).toHaveLength(1);
  });

  it("filters by category, canonicalising the query", async () => {
    const drinks = await feed("?category=Drinks");
    expect(drinks.items.length).toBeGreaterThan(0);
    expect(drinks.items.every((i) => i.category === "Beverages")).toBe(true);
    expect(drinks.items.some((i) => i.gtin === GATORADE)).toBe(true);

    const snacks = await feed("?category=Snacks");
    expect(snacks.items.some((i) => i.gtin === GATORADE)).toBe(false);
  });
});
