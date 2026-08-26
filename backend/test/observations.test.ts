import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import app from "../src/index";
import { hitRateLimit, KROGER_HOURLY_LIMIT } from "../src/ratelimit";
import { declaredBodyTooLarge } from "../src/routes/observations";

const GTIN = "0028400642255";

function body(overrides: Record<string, string> = {}, photo?: Blob): FormData {
  const fields: Record<string, string> = {
    gtin: GTIN,
    device_id: "device-1",
    quantity: "793.786",
    unit_kind: "mass",
    raw_text: "NET WT 28 OZ (794g)",
    ocr_confidence: "0.95",
    ...overrides,
  };
  const form = new FormData();
  for (const [key, value] of Object.entries(fields)) form.append(key, value);
  if (photo) form.append("photo", photo, "label.jpg");
  return form;
}

const jpeg = () => new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" });

async function post(form: FormData) {
  return app.request("/v1/observations", { method: "POST", body: form }, env);
}

async function seedProduct(unitKind: string | null) {
  await env.DB.prepare(
    "INSERT INTO products (gtin, name, brand, category, image_url, unit_kind, created_at, updated_at) VALUES (?, 'Gatorade', 'Gatorade', 'Beverages', NULL, ?, 1, 1)"
  ).bind(GTIN, unitKind).run();
}

async function seedAccepted(quantity: number, unitKind = "mass") {
  await env.DB.prepare(
    "INSERT INTO observations (gtin, quantity, unit_kind, raw_text, observed_at, source, source_ref, confidence, status, created_at) VALUES (?, ?, ?, '32 oz', 1517443200, 'fdc', '1', 0.9, 'accepted', 1)"
  ).bind(GTIN, quantity, unitKind).run();
}

async function photoKeys(): Promise<string[]> {
  return (await env.PHOTOS.list()).objects.map((o) => o.key);
}

describe("declaredBodyTooLarge", () => {
  const CAP = 5 * 1024 * 1024;
  const SLACK = 64 * 1024;

  it("allows a declared size within the cap plus slack", () => {
    expect(declaredBodyTooLarge(String(CAP))).toBe(false);
    expect(declaredBodyTooLarge(String(CAP + SLACK))).toBe(false);
  });

  it("rejects a declared size beyond the cap plus slack", () => {
    expect(declaredBodyTooLarge(String(CAP + SLACK + 1))).toBe(true);
    expect(declaredBodyTooLarge(String(6 * 1024 * 1024))).toBe(true);
  });

  it("treats a missing or malformed header as small, deferring to the post-parse checks", () => {
    expect(declaredBodyTooLarge(null)).toBe(false);
    expect(declaredBodyTooLarge("not-a-number")).toBe(false);
    expect(declaredBodyTooLarge("")).toBe(false);
  });
});

describe("POST /v1/observations", () => {
  beforeEach(async () => {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM alert_jobs"),
      env.DB.prepare("DELETE FROM submissions"),
      env.DB.prepare("DELETE FROM observations"),
      env.DB.prepare("DELETE FROM products"),
    ]);
    for (const key of await photoKeys()) await env.PHOTOS.delete(key);
  });

  it("accepts a high-confidence submission, keeps no photo, and queues a size drop", async () => {
    await seedProduct("mass");
    await seedAccepted(907.184);

    const res = await post(body({}, jpeg()));
    expect(res.status).toBe(200);
    const json = await res.json<{ status: string; confidence: number; observation_id: number }>();
    expect(json.status).toBe("accepted");
    expect(json.confidence).toBe(1);
    expect(json.observation_id).toBeGreaterThan(0);

    const observation = await env.DB.prepare(
      "SELECT quantity, unit_kind, raw_text, source, source_ref, confidence, status FROM observations WHERE id = ?"
    ).bind(json.observation_id).first<any>();
    expect(observation).toMatchObject({
      quantity: 793.786, unit_kind: "mass", raw_text: "NET WT 28 OZ (794g)",
      source: "crowd", confidence: 1, status: "accepted",
    });

    const submission = await env.DB.prepare("SELECT id, status, photo_key, device_id, parsed_quantity FROM submissions").first<any>();
    expect(submission).toMatchObject({ status: "accepted", photo_key: null, device_id: "device-1", parsed_quantity: 793.786 });
    expect(observation.source_ref).toBe(submission.id);

    // Accepted rows never need a human, so the photo is never written (spec §6.3).
    expect(await photoKeys()).toEqual([]);

    const job = await env.DB.prepare("SELECT kind, gtin, brand, location_id, payload, sent_at FROM alert_jobs").first<any>();
    expect(job).toMatchObject({ kind: "size_drop", gtin: GTIN, brand: "Gatorade", location_id: null, sent_at: null });
    expect(JSON.parse(job.payload)).toEqual({
      gtin: GTIN, unit_kind: "mass", previous_quantity: 907.184, quantity: 793.786,
      percent_change: -12.5, source: "crowd",
    });
  });

  it("holds a low-confidence submission pending and stores its photo", async () => {
    await seedProduct(null);

    const res = await post(body({ ocr_confidence: "0.4" }, jpeg()));
    const json = await res.json<{ status: string; confidence: number; observation_id: number }>();
    expect(json.status).toBe("pending");
    expect(json.confidence).toBe(0.5);

    const submission = await env.DB.prepare("SELECT id, status, photo_key FROM submissions").first<any>();
    expect(submission.status).toBe("pending");
    expect(submission.photo_key).toBe(`submissions/${submission.id}.jpg`);
    expect(await photoKeys()).toEqual([submission.photo_key]);

    const stored = await env.PHOTOS.get(submission.photo_key);
    expect(stored?.httpMetadata?.contentType).toBe("image/jpeg");

    expect((await env.DB.prepare("SELECT status FROM observations WHERE id = ?").bind(json.observation_id).first<any>()).status).toBe("pending");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("accepts a pending submission that arrives without a photo", async () => {
    await seedProduct(null);
    const res = await post(body({ ocr_confidence: "0.4" }));
    expect((await res.json<{ status: string }>()).status).toBe("pending");
    const submission = await env.DB.prepare("SELECT photo_key FROM submissions").first<any>();
    expect(submission.photo_key).toBeNull();
    expect(await photoKeys()).toEqual([]);
  });

  it("creates the product row when the barcode is unknown everywhere", async () => {
    const res = await post(body({ gtin: "0099999999999", ocr_confidence: "0.4" }));
    expect(res.status).toBe(200);
    expect((await res.json<{ status: string }>()).status).toBe("pending");
    const product = await env.DB.prepare("SELECT gtin, name, unit_kind FROM products WHERE gtin = '0099999999999'").first<any>();
    expect(product).toMatchObject({ gtin: "0099999999999", name: "", unit_kind: null });
  });

  it("backfills the product's dominant kind when a crowd row is accepted", async () => {
    await seedProduct(null);
    await seedAccepted(907.184);
    // 0.5 parsed + 0.2 range + 0.1 ocr = 0.8 -> accepted with no dominant kind.
    const res = await post(body());
    expect(await res.json<{ status: string; confidence: number }>()).toMatchObject({ status: "accepted", confidence: 0.8 });
    const product = await env.DB.prepare("SELECT unit_kind FROM products WHERE gtin = ?").bind(GTIN).first<any>();
    expect(product.unit_kind).toBe("mass");
  });

  it("does not queue a size drop for a change inside the 1% same-size band", async () => {
    await seedProduct("mass");
    await seedAccepted(907.184);
    const res = await post(body({ quantity: "900" }));
    expect((await res.json<{ status: string }>()).status).toBe("accepted");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("does not queue a size drop when the package grew", async () => {
    await seedProduct("mass");
    await seedAccepted(793.786);
    const res = await post(body({ quantity: "907.184" }));
    expect((await res.json<{ status: string }>()).status).toBe("accepted");
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM alert_jobs").first<{ n: number }>())!.n).toBe(0);
  });

  it("normalizes a 12-digit UPC-A onto the existing product", async () => {
    await seedProduct("mass");
    await post(body({ gtin: "028400642255", ocr_confidence: "0.4" }));
    const submission = await env.DB.prepare("SELECT gtin FROM submissions").first<any>();
    expect(submission.gtin).toBe(GTIN);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM products").first<{ n: number }>())!.n).toBe(1);
  });

  it("rejects malformed submissions", async () => {
    const cases: Array<[Record<string, string>, string]> = [
      [{ gtin: "12345" }, "invalid_gtin"],
      [{ device_id: "" }, "missing_device_id"],
      [{ device_id: "d".repeat(65) }, "invalid_device_id"],
      [{ quantity: "0" }, "invalid_quantity"],
      [{ quantity: "banana" }, "invalid_quantity"],
      [{ unit_kind: "grams" }, "invalid_unit_kind"],
    ];
    for (const [overrides, error] of cases) {
      const res = await post(body(overrides));
      expect(res.status, error).toBe(400);
      expect(await res.json()).toEqual({ error });
    }
  });

  it("rejects a photo larger than 5 MB before touching R2", async () => {
    const huge = new Blob([new Uint8Array(5 * 1024 * 1024 + 1)], { type: "image/jpeg" });
    const res = await post(body({ ocr_confidence: "0.4" }, huge));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "photo_too_large" });
    expect(await photoKeys()).toEqual([]);
  });

  it("rejects a body far beyond the photo cap by its declared Content-Length, without parsing it", async () => {
    // I7: c.req.formData() buffers the whole request before the old
    // post-parse size check ever ran. A body this far over the cap must be
    // rejected off Content-Length alone, before multipart parsing starts.
    const huge = new Blob([new Uint8Array(6 * 1024 * 1024)], { type: "image/jpeg" });
    const res = await post(body({ ocr_confidence: "0.4" }, huge));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "photo_too_large" });
    expect(await photoKeys()).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM submissions").first<{ n: number }>()).toMatchObject({ n: 0 });
  });

  it("rejects a photo whose bytes are not a JPEG, regardless of the declared content-type", async () => {
    await seedProduct(null);
    const notJpeg = new Blob([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], { type: "image/jpeg" }); // PNG magic bytes
    const res = await post(body({ ocr_confidence: "0.4" }, notJpeg));
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_photo" });
    expect(await photoKeys()).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM submissions").first<{ n: number }>()).toMatchObject({ n: 0 });
  });

  it("stores the photo as image/jpeg regardless of the client's declared content-type", async () => {
    await seedProduct(null);
    const lyingType = new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "text/html" });
    const res = await post(body({ ocr_confidence: "0.4" }, lyingType));
    expect(res.status).toBe(200);
    const submission = await env.DB.prepare("SELECT photo_key FROM submissions").first<{ photo_key: string }>();
    const stored = await env.PHOTOS.get(submission!.photo_key);
    expect(stored?.httpMetadata?.contentType).toBe("image/jpeg");
  });

  it("rate-limits submissions to 30 per device per hour, separately from the Kroger quota", async () => {
    await seedProduct("mass");
    const deviceId = `device-rl-${crypto.randomUUID()}`;
    for (let i = 1; i <= 30; i++) {
      const res = await post(body({ device_id: deviceId }));
      expect(res.status, `attempt ${i}`).toBe(200);
    }
    const res = await post(body({ device_id: deviceId }));
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });

    // A device that has exhausted its observations quota still has its
    // separate Kroger quota (spec §6.6) untouched.
    const { allowed } = await hitRateLimit(env.KV, deviceId, KROGER_HOURLY_LIMIT, "kroger");
    expect(allowed).toBe(true);
  });
});
