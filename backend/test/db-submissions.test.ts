import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  getLatestAcceptedObservation,
  getObservationBySubmission,
  getSubmission,
  insertAlertJob,
  insertObservation,
  insertSubmission,
  listPendingSubmissions,
  markSubmissionReviewed,
  setObservationStatus,
  setProductUnitKindIfMissing,
} from "../src/db";

const GTIN = "0028400642255";

async function seedProduct(unitKind: string | null) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, ?, 1, 1)"
  ).bind(GTIN, unitKind).run();
}

function submission(id: string, status: string, photoKey: string | null = null) {
  return {
    id, device_id: "device-1", gtin: GTIN, photo_key: photoKey,
    ocr_text: "NET WT 28 OZ (794g)", parsed_quantity: 793.786, parsed_kind: "mass",
    status, created_at: 1700000000,
  };
}

describe("submission and alert_jobs helpers", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
  });

  it("round-trips a submission", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending", "submissions/sub-1.jpg"));
    const row = await getSubmission(env.DB, "sub-1");
    expect(row).toMatchObject({
      id: "sub-1", device_id: "device-1", gtin: GTIN, photo_key: "submissions/sub-1.jpg",
      ocr_text: "NET WT 28 OZ (794g)", parsed_quantity: 793.786, parsed_kind: "mass",
      status: "pending", created_at: 1700000000, reviewed_at: null,
    });
    expect(await getSubmission(env.DB, "nope")).toBeNull();
  });

  it("lists only pending submissions and joins the product name", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending"));
    await insertSubmission(env.DB, submission("sub-2", "accepted"));
    const rows = await listPendingSubmissions(env.DB);
    expect(rows.map((r) => r.id)).toEqual(["sub-1"]);
    expect(rows[0].name).toBe("Gatorade");
    expect(rows[0].brand).toBe("Gatorade");
  });

  it("lists a submission for a product that does not exist yet", async () => {
    await insertSubmission(env.DB, submission("sub-1", "pending"));
    const rows = await listPendingSubmissions(env.DB);
    expect(rows).toHaveLength(1);
    expect(rows[0].name).toBe("");
  });

  it("marks a submission reviewed and drops its photo key", async () => {
    await seedProduct("mass");
    await insertSubmission(env.DB, submission("sub-1", "pending", "submissions/sub-1.jpg"));
    await markSubmissionReviewed(env.DB, "sub-1", "rejected", 1700000900);
    const row = await getSubmission(env.DB, "sub-1");
    expect(row).toMatchObject({ status: "rejected", reviewed_at: 1700000900, photo_key: null });
  });

  it("inserts an observation, returns its id, and flips its status", async () => {
    await seedProduct("mass");
    const id = await insertObservation(env.DB, {
      gtin: GTIN, quantity: 793.786, unit_kind: "mass", raw_text: "NET WT 28 OZ (794g)",
      observed_at: 1700000000, source: "crowd", source_ref: "sub-1", confidence: 0.7, status: "pending",
    });
    expect(id).toBeGreaterThan(0);

    const found = await getObservationBySubmission(env.DB, "sub-1");
    expect(found).toMatchObject({ id, gtin: GTIN, quantity: 793.786, unit_kind: "mass", status: "pending" });

    await setObservationStatus(env.DB, id, "accepted");
    expect((await getObservationBySubmission(env.DB, "sub-1"))?.status).toBe("accepted");
  });

  it("finds the newest accepted observation of the requested kind only", async () => {
    await seedProduct("mass");
    await insertObservation(env.DB, { gtin: GTIN, quantity: 907.184, unit_kind: "mass", raw_text: null, observed_at: 1517443200, source: "fdc", source_ref: "1", confidence: 0.9, status: "accepted" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 850, unit_kind: "mass", raw_text: null, observed_at: 1625097600, source: "fdc", source_ref: "2", confidence: 0.9, status: "accepted" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 500, unit_kind: "mass", raw_text: null, observed_at: 1700000000, source: "crowd", source_ref: "sub-1", confidence: 0.5, status: "pending" });
    await insertObservation(env.DB, { gtin: GTIN, quantity: 828.058, unit_kind: "volume", raw_text: null, observed_at: 1700000000, source: "fdc", source_ref: "3", confidence: 0.9, status: "accepted" });

    expect((await getLatestAcceptedObservation(env.DB, GTIN, "mass"))?.quantity).toBe(850);
    expect((await getLatestAcceptedObservation(env.DB, GTIN, "volume"))?.quantity).toBe(828.058);
    expect(await getLatestAcceptedObservation(env.DB, GTIN, "count")).toBeNull();
  });

  it("fills a missing dominant kind but never overwrites one", async () => {
    await seedProduct(null);
    await setProductUnitKindIfMissing(env.DB, GTIN, "mass", 1700000000);
    let row = await env.DB.prepare("SELECT unit_kind, updated_at FROM products WHERE gtin = ?").bind(GTIN).first<{ unit_kind: string; updated_at: number }>();
    expect(row).toMatchObject({ unit_kind: "mass", updated_at: 1700000000 });

    await setProductUnitKindIfMissing(env.DB, GTIN, "volume", 1700009999);
    row = await env.DB.prepare("SELECT unit_kind, updated_at FROM products WHERE gtin = ?").bind(GTIN).first<{ unit_kind: string; updated_at: number }>();
    expect(row).toMatchObject({ unit_kind: "mass", updated_at: 1700000000 });
  });

  it("round-trips an alert job", async () => {
    await insertAlertJob(env.DB, {
      kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null,
      payload: JSON.stringify({ percent_change: -12.5 }), created_at: 1700000000,
    });
    const row = await env.DB.prepare("SELECT kind, gtin, brand, location_id, payload, created_at, sent_at FROM alert_jobs").first<any>();
    expect(row).toMatchObject({ kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null, created_at: 1700000000, sent_at: null });
    expect(JSON.parse(row.payload).percent_change).toBe(-12.5);
  });
});
